#!/usr/bin/env bash
#
# End-to-end bootstrap: terraform apply, then Cilium, then GitLab.
#
#   ./bin/bootstrap.sh
#   ./bin/bootstrap.sh --skip-gitlab
#   ./bin/bootstrap.sh --plan-only
#
# THE PROBLEM THIS SOLVES
# -----------------------
# Under cilium_install_method = "helm" nothing installs a CNI during the
# apply. Nodes join the cluster and stay NotReady, and an EKS managed node
# group does not reach ACTIVE until its nodes are Ready -- so `terraform
# apply` sits and waits, and would eventually fail, unless something installs
# Cilium in the meantime.
#
# That "something" is this script. It starts the apply in the background,
# watches for the first node to register, installs Cilium into the NotReady
# window, and then waits for the apply to complete now that the nodes can go
# Ready. Doing it by hand is the same thing in two terminals:
#
#   terminal 1:  terraform apply -target=module.karpenter   # stage 1
#   terminal 2:  ./bin/install-cilium.sh     # once `kubectl get nodes` shows NotReady
#   terminal 1:  terraform apply                              # stage 2
#
# WHY TWO STAGES
# --------------
# Karpenter's NodePools are submitted with kubernetes_manifest, which resolves
# the CRD against the live API server at PLAN time. The CRDs arrive with the
# Karpenter Helm release, so a single `terraform apply` on a new cluster fails
# at plan. Stage 1 (-target=module.karpenter) builds the cluster and installs
# the CRDs; stage 2 plans cleanly against them. See the header of
# terraform-karpenter-nodepools/modules/karpenter-nodepool/main.tf.

. "$(dirname "$0")/lib.sh"

need terraform helm kubectl aws jq

SKIP_GITLAB=0
PLAN_ONLY=0
APPLY_ARGS="-auto-approve"

while [ $# -gt 0 ]; do
  case $1 in
    --skip-gitlab) SKIP_GITLAB=1; shift ;;
    --plan-only)   PLAN_ONLY=1; shift ;;
    -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
done

tfvar() {
  [ -f "$TF_DIR/terraform.tfvars" ] || return 0
  grep -E "^[[:space:]]*$1[[:space:]]*=" "$TF_DIR/terraform.tfvars" \
    | head -1 | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/'
}
CLUSTER="${CLUSTER_NAME:-$(tfvar cluster_name)}"
REGION="${AWS_REGION:-$(tfvar aws_region)}"
[ -n "$CLUSTER" ] || die "could not determine cluster_name from $TF_DIR/terraform.tfvars"
[ -n "$REGION" ]  || REGION=us-east-1

require_chart "$CHART_DIR/cilium-${CILIUM_CHART_VERSION}.tgz"
[ "$SKIP_GITLAB" = 1 ] || require_chart "$CHART_DIR/gitlab-${GITLAB_CHART_VERSION}.tgz"

###############################################################################
# 0. Plan
###############################################################################

log "terraform init"
terraform -chdir="$TF_DIR" init -input=false >/dev/null

# -target is load-bearing, not a shortcut: see WHY TWO STAGES above.
log "terraform plan (stage 1: cluster, nodes, addons, Karpenter CRDs)"
terraform -chdir="$TF_DIR" plan -input=false \
  -target=module.karpenter -out="$TF_DIR/.bootstrap.tfplan"

if [ "$PLAN_ONLY" = 1 ]; then
  ok "Plan only -- stopping here."
  exit 0
fi

printf '\n' >&2
warn "About to apply the plan above and create real AWS infrastructure"
warn "(VPC, EKS cluster, 4 node groups, RDS, ElastiCache, 12 S3 buckets)."
printf '    Continue? [y/N] ' >&2
read -r REPLY
case "$REPLY" in
  y|Y|yes|YES) ;;
  *) die "aborted" ;;
esac

###############################################################################
# 1. Apply, in the background
###############################################################################

APPLY_LOG="$HELM_DIR/.rendered/terraform-apply.log"
mkdir -p "$(dirname "$APPLY_LOG")"

log "terraform apply, stage 1 (background) -- log: $APPLY_LOG"
terraform -chdir="$TF_DIR" apply -input=false "$TF_DIR/.bootstrap.tfplan" > "$APPLY_LOG" 2>&1 &
TF_PID=$!

# If we die for any reason, do not leave an orphaned apply mutating AWS.
cleanup() {
  if kill -0 "$TF_PID" 2>/dev/null; then
    warn "stopping background terraform apply (pid $TF_PID)"
    kill -INT "$TF_PID" 2>/dev/null || true
    wait "$TF_PID" 2>/dev/null || true
  fi
}
trap cleanup INT TERM

apply_alive() { kill -0 "$TF_PID" 2>/dev/null; }

apply_died() {
  warn "terraform apply exited early -- last 40 lines:"
  tail -40 "$APPLY_LOG" >&2
  die "$1"
}

###############################################################################
# 2. Wait for the control plane
###############################################################################

log "Waiting for EKS cluster $CLUSTER to become ACTIVE (usually ~10 minutes)"
while :; do
  STATUS=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
    --query 'cluster.status' --output text 2>/dev/null || echo PENDING)
  [ "$STATUS" = ACTIVE ] && break
  apply_alive || apply_died "cluster never became ACTIVE"
  sleep 20
done
ok "control plane ACTIVE"

use_cluster "$CLUSTER" "$REGION"

###############################################################################
# 3. Wait for the first node -- it will be NotReady, and that is the point
###############################################################################

log "Waiting for the first node to register"
while :; do
  COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "${COUNT:-0}" -ge 1 ] && break
  apply_alive || apply_died "no node ever registered"
  sleep 10
done

printf '\n' >&2
ok "Nodes have joined. This is the expected pre-Cilium state:"
kubectl get nodes >&2
printf '\n' >&2
warn "Every node is NotReady: there is no CNI on this cluster yet, so the"
warn "kubelet has no /etc/cni/net.d and refuses to accept pods. terraform"
warn "apply is now blocked waiting for these to go Ready."
printf '\n' >&2

###############################################################################
# 4. Install Cilium -- the NotReady -> Ready transition
###############################################################################

"$HELM_DIR/bin/install-cilium.sh" --cluster "$CLUSTER" --region "$REGION"

###############################################################################
# 5. Let the apply finish now that nodes can reach Ready
###############################################################################

log "Waiting for terraform apply to finish (node groups, addons, RDS, S3, ...)"
trap - INT TERM
set +e
wait "$TF_PID"
TF_RC=$?
set -e
if [ "$TF_RC" -ne 0 ]; then
  warn "terraform apply failed (exit $TF_RC) -- last 40 lines:"
  tail -40 "$APPLY_LOG" >&2
  die "fix the apply, re-run \`terraform -chdir=$TF_DIR apply\`, then run bin/install-gitlab.sh"
fi
ok "terraform apply stage 1 complete"
rm -f "$TF_DIR/.bootstrap.tfplan"

###############################################################################
# 5b. Stage 2 -- everything that could not be planned until the CRDs existed
###############################################################################

log "terraform apply, stage 2 (Karpenter NodePools, ingress, GitLab's AWS side)"
# tee swallows terraform's exit code, so take it from PIPESTATUS -- captured
# on the very next line, because any other command in between resets it.
terraform -chdir="$TF_DIR" apply -input=false -auto-approve 2>&1 | tee -a "$APPLY_LOG" | tail -5
STAGE2_RC=${PIPESTATUS[0]}
[ "$STAGE2_RC" -eq 0 ] || die "stage 2 apply failed (exit $STAGE2_RC) -- see $APPLY_LOG"
ok "terraform apply stage 2 complete"

###############################################################################
# 6. GitLab
###############################################################################

if [ "$SKIP_GITLAB" = 1 ]; then
  ok "Skipping GitLab. Install it later with ./bin/install-gitlab.sh"
  exit 0
fi

"$HELM_DIR/bin/install-gitlab.sh"

printf '\n' >&2
ok "Bootstrap complete. Both charts are now ordinary Helm releases:"
printf '      helm -n kube-system list\n' >&2
printf '      helm -n gitlab list\n' >&2
