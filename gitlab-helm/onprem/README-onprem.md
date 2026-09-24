# GitLab on `upskillops-cluster`

GitLab CE installed from the upstream Helm chart onto the on-prem kubeadm
cluster, exposed through the shared Istio ingress gateway.

This is a different target from [`../`](../), which describes an EKS install
(NLB, IRSA, RDS/ElastiCache/S3). Nothing here applies to that cluster.

## What is installed

| | |
|---|---|
| Chart | `gitlab/gitlab` 9.11.12 (GitLab CE 18.11.11) |
| Release / namespace | `gitlab` / `gitlab` |
| Web UI | `https://gitlab.upskillops.in` |
| Container registry | `https://registry.upskillops.in` |
| Object storage (MinIO) | `https://gitlab-minio.upskillops.in` |
| git over SSH | `192.168.0.142:22` (MetalLB) |
| Storage | Longhorn via `longhorn-gitlab` (2 replicas, `Retain`) |

### Why chart 9.x and not 10.x

Chart 10.x removed the bundled `postgresql`, `redis` and `minio` subcharts;
it expects you to bring your own. This cluster has no managed datastore to
point at, so 9.11.x — the last line that still ships them — keeps the install
self-contained. Moving to 10.x means standing up PostgreSQL and Redis first.

## Files

- `values-gitlab-onprem.yaml` — Helm values
- `gitlab-istio.yaml` — Istio `Gateway` + three `VirtualService`s
- `storageclass-longhorn-gitlab.yaml` — 2-replica Longhorn class

## Install

```bash
kubectl apply -f storageclass-longhorn-gitlab.yaml

helm repo add gitlab https://charts.gitlab.io/ && helm repo update gitlab
helm upgrade --install gitlab gitlab/gitlab --version 9.11.12 \
  -n gitlab --create-namespace \
  -f values-gitlab-onprem.yaml --timeout 25m

kubectl apply -f gitlab-istio.yaml
```

Root password (rotate it after first login):

```bash
kubectl get secret gitlab-gitlab-initial-root-password -n gitlab \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

## How the exposure works

The chart's own nginx controller and Ingress objects are switched off
(`global.ingress.enabled: false`, `nginx-ingress.enabled: false`). Traffic
instead goes:

```
client -> istio-ingressgateway (192.168.0.140, TLS terminated here)
       -> gitlab-gateway -> VirtualService -> service
```

TLS uses the existing `wildcard-upskillops-in-tls` secret in `istio-system`,
the same one harbor/argocd/vault use. Port 80 redirects to 443.

Two details worth knowing before you change the routing:

- `gitlab.upskillops.in` routes to **port 8181** on
  `gitlab-webservice-default`, which is Workhorse — not port 8080, which is
  Puma. Workhorse is what handles git-over-HTTP, LFS and large uploads;
  routing to 8080 gives you a web UI that can't serve git.
- Routes set `timeout: 1800s`. Cloning or pushing a large repo, and pushing
  container layers, both outlast a short route timeout.

SSH is deliberately not on the gateway — an L7 HTTP gateway cannot carry it,
so `gitlab-shell` takes its own MetalLB address instead.

DNS for all three hostnames must point at **192.168.0.140**
(`istio-ingressgateway`), not at the shell IP.

## Capacity

This is the tight part. At install time the cluster had roughly **1.7 CPU and
9.6Gi actually free**, essentially all of it on `worker3`:

- `master` is tainted `NoSchedule`
- `worker1` is **NotReady**
- `worker2` was at 82% CPU / 86% memory requested

So every request in the values file is trimmed well below GitLab's defaults —
the install totals about **850m CPU / 5.2Gi**. It fits, but it is sized to
fit, not sized to be fast. Expect slow web responses and slow CI under load.

Two things to do when you can, in order of payoff:

1. **Bring `worker1` back.** It is 4 CPU / 7.7Gi sitting idle, and it is also
   the reason `longhorn-gitlab` uses 2 replicas instead of 3. With it back,
   raise `numberOfReplicas` to 3 for real redundancy.
2. **Raise the webservice and sidekiq requests.** Those two govern how GitLab
   actually feels. 2Gi for Puma is the floor, not a target.

GitLab's own [reference architectures](https://docs.gitlab.com/ee/administration/reference_architectures/)
start at 8 vCPU / 16Gi for 1,000 users — worth reading before this grows past
a handful of people.

## Things this install does not do

- No Prometheus (`kube-prometheus-stack` already runs in `monitoring`)
- No GitLab Runner (runners live in the `gitlab-runner` namespace)
- No cert-manager (already cluster-wide; the gateway reuses the wildcard cert)
- No KAS (the agent server) — disabled to save a pod
- No `gitlab-exporter`
- No Istio sidecar injection in the `gitlab` namespace, matching how harbor
  and argocd are deployed here

## Known gap: Kyverno `require-requests-limits`

The cluster runs a Kyverno policy requiring both requests *and* limits on
every container. The values file sets requests only, so GitLab's pods are
flagged in policy reports:

```
policy require-requests-limits/validate-resources fail: validation error:
CPU and memory resource requests and limits are required.
```

The policy is `validationFailureAction: Audit`, so nothing is blocked — this
is a compliance gap, not an outage. Closing it means adding `limits` next to
every `requests` block in `values-gitlab-onprem.yaml`.

Be deliberate about the memory numbers if you do. On a cluster this tight, a
memory limit set near the request is an OOMKill loop waiting for a big repo
or a heavy CI job; give Puma and Sidekiq real headroom above their requests
rather than mirroring them.

---

# GitLab Runner

Runs in the **same `gitlab` namespace** as GitLab, with the Kubernetes
executor, so CI job pods are created alongside it.

| | |
|---|---|
| Chart | `charts/gitlab-runner-0.88.4.tgz` (vendored, SHA in `charts/SHA256SUMS`) |
| Runner version | 18.11.4 |
| Values | `values-gitlab-runner.yaml` |
| Release | `gitlab-runner` in namespace `gitlab` |
| Concurrency | 4 jobs |

The chart version is not arbitrary. 0.88.4 is Runner **18.11.4**, matched to
the GitLab **18.11.11** server — a runner newer than its GitLab is not a
supported pairing, so do not bump this independently of the GitLab chart.
The `helm search repo gitlab/gitlab-runner --versions` output is the map from
chart version to runner version.

## Install

The `glrt-` token is an **authentication** token, not the old registration
token. The runner authenticates with it rather than registering, so its name,
tags and "run untagged jobs" setting all live in the GitLab UI
(Admin → CI/CD → Runners), not in these values.

```bash
# Token goes in a Secret, never in the values file.
umask 077 && printf '%s' 'glrt-...' > /tmp/rt
kubectl -n gitlab create secret generic gitlab-runner-token \
  --from-file=runner-token=/tmp/rt \
  --from-file=runner-registration-token=/dev/null
rm -f /tmp/rt

helm upgrade --install gitlab-runner charts/gitlab-runner-0.88.4.tgz \
  -n gitlab -f values-gitlab-runner.yaml
```

**The empty `runner-registration-token` key is required**, even though a
`glrt-` token never uses it. The chart's `projected-secrets` volume lists both
keys with no `optional: true`, so a secret carrying only `runner-token`
leaves the pod stuck in `ContainerCreating` with:

```
MountVolume.SetUp failed for volume "projected-secrets":
references non-existent secret key: runner-registration-token
```

That is the single most likely thing to go wrong here, and the error does not
mention the runner or the token at all.

Confirm it authenticated — this line is the one that matters:

```bash
kubectl -n gitlab logs -l app=gitlab-runner | grep 'is valid'
#   Verifying runner... is valid   runner=24UJhlLdM
```

## Job sizing

CI pods get explicit requests *and* limits (200m/256Mi request, 1 CPU/1Gi
limit). That is deliberate on this cluster: unbounded CI pods are the fastest
way to evict GitLab itself, which is already running with little headroom.
`concurrent: 4` is set against roughly one spare core — raise both together,
or not at all.

`request_concurrency = 4` is separate: it is concurrent API requests to
GitLab, not jobs. Left at the default of 1 the runner logs a
"Request bottleneck ... causing job delays during long polling" warning on
every config reload.

## Cache

Distributed cache reuses the MinIO that ships with the GitLab release —
bucket `runner-cache`, which GitLab's own bucket-creation job already made.
Credentials are copied from `gitlab-minio-secret` into `gitlab-runner-cache`.
Nothing extra to run.

If you ever rotate the MinIO keys, recreate that secret too or caching starts
failing silently (jobs still run, they just stop caching).

## Note on the other runners

Three unrelated runners already exist in the **`gitlab-runner`** namespace
(`gitlab-runner`, `gitlab-runner-eks`, `gitlab-runner-infra`), pointing at
other GitLab instances. This one is independent of all three; they do not
conflict, but do not confuse them when debugging.
