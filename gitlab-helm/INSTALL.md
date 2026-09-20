> **Superseded by [`../helm-charts/`](../helm-charts/).**
>
> This guide describes an earlier design: nginx-ingress, static S3 access
> keys, a manually created `ClusterIssuer`, and S3 buckets created by hand.
> The current stack uses Envoy Gateway behind an NLB, IRSA instead of static
> keys, and Terraform-provisioned RDS / ElastiCache / S3. It also predates
> GitLab chart v10, which removed the bundled PostgreSQL and Redis.
>
> Kept for reference. Follow `helm-charts/README.md` instead.

# Installing GitLab on the EKS cluster

## 1. Prerequisites
- `kubectl` pointed at the cluster: `aws eks update-kubeconfig --name prod-eks --region us-east-1`
- A `gp3` StorageClass backed by the EBS CSI driver (the `eks` module
  already provisions the CSI driver + its IRSA role):
  ```bash
  kubectl apply -f storageclass-gp3.yaml
  ```
- cert-manager, if not already running cluster-wide:
  ```bash
  helm repo add jetstack https://charts.jetstack.io
  helm install cert-manager jetstack/cert-manager \
    -n cert-manager --create-namespace --set installCRDs=true
  ```
  Then create a `ClusterIssuer` named `letsencrypt-prod` (referenced in
  `values-gitlab.yaml`) - see cert-manager's ACME docs for the exact manifest.
- S3 buckets for artifacts/lfs/uploads/packages/backups (not yet in the
  Terraform repo - happy to add an `s3-buckets` module if useful).
- Real values for every `REPLACE_ME` in `values-gitlab.yaml`.

## 2. Secrets
Edit and run `secrets-example.sh` (fill in the real DB password and S3
keys first - don't commit it with real values in it):
```bash
./secrets-example.sh
```

## 3. Install
```bash
helm repo add gitlab https://charts.gitlab.io/
helm repo update

helm install gitlab gitlab/gitlab \
  -n gitlab --create-namespace \
  -f values-gitlab.yaml \
  --timeout 600s
```

First install can take 10-15 minutes (migrations, gitaly, registry, etc.
all come up). Watch progress with:
```bash
kubectl get pods -n gitlab -w
```

## 4. DNS
Point `gitlab.<your-domain>` and `registry.<your-domain>` at the NLB
hostname created by the bundled nginx-ingress Service:
```bash
kubectl get svc -n gitlab gitlab-nginx-ingress-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```
(Use the `route53` module, or add records manually/via `external-dns`.)

## 5. First login
```bash
kubectl get secret gitlab-gitlab-initial-root-password -n gitlab \
  -o jsonpath='{.data.password}' | base64 -d
```
Log in as `root` at `https://gitlab.<your-domain>`, then rotate that
password immediately.

## Notes
- **Sizing**: `values-gitlab.yaml` trims resource requests/replica counts
  to fit on `m6i.large` (2 vCPU/8GB) nodes for a first install. GitLab's
  own [reference architectures](https://docs.gitlab.com/ee/administration/reference_architectures/)
  recommend far more for real usage (1,000 users ≈ 8 vCPU/16GB minimum
  across components) - budget a dedicated node group as usage grows.
- **Istio**: this setup deliberately keeps GitLab's ingress (nginx +
  its own NLB) outside the Istio mesh used elsewhere in the cluster,
  since SSH git access, the container registry, and Pages all have
  routing needs that don't map cleanly onto HTTP-centric mesh ingress.
  It's possible to route GitLab through Istio instead, but it's
  meaningfully more setup for limited benefit here.
- **Object storage**: if you'd rather not manage static S3 keys in a
  Secret, GitLab's chart supports IRSA - annotate the relevant
  ServiceAccounts with an IAM role ARN instead of using
  `gitlab-object-storage`. Say the word if you want that wired up.
