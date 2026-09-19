# EKS + Graviton node groups + Karpenter + Cilium

Provisions a VPC, an EKS cluster, **Cilium as the sole CNI**, four **Graviton
(arm64) EC2 managed node groups**, and three **Karpenter NodePools** that burst
above them.

```
.
├── vpc.tf            # VPC, public/private subnets, NAT per AZ
├── eks.tf            # EKS control plane ONLY (no compute -- see below)
├── cilium.tf         # Cilium: replaces VPC CNI *and* kube-proxy
├── nodegroups.tf     # 4 Graviton managed node groups (the per-tier floor)
├── addons.tf         # CoreDNS, Pod Identity agent, EBS CSI + gp3 StorageClass
├── karpenter.tf      # Karpenter controller (burst above the floor)
├── main.tf           # the 3 Karpenter NodePools
├── providers.tf      # exec-based EKS auth
├── aws-lbc.tf        # AWS Load Balancer Controller (NLB for the GitLab Gateway)
├── gitlab.tf              # GitLab + bundled Runner Helm release
├── gitlab-datastores.tf   # RDS PostgreSQL 17 + ElastiCache Redis (Graviton)
├── gitlab-storage.tf      # 12 S3 buckets + IRSA
├── gitlab-dns.tf          # Route53 zone + external-dns
├── iam-existing-cluster.tf   # node IAM role, only when create_cluster = false
└── modules/karpenter-nodepool/   # 1 EC2NodeClass + 1 NodePool
```

## Tiers

Each tier is **half managed node group, half Karpenter**. Both halves carry the
same `workload=<tier>:NoSchedule` taint and `workload=<tier>` label, so the
scheduler treats them as interchangeable: the node group guarantees a floor,
Karpenter supplies everything above it.

| Tier         | Node group (floor)                        | min → max | Karpenter burst          | Capacity          |
|--------------|-------------------------------------------|-----------|--------------------------|-------------------|
| `core`       | `m7g.large`, `m8g.large`                  | 2 → 4     | none (untainted)         | on-demand         |
| `infra`      | `m7g.xlarge`, `m8g.xlarge`, `c7g.2xlarge` | 3 → 10    | `c`/`m`, large–2xlarge   | spot + on-demand  |
| `app`        | `m7g.xlarge`, `m8g.xlarge`, `r7g.xlarge`  | 3 → 30    | `m`/`r`, large–4xlarge   | on-demand         |
| `monitoring` | `r7g.xlarge`, `r8g.xlarge`, `m7g.2xlarge` | 2 → 8     | `r`/`m`, large–2xlarge   | on-demand         |

`core` is deliberately **untainted**: CoreDNS, the Cilium operator, the EBS CSI
controller and Karpenter itself ship without tolerations for a custom taint, and
Karpenter cannot manage the nodes it runs on.

`infra` has a floor of 3 because it hosts GitLab, which is stateful. With
`enable_gitlab = false` you can drop it back to 0 and let the tier run purely
on Karpenter.

To land a pod on a tier, set both a nodeSelector and a toleration:

```yaml
nodeSelector:
  workload: app
tolerations:
  - key: workload
    operator: Equal
    value: app
    effect: NoSchedule
```

## Graviton

Everything is arm64. Node groups use `AL2023_ARM_64_STANDARD`; the NodePools
pin `kubernetes.io/arch: arm64` plus `instance-generation > 6`, which resolves
to the 7g/8g families (`c7g`/`c8g`, `m7g`/`m8g`, `r7g`/`r8g`). **Your container
images must be arm64 or multi-arch.**

## Cilium

Cilium is the **only** CNI: there is no `vpc-cni` addon and no `kube-proxy`
addon. Module v21 sets `bootstrap_self_managed_addons = false`, so the cluster
starts with no networking at all and Cilium fills the gap.

- `ipam.mode=eni` + `routingMode=native` — every pod gets a **real VPC IP**, no overlay.
- `kubeProxyReplacement=true` — eBPF service handling instead of iptables.
- `awsEnablePrefixDelegation=true` — /28 prefixes per ENI, so pods-per-node is not the bottleneck.
- Hubble on, Hubble UI off.

### Why node groups are not inside the EKS module call

With Cilium as the sole CNI there is no VPC CNI to make a joining node `Ready`,
so Cilium must be installed *between* the control plane and the first node.
Terraform cannot order a `helm_release` between a module's cluster and that same
module's inline `eks_managed_node_groups` — a `depends_on` there is a cycle,
because the Helm provider is configured from that module's outputs. Splitting
compute into `nodegroups.tf` makes the order explicit:

```
control plane → cilium (wait=false) → node groups → addons → karpenter → nodepools
```

Cilium is installed with `wait = false` on purpose: at that point the cluster has
zero nodes, so nothing can become Ready and waiting would deadlock. The node
groups' own "wait for ACTIVE" is what proves networking actually works.

The usual ENI-mode deadlock — the agent can't assign pod IPs until the operator
attaches ENIs, but a normal Deployment needs a pod IP to start — is avoided
because the chart defaults `operator.hostNetwork=true`.

### Pod IPs need subnet space

Real VPC IPs mean pod density is bounded by subnet size, not by an overlay. The
private subnets are therefore `/20` (4091 usable each), not `/24`.

## Usage

```bash
terraform init
terraform plan
terraform apply
```

Then:

```bash
$(terraform output -raw configure_kubectl)

kubectl get nodes -L workload,node-role,kubernetes.io/arch
kubectl get nodepools,ec2nodeclasses
kubectl -n kube-system get ds cilium
kubectl -n kube-system get ds aws-node kube-proxy   # expect NotFound: Cilium replaced both
```

Expected wall-clock for a cold apply is roughly **18–22 minutes**, of which
~10 is the EKS control plane — an AWS-side floor no Terraform change can move.

## Notes

- **Auth.** The providers shell out to `aws eks get-token` rather than using
  `data.aws_eks_cluster_auth`. That data source mints a token EKS honours for
  only 15 minutes, resolved early in the graph — on an apply this long,
  everything Kubernetes-related past ~minute 15 failed with `401 Unauthorized`.
  `aws` CLI v2 must be on `PATH` for Terraform.
- **Karpenter replicas vs core size.** The Karpenter chart applies a *required*
  podAntiAffinity on hostname, and the release uses `wait = true`. Keep
  `workload_node_groups["core"].desired_size >= replicas` (both 2 by default).
- **Auth mode.** `API_AND_CONFIG_MAP` with
  `enable_cluster_creator_admin_permissions`, so whoever runs `terraform apply`
  gets cluster-admin. EKS creates the access entry for the managed node group
  role automatically; Karpenter's node role gets its own via the submodule.
- **Node IAM roles carry no `AmazonEKS_CNI_Policy`.** With VPC CNI gone, only
  the `cilium-operator` IRSA role may manipulate ENIs.
- **Why IRSA for Cilium and Pod Identity for Karpenter.** Pod Identity needs a
  DaemonSet agent on a Ready node — impossible before the CNI exists. IRSA is
  served by the control plane, so it works during bootstrap. Karpenter is
  installed after nodes exist, so it uses Pod Identity (the v21 default).
- **EBS CSI** (`enable_ebs_csi_driver`, default `true`) is slightly beyond a
  pure networking/compute refactor, but the monitoring tier cannot bind a PVC
  for Prometheus/Loki without it. It also creates a default `gp3` StorageClass.

## GitLab

`enable_gitlab = true` installs GitLab, its bundled Runner, cert-manager and
Envoy Gateway onto the **infra** node group, with AWS-managed datastores behind
it. Set `gitlab_domain` and `gitlab_acme_email` in `terraform.tfvars` first.

```
browser ──HTTPS──> NLB (AWS LB Controller, ip targets)
                     └─> Envoy Gateway ──> webservice / registry / kas
                                             │
                       RDS PostgreSQL 17 <───┤
                       ElastiCache Redis <───┤
                       S3 x12 (IRSA)     <───┘
```

| Piece | What runs it |
|---|---|
| GitLab, Runner manager, cert-manager, Envoy Gateway | infra **managed node group** (on-demand) |
| CI job pods | `workload=infra` — may burst onto the Karpenter infra pool, **including spot** |
| PostgreSQL | RDS `db.m7g.large`, PG 17, private subnets |
| Redis | ElastiCache `cache.m7g.large`, TLS + AUTH |
| Object storage | 12 S3 buckets, accessed via IRSA (no static keys) |

### Chart v10 changed the rules

- **PostgreSQL, Redis and object storage are no longer bundled.** Chart v10.0.0
  deleted those subcharts and refuses to render without external ones. They are
  provisioned in `gitlab-datastores.tf` and `gitlab-storage.tf`.
- **PostgreSQL 17 is the floor.** The chart's own NOTES.txt states it; PG 16
  fails the migration job.
- **Ingress is Gateway API, not nginx.** The chart ships Envoy Gateway and
  creates a `Gateway` plus `HTTPRoute`s. `nginx-ingress` is off by default.
- **The Runner ships inside the chart** (`gitlab-runner.install = true`) and
  self-registers, so there is no registration token to fetch by hand.

### Graviton

Every GitLab image is multi-arch and runs on arm64 — verified against the
registry for all 21 images the chart pulls. The one exception is the Runner's
**helper** image, which is published per-architecture rather than as a manifest
list. `gitlab_runner_helper_image` therefore pins the `arm64-` tag; with the
default `x86_64-` tag every CI job would die with `exec format error`.

### Why GitLab is pinned to the managed node group, not the whole tier

GitLab components select on `eks.amazonaws.com/nodegroup = <cluster>-infra`
rather than `workload: infra`. Gitaly owns the EBS volume holding your git
repositories, so it must not land on the Karpenter infra pool, which includes
spot. CI job pods are the opposite case — short-lived and restartable — so they
select on `workload: infra` and are free to use spot.

This is also why `workload_node_groups["infra"]` has a floor of 3 rather than 0.

### First run

```bash
terraform apply

# 1. Delegate the domain at your registrar:
terraform output gitlab_nameservers

# 2. Watch the install (runs asynchronously by default):
kubectl -n gitlab get pods -w

# 3. Get the initial root password, then rotate it:
terraform output -raw gitlab_root_password_command | bash
```

Then open `https://gitlab.<your-domain>`. The certificate appears once DNS
delegation has propagated and Let's Encrypt completes its HTTP01 challenge;
until then the Gateway serves a self-signed cert.

Expect **~20 min** for the cluster and a further **10-20 min** for GitLab to
settle (migrations plus ~20 image pulls). `gitlab_wait_for_rollout = true`
makes `terraform apply` block on it instead.

### Cost

GitLab adds roughly **$150-250/month**: RDS `db.m7g.large` (~$125 with storage),
ElastiCache `cache.m7g.large` (~$90), an NLB (~$20), S3, plus the larger infra
floor. `gitlab_db_multi_az = true` roughly doubles the database line.

## Free-plan accounts

If `terraform apply` leaves node groups stuck in `CREATING` and the ASG
activity log shows:

```
InvalidParameterCombination - The specified instance type is not eligible
for Free Tier.
```

the account is on AWS's **Free** account plan, which refuses any EC2 instance
type outside this allowlist:

| | |
|---|---|
| x86_64 | `t3.micro`, `t3.small`, `t8i.micro`, `t8i.small`, `c7i-flex.large`, `m7i-flex.large` |
| **arm64** | **`t4g.micro` (1 GiB), `t4g.small` (2 GiB)** — the only Graviton options |

The cap is on instance types only — the EKS control plane, NAT gateways and
other paid resources create normally, which is why the cluster reaches ACTIVE
while no node ever joins.

```bash
terraform apply -var-file=free-tier.tfvars
```

That profile drops to `t4g.small` nodes, one NAT gateway, a single Karpenter
and Cilium-operator replica, and only the `core` and `infra` tiers. Karpenter's
generation floor moves from 6 to 3, because `t4g` is generation 4.

**GitLab cannot run under this plan** and the profile disables it. It needs
~12–16 GiB across its components; the ceiling here is 2 GiB per node, and
RDS/ElastiCache are capped to micro classes by the same restriction.

To lift the cap: **Billing and Cost Management → Account plan → upgrade to
Paid**. That is a billing change, not a Terraform one — afterwards use
`terraform.tfvars` and every value reverts to its normal default.

## `create_cluster = false`

Attaches only the three NodePools plus a Karpenter node IAM role to an existing
cluster. It assumes that cluster already has a working CNI, a Karpenter
controller, and `karpenter.sh/discovery` tags on its subnets and security
groups. Cilium and the node groups are skipped — swapping the CNI on a live
cluster is a migration, not a create.

## Rollback

The pre-refactor configuration is preserved in `.backup-pre-refactor/`.
