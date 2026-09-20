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
charts/     the pinned .tgz archives, committed, with SHA256SUMS
values/     values files with __PLACEHOLDER__ tokens -- edit these
bin/        install scripts
.rendered/  values with Terraform outputs substituted in -- generated, gitignored
```

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
#   terminal 1
terraform -chdir=../terraform-karpenter-nodepools apply
#   terminal 2, once `kubectl get nodes` shows NotReady
./bin/install-cilium.sh
```

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
