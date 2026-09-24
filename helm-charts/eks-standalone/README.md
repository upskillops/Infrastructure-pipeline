# GitLab on EKS — self-contained

One `helm` command, from a chart archive committed in this repo. No Terraform
outputs, no RDS, no ElastiCache, no S3, no placeholder rendering.

This is the EKS counterpart of the on-prem install in
[`../../gitlab-helm/onprem/`](../../gitlab-helm/onprem/) — same idea, AWS
plumbing instead of MetalLB/Longhorn/Istio.

> **This is not the production path.** That is [`../README.md`](../README.md):
> chart 10.4.0 against Terraform-provisioned RDS, ElastiCache and S3, with
> IRSA and Envoy Gateway. The two are independent — installing this one
> touches nothing that one owns. Use this for a dev cluster, an evaluation, or
> when you want GitLab on EKS without the managed-service bill.

## Chart

| | |
|---|---|
| Archive | `../charts/gitlab-9.11.12.tgz` (committed, SHA in `../charts/SHA256SUMS`) |
| Version | 9.11.12 / GitLab CE 18.11.11 |
| Values | `../values/gitlab-eks-standalone.yaml` |

9.11.12 is required rather than preferred. Chart 10.0.0 deleted the bundled
PostgreSQL, Redis and MinIO subcharts, so a self-contained install is only
possible on the 9.x line, and 9.11.12 is the last of it.

Everything installs from the local archive — nothing is fetched from
`charts.gitlab.io` at deploy time. To read the templates:

```bash
tar xzf ../charts/gitlab-9.11.12.tgz -C /tmp && ls /tmp/gitlab
helm show values ../charts/gitlab-9.11.12.tgz
```

## Prerequisites

Two one-time things on the cluster. Both are easy to miss and both fail
quietly — PVCs just sit `Pending`.

```bash
# 1. EBS CSI driver. EKS does not install it by default.
aws eks create-addon --cluster-name <cluster> --addon-name aws-ebs-csi-driver

# 2. The gp3 StorageClass the values reference.
kubectl apply -f storageclass-gp3.yaml
```

The CSI driver also needs IRSA permission to create volumes. If your cluster
was built by the Terraform in this repo that role already exists; otherwise
attach `AmazonEBSCSIDriverPolicy` to a role and pass
`--service-account-role-arn` on the `create-addon` call.

### Node capacity — check this first

Measured from `helm template` against the vendored chart with these values:

| | |
|---|---|
| Total requests | **2125m CPU, 8068Mi (7.9Gi)** |
| Largest single pod | `webservice` at **2595Mi** |
| Then | `sidekiq` 1500Mi, `postgresql` 1024Mi, `gitaly` 1024Mi |

Two separate limits, and the second is the one people miss:

1. The cluster needs ~8Gi allocatable in total.
2. **One node must have ≥2595Mi allocatable on its own.** A pod is scheduled
   whole; it cannot be spread. Plenty of total memory across many small nodes
   still leaves `webservice` permanently `Pending`.

Roughly 3 × `m6i.large` / `m7g.large` (8Gi each) clears both comfortably.

Check before installing:

```bash
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory'
```

Note that allocatable is well below the instance's nominal RAM — the kubelet
and system reservations take a fixed slice, which hurts proportionally more on
small instances. A `t4g.small` is nominally 2Gi but allocates about 1366Mi.

### This will not run on the free-tier cluster

`terraform-karpenter-nodepools` applied with `-var-file=free-tier.tfvars`
builds 3 × `t4g.small`:

```
3 nodes x 1366Mi allocatable = 4098Mi total
GitLab needs                   8068Mi total   -> short by ~4Gi
largest node 1366Mi  <  webservice 2595Mi     -> cannot schedule at all
```

The second line is fatal on its own: no values tuning fixes a pod that is
larger than any node. And the AWS Free plan's instance allowlist tops out at
`t4g.small` for arm64, so there is no bigger node to move to.

Running GitLab therefore means leaving the free-tier profile: use the defaults
in `variables.tf` (which include a dedicated `infra` tier of `m7g.xlarge`),
and raise the account's `L-1216C47A` vCPU quota to match.

## Install

```bash
cd ..    # helm-charts/

helm upgrade --install gitlab charts/gitlab-9.11.12.tgz \
  -n gitlab --create-namespace \
  -f values/gitlab-eks-standalone.yaml \
  --set global.hosts.domain=example.com \
  --set certmanager-issuer.email=you@example.com \
  --timeout 25m
```

Only those two `--set` values change between environments, which is why they
are on the command line instead of edited into the file.

Watch it — a first install runs ~1,400 migrations and pulls around 20 images,
so 10–20 minutes is normal:

```bash
kubectl -n gitlab get pods -w
```

## DNS

The chart creates three Ingress hosts, all on one NLB:

| Host | Serves |
|---|---|
| `gitlab.<domain>` | web UI, git over HTTPS |
| `registry.<domain>` | container registry |
| `minio.<domain>` | object storage |

Point all three at the NLB:

```bash
kubectl -n gitlab get svc gitlab-nginx-ingress-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

A CNAME each, or one wildcard `*.<domain>`. **Do this before expecting TLS
to work** — cert-manager uses an HTTP01 challenge, so Let's Encrypt has to
reach `gitlab.<domain>` over port 80 from the internet. Until DNS resolves,
the certificate stays pending and the site serves a self-signed cert.

## First login

```bash
kubectl -n gitlab get secret gitlab-gitlab-initial-root-password \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

User `root` at `https://gitlab.<domain>`. Rotate it immediately — GitLab
deletes that secret once you do.

## Networking shape

```
             NLB  (one, in-tree EKS provider)
              |
   80 / 443 / 22
              |
    nginx-ingress-controller
       |          |        \
   webservice  registry   gitlab-shell (SSH, TCP 22)
```

Worth knowing: SSH shares the same NLB. The bundled nginx controller
publishes TCP 22 and forwards it to `gitlab-shell`, so there is deliberately
no second `LoadBalancer` Service. (The on-prem install *does* give SSH its own
address, because there nginx is off and Istio fronts GitLab — an L7 gateway
cannot carry SSH.)

The NLB annotation is `aws-load-balancer-type: nlb`, the in-tree EKS cloud
provider, so this install has no dependency on the AWS Load Balancer
Controller being present. If you do run that controller, switching to
`external` + `nlb-target-type: ip` gives a real IP-target NLB.

## What you are trading away

The bundled datastores are single-replica and cluster-local:

- **No managed backups.** RDS snapshots do not exist here. Gitaly's volume and
  the PostgreSQL volume are `Retain`, so deleting the release keeps them, but
  nothing is backing them up. Schedule EBS snapshots or run GitLab's own
  backup task from the toolbox pod.
- **No failover.** One PostgreSQL pod, one Redis pod, one Gitaly pod. An AZ
  outage takes GitLab down.
- **No read replicas, no connection pooling.**

If any of that matters, use the Terraform path instead. The upgrade route is
not in-place — it is a backup, a fresh install against RDS/ElastiCache, and a
restore.

## Day 2

```bash
helm -n gitlab history gitlab
helm -n gitlab get values gitlab
helm -n gitlab rollback gitlab <revision>
```

To change sizing or enable a feature, edit
`../values/gitlab-eks-standalone.yaml` and re-run the same
`helm upgrade --install` — it is the upgrade path too.

Two things off by default that you may want:

- **GitLab Runner** (`gitlab-runner.install: true`). Left off because a first
  install has no runner token yet; turn it on after GitLab is up.
- **Prometheus** (`prometheus.install: false`). Run `kube-prometheus-stack`
  separately rather than the chart's bundled copy.
