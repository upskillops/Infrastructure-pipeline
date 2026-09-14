# EKS Private Cluster with Fargate – Terraform (Self-Managed Modules)

## Architecture

- **VPC** – Custom VPC with public + private subnets across 3 AZs
- **NAT Gateways** – One per AZ (HA) or single (cost-saving)
- **VPC Endpoints** – Interface endpoints for ECR, CloudWatch, STS, ELB, and more; S3 gateway endpoint
- **EKS Cluster** – Private control plane (no public endpoint by default)
- **Fargate Profiles** – Pods run serverless; no EC2 nodes to manage
- **KMS Encryption** – Kubernetes secrets encrypted at rest
- **IRSA** – OIDC provider for IAM Roles for Service Accounts
- **EKS Add-ons** – VPC CNI, CoreDNS, kube-proxy, EBS CSI Driver

## Prerequisites

- Terraform >= 1.6
- AWS CLI >= 2.x configured
- `kubectl` (optional, for post-deploy verification)

## Quick Start

```bash
# 1. Clone / copy this directory
cd eks-fargate

# 2. Copy and edit the example variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# 3. Init, plan, apply
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# 4. Configure kubectl (from a machine with VPC access or via VPN/bastion)
aws eks update-kubeconfig \
  --region us-east-1 \
  --name private-eks-fargate

# 5. Verify
kubectl get nodes
kubectl get pods -A
```

## Module Structure

```
eks-fargate/
├── main.tf                  # Root: wires modules together
├── variables.tf             # Root: input variables
├── outputs.tf               # Root: outputs
├── terraform.tfvars.example # Example values
└── modules/
    ├── vpc/                 # VPC, subnets, NAT GW, VPC endpoints
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── eks/                 # EKS cluster, IAM roles, security groups, add-ons
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    └── fargate/             # Fargate profiles
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

## Key Design Decisions

| Decision | Why |
|---|---|
| Private endpoint only | No API server exposed to internet; access via VPN or bastion |
| VPC Interface Endpoints | Fargate pods pull from ECR without internet; no data egress cost |
| KMS secrets encryption | Meets common compliance requirements (SOC 2, PCI) |
| Per-AZ NAT Gateways | Avoids cross-AZ data transfer costs and AZ failure blast radius |
| IRSA (OIDC) | Pods get fine-grained AWS permissions without EC2 instance profiles |

## Accessing a Private Cluster

Since `endpoint_public_access = false`, kubectl must run inside the VPC:

1. **AWS Systems Manager Session Manager** – use `aws ssm start-session` on a bastion EC2 in the VPC
2. **VPN** – site-to-site or client VPN to the VPC
3. **AWS Cloud9** – IDE running inside a private subnet
4. **Temporary public access** – set `endpoint_public_access = true` and `public_access_cidrs = ["<your-ip>/32"]` for bootstrapping, then disable

## Notes

- CoreDNS add-on sets `computeType: Fargate` so it schedules on Fargate pods (not EC2)
- The `aws-auth` ConfigMap is managed by Terraform; avoid manual edits
- All Fargate pods run in private subnets; the NAT Gateway provides outbound internet access
