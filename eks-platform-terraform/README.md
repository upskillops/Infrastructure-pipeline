# EKS Platform - Terraform (modular)

Terraform implementation of the reference architecture: internet-facing
NLB → private EKS cluster (Cilium CNI + Istio mesh) → RDS / ElastiCache /
OpenSearch / MSK, with VPC endpoints for private AWS API access, WAF,
Route 53, and CloudWatch/Hubble observability.

## Layout

```
modules/
  vpc/                3 public + 3 private subnets (one per AZ), IGW, NAT
                       per AZ, route tables, VPC Flow Logs
  security-groups/     NLB, EKS cluster, EKS nodes, VPC endpoints, and
                       per-data-service security groups
  vpc-endpoints/       S3 gateway endpoint + interface endpoints (ECR,
                       STS, Secrets Manager, CloudWatch, KMS, SSM, ...)
  waf/                 WAFv2 WebACL with AWS managed rule groups + rate
                       limiting (see note below on where to attach it)
  eks/                 EKS cluster (private), OIDC/IRSA provider, managed
                       node group(s), core addons, EKS access entries
  cluster-addons/      Helm releases: Cilium, Istio (base/istiod/gateways),
                       Kyverno, kube-prometheus-stack, Loki
  rds/                 PostgreSQL, Multi-AZ, encrypted, managed master
                       password in Secrets Manager
  elasticache/          Redis replication group, Multi-AZ, encrypted
  opensearch/            OpenSearch domain, VPC-only, fine-grained access
                       control
  msk/                  MSK cluster, TLS + IAM auth, encrypted
  route53/              Optional hosted zone + alias record to the
                       ingress load balancer

environments/
  prod/                Root module wiring all of the above together for
                       a single environment. Copy this folder (or add a
                       sibling `staging/`, `dev/`) to manage more envs.
```

## Design notes / things to check before you `apply`

- **Pod CIDR is intentionally not part of the VPC CIDR.** Cilium runs in
  overlay (VXLAN) mode with `ipam.mode = cluster-pool` and
  `100.64.0.0/16`, matching the reference diagram. Security groups for
  the data layer allow both the node SG and the pod CIDR, since pod
  traffic is encapsulated and doesn't show up as `eks_nodes` SG traffic
  at the ENI level in overlay mode.
- **AWS WAF cannot attach directly to a Network Load Balancer** (NLB is
  L4, WAF inspects L7). The `waf` module creates the WebACL but you must
  front it with either a CloudFront distribution (WebACL scope =
  `CLOUDFRONT`) or an ALB, per the comment in `modules/waf/main.tf`. If
  your ingress truly needs to be pure L4 passthrough to Istio, put
  CloudFront in front of the NLB and attach WAF there.
- **The EKS cluster is fully private** (`endpoint_public_access =
  false`) per the diagram (EKS cluster boxed inside the private
  subnets). This means the Terraform host running `kubectl`/Helm
  operations must have network access to the private subnets (VPN /
  Direct Connect / a bastion / CodeBuild-in-VPC), matching the "VPN /
  Direct Connect" path shown from the corporate network.
- **Two-phase apply for cluster-addons.** `modules/cluster-addons` uses
  the `helm` and `kubernetes` providers, which authenticate to the EKS
  API using an `aws eks get-token` exec plugin. On a completely fresh
  environment, run:
  1. `terraform apply -target=module.eks` (or set
     `install_cluster_addons = false` in tfvars) to stand up the cluster
     first.
  2. `terraform apply` again with `install_cluster_addons = true` to
     install Cilium/Istio/Kyverno/observability.
  This avoids provider-configuration errors from trying to talk to an
  API server that doesn't exist yet.
- **Istio ingress gateway creates its own NLB** via the Kubernetes
  `Service` (`type: LoadBalancer`, AWS Load Balancer Controller
  annotations) once the mesh is installed - that's the "Network Load
  Balancer" box in the diagram. The `route53` module is wired but
  commented out in `environments/prod/main.tf` until you plug in that
  Service's actual hostname/zone ID (or install the [external-dns]
  add-on to automate it).
- **RDS uses `manage_master_user_password = true`** (AWS-managed
  Secrets Manager secret) instead of a Terraform-supplied password, so
  no DB credentials ever live in state or tfvars.
- **Node group `desired_size` is excluded from plan diffs**
  (`lifecycle.ignore_changes`) since the Kubernetes Cluster Autoscaler
  or Karpenter will be adjusting it at runtime.

## Usage

```bash
cd environments/prod
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: account-specific ARNs, domain, AZs, etc.
# edit backend.tf: your real S3 bucket / DynamoDB table for state

terraform init
terraform apply -target=module.vpc -target=module.security_groups \
  -target=module.vpc_endpoints -target=module.eks
# (first pass: stand up networking + cluster before Helm providers need it)

terraform apply
# second pass: installs Cilium/Istio/Kyverno/observability + data layer

aws eks update-kubeconfig --name prod-eks --region us-east-1
```

## Remote state bootstrap

`backend.tf` expects an existing S3 bucket (versioned, encrypted).
State locking uses S3's native lockfile support (`use_lockfile = true`,
requires Terraform >= 1.10 and AWS provider >= 5.73) - no DynamoDB
table needed. Create the bucket once, by hand or in a separate
`bootstrap/` root, before `terraform init` here.

On Terraform < 1.10, swap `use_lockfile` for a `dynamodb_table`
attribute instead and provision that table (partition key `LockID`,
type String) - see the comment in `backend.tf`.

## Extending

- Add more node groups (e.g. a tainted Istio-gateway-only pool, or a
  Spot pool) via the `node_groups` map in `environments/prod/main.tf`.
- Additional IRSA roles (for external-dns, cert-manager, cluster
  autoscaler, the AWS Load Balancer Controller, etc.) follow the same
  pattern as the `ebs_csi` role in `modules/eks/main.tf` - one
  `aws_iam_role` + trust policy scoped to the OIDC provider and a
  `system:serviceaccount:<ns>:<sa>` subject.
- Multiple environments: duplicate `environments/prod` to
  `environments/staging`, adjust `terraform.tfvars` and the backend
  `key`.
