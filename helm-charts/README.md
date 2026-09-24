# helm-charts

Vendored Helm charts for the two things that are installed with `helm` rather
than by Terraform: **Cilium** (the cluster's only CNI) and **GitLab**.

Terraform still builds all the AWS underneath — VPC, EKS, node groups, IAM
roles, RDS, ElastiCache, S3, Route53 — and still installs the two small
cluster-scoped controllers GitLab depends on (AWS Load Balancer Controller and
external-dns). What moved out of Terraform is the two big charts, so that
`helm diff`, `helm history` and `helm rollback` work on them normally instead
of every values change being a `terraform plan`.

```
charts/          the pinned .tgz archives, committed, with SHA256SUMS
values/          values files with __PLACEHOLDER__ tokens -- edit these
bin/             install scripts
eks-standalone/  the self-contained GitLab install (see below)
.rendered/       values with Terraform outputs substituted in -- generated, gitignored
```

## Two ways to install GitLab

|  | production | self-contained |
|---|---|---|
| Chart | `gitlab-10.4.0.tgz` | `gitlab-9.11.12.tgz` |
| Values | `values/gitlab.values.yaml` | `values/gitlab-eks-standalone.yaml` |
| Postgres / Redis / objects | RDS, ElastiCache, S3 | bundled in-cluster, on EBS |
| Ingress | Envoy Gateway -> NLB | bundled nginx -> NLB |
| Install | `./bin/install-gitlab.sh` | one `helm upgrade --install` |
| Needs Terraform outputs | yes | no |

Everything below this section describes the **production** path. For the
self-contained one see [`eks-standalone/README.md`](eks-standalone/README.md) --
it is independent, and installing it touches nothing the production path owns.

It exists because chart 10.x cannot be self-contained: v10.0.0 deleted the
bundled PostgreSQL, Redis and MinIO subcharts, so the 9.x line is the only way
to get GitLab onto a cluster without provisioning managed datastores first.

## GitLab on EKS with the Helm chart

The self-contained path, start to finish. Everything installs from the
committed `.tgz` — nothing is pulled from `charts.gitlab.io` at deploy time.
Full detail, including the trade-offs, is in
[`eks-standalone/README.md`](eks-standalone/README.md).

**0. Point kubectl at the right cluster.** Worth stating because this repo also
manages an on-prem cluster, and the install command does not name a cluster:

```bash
aws eks update-kubeconfig --name <cluster> --region <region>
kubectl config current-context      # confirm before going further
```

**1. Storage.** EKS ships `gp2` and no CSI driver, so without these two the
PVCs sit `Pending` with no useful error:

```bash
aws eks create-addon --cluster-name <cluster> --addon-name aws-ebs-csi-driver
kubectl apply -f eks-standalone/storageclass-gp3.yaml
```

**2. Install.** Only the domain and the ACME address differ per environment,
which is why they are flags rather than edits to the values file:

```bash
helm upgrade --install gitlab charts/gitlab-9.11.12.tgz \
  -n gitlab --create-namespace \
  -f values/gitlab-eks-standalone.yaml \
  --set global.hosts.domain=example.com \
  --set certmanager-issuer.email=you@example.com \
  --timeout 25m
```

A first install runs ~1,400 migrations and pulls around 20 images, so 10-20
minutes is normal. Watch it with `kubectl -n gitlab get pods -w`.

**3. DNS.** Three hosts, all on the one NLB the chart creates:

```bash
kubectl -n gitlab get svc gitlab-nginx-ingress-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Point `gitlab.<domain>`, `registry.<domain>` and `minio.<domain>` at it — a
CNAME each, or one wildcard. Do this *before* expecting TLS to work:
cert-manager uses an HTTP01 challenge, so Let's Encrypt has to reach
`gitlab.<domain>` on port 80 from the internet. Until DNS resolves the
certificate stays pending and the site serves a self-signed cert.

**4. Log in.**

```bash
kubectl -n gitlab get secret gitlab-gitlab-initial-root-password \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

User `root` at `https://gitlab.<domain>`. Rotate immediately — GitLab deletes
that secret once you do.

### Sizing — check before you install

Measured from `helm template` against the vendored chart:

| | |
|---|---|
| Total requests | 2125m CPU, **8068Mi (7.9Gi)** |
| Largest single pod | `webservice` at **2595Mi** |

The second row is the one that catches people. A pod schedules whole, so
**one node must have ≥2595Mi allocatable by itself** — lots of total memory
spread over small nodes still leaves `webservice` `Pending` forever. Roughly
3 x `m7g.large` (8Gi each) clears both limits.

Concretely: the free-tier profile in `../terraform-karpenter-nodepools`
(`-var-file=free-tier.tfvars`) builds 3 x `t4g.small` = 4098Mi allocatable in
total, with 1366Mi on the largest node. **GitLab cannot run there** — short on
total memory, and no single node can hold `webservice`. The AWS Free plan's
instance allowlist has nothing bigger for arm64, so this needs the normal
`variables.tf` defaults and a raised `L-1216C47A` vCPU quota.

GitLab's own reference architecture for 1,000 users starts at 8 vCPU / 16Gi,
so 7.9Gi is a floor for a working install, not a target.

### Two things left off

`gitlab-runner.install` and `prometheus.install` are both `false`. The runner
is off because a first install has no runner token yet — turn it on afterwards.
Prometheus is off because `kube-prometheus-stack` belongs on the monitoring
tier, not bundled into this release.

SSH shares the same NLB: the bundled nginx controller publishes TCP 22 and
forwards it to `gitlab-shell`, so there is deliberately no second
`LoadBalancer` Service. Giving it one stands up a second NLB serving the same
endpoint.

---

## The install order, and why it looks broken in the middle

This cluster has **no VPC CNI and no kube-proxy**. Cilium replaces both. The
EKS module sets `bootstrap_self_managed_addons = false` and
`modules/cluster-addons` installs neither, so a freshly created node has nothing to write
`/etc/cni/net.d` and the kubelet refuses to report Ready.

That produces a deliberate window:

| # | State | What you see |
|---|---|---|
| 1 | Control plane created | no nodes |
| 2 | Node groups created, nodes join | `kubectl get nodes` → **all NotReady** |
| 3 | `install-cilium.sh` runs | cilium-agent DaemonSet tolerates NotReady, runs on the host network, writes the CNI config |
| 4 | | `kubectl get nodes` → **all Ready** |
| 5 | `install-gitlab.sh` runs | GitLab schedules onto the infra nodes |

**Step 2 blocks `terraform apply`.** An EKS managed node group does not reach
`ACTIVE` until its nodes are Ready, so the apply sits there — that is the
window Cilium has to be installed into. Two ways to handle it:

```bash
# One command, does the whole thing:
./bin/bootstrap.sh

# Or by hand, in two terminals:
#   terminal 1 -- stage 1
terraform -chdir=../terraform-karpenter-nodepools apply -target=module.karpenter
#   terminal 2, once `kubectl get nodes` shows NotReady
./bin/install-cilium.sh
#   terminal 1 -- stage 2, once stage 1 returns
terraform -chdir=../terraform-karpenter-nodepools apply
```

The `-target` on stage 1 is load-bearing, not a shortcut. Karpenter's
NodePools are submitted with `kubernetes_manifest`, which resolves the CRD
against the live API server at **plan** time — and the CRDs only arrive with
the Karpenter Helm release. A single `terraform apply` on a new cluster fails
at plan with `Failed to construct REST client`. Stage 1 builds the cluster and
the CRDs; stage 2 plans cleanly against them.

`bootstrap.sh` starts the apply in the background, waits for the first node to
register, prints the NotReady state, installs Cilium, waits for the apply to
finish, then installs GitLab.

---

## Scripts

| Script | Does |
|---|---|
| `bin/bootstrap.sh` | apply → Cilium → GitLab, in order. `--skip-gitlab`, `--plan-only` |
| `bin/install-cilium.sh` | installs/upgrades Cilium. `--dry-run`, `--from-terraform` |
| `bin/install-gitlab.sh` | namespace + 4 secrets + GitLab. `--wait`, `--dry-run`, `--secrets-only` |
| `bin/render-values.sh` | renders `values/` into `.rendered/` without installing |
| `bin/pull-charts.sh` | re-downloads the charts and refreshes `SHA256SUMS` |

`install-cilium.sh` reads the cluster's details **from the AWS API**, not from
Terraform outputs. It normally runs while the apply is still in flight, when
the state file on disk is stale and locked. `install-gitlab.sh` runs after the
apply and does read `terraform output`, because the RDS address, the generated
passwords and the bucket names are Terraform's decisions and cannot be
reconstructed from AWS alone.

---

## Day-2

Both are ordinary Helm releases:

```bash
helm -n kube-system list
helm -n gitlab history gitlab
helm -n gitlab rollback gitlab 3
```

To change a value: edit `values/cilium.values.yaml` or
`values/gitlab.values.yaml`, then re-run the matching install script — they are
`helm upgrade --install`, so they are the upgrade path too. To preview first:

```bash
./bin/render-values.sh gitlab
helm -n gitlab diff upgrade gitlab charts/gitlab-10.4.0.tgz \
  -f .rendered/gitlab.values.yaml      # needs the helm-diff plugin
```

To bump a chart version: set `CILIUM_CHART_VERSION` / `GITLAB_CHART_VERSION`
in `bin/lib.sh`, run `bin/pull-charts.sh`, commit the new `.tgz`, then upgrade.

Neither script uses `--atomic`, on purpose. Rolling Cilium back on failure
would remove the only CNI on the cluster, and rolling GitLab back part-way
through a schema migration is worse than a stuck install. If an install fails,
it stays failed and visible.

---

## Switching back to Terraform-managed

The `helm_release` resources still exist, behind two variables:

```hcl
cilium_install_method = "terraform"
gitlab_install_method = "terraform"
```

With those set, Terraform owns the releases again and these scripts refuse to
run. The values in `values/*.yaml` are a direct transcription of the values
blocks in `modules/cilium` and `modules/gitlab` — **if you change one, change
both**,
otherwise flipping the switch silently changes the cluster.

---

## Notes

- **GitLab secrets.** The chart expects `gitlab-postgres-password`,
  `gitlab-redis-password`, `gitlab-object-storage` and
  `gitlab-registry-storage` to already exist. `install-gitlab.sh` creates all
  four from Terraform outputs, via a 0700 temp dir so the generated passwords
  never reach `ps` output.
- **Object storage uses IRSA**, not static keys — `use_iam_profile: true`, with
  every GitLab ServiceAccount annotated with the S3 role ARN.
- **Buckets without features.** Terraform provisions `dependencyProxy` and
  `pages` buckets, but both features are off by default in the chart, so those
  buckets go unused until you enable them in `values/gitlab.values.yaml`.
- **DNS.** GitLab will not get a certificate until `gitlab_domain` is delegated
  to the Route53 zone Terraform created:
  `terraform output gitlab_nameservers`.
