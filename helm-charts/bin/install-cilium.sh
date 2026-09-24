#!/usr/bin/env bash
#
# Install (or upgrade) Cilium from the vendored chart. This is the step that
# takes the cluster's nodes from NotReady to Ready.
#
#   ./bin/install-cilium.sh
#   ./bin/install-cilium.sh --cluster my-eks-cluster --region us-east-1
#   ./bin/install-cilium.sh --dry-run
#
# WHY THIS DOES NOT READ TERRAFORM OUTPUTS BY DEFAULT
# ---------------------------------------------------
# The normal time to run this is *while* `terraform apply` is still going --
# the node groups are created, their nodes have joined NotReady, and the apply
# is blocked waiting for them to reach Ready. At that moment the state file on
# disk is stale and the state is locked, so `terraform output` is unreliable.
# Everything needed is instead derived from the AWS API, which is authoritative
# and available immediately. Pass --from-terraform for a day-2 run against a
# quiet state file.

. "$(dirname "$0")/lib.sh"

need helm kubectl aws jq

CLUSTER="${CLUSTER_NAME:-}"
REGION="${AWS_REGION:-}"
SOURCE=aws
DRY_RUN=0
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15m}"
NODE_READY_TIMEOUT="${NODE_READY_TIMEOUT:-600}"

while [ $# -gt 0 ]; do
  case $1 in
    -c|--cluster)     CLUSTER=$2; shift 2 ;;
    -r|--region)      REGION=$2; shift 2 ;;
    --from-terraform) SOURCE=terraform; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        sed -n '2,25p' "$0"; exit 0 ;;
    *)                die "unknown argument: $1" ;;
  esac
done

# Fall back to terraform.tfvars, which is readable regardless of state locks.
tfvar() {
  [ -f "$TF_DIR/terraform.tfvars" ] || return 0
  grep -E "^[[:space:]]*$1[[:space:]]*=" "$TF_DIR/terraform.tfvars" \
    | head -1 | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/'
}
[ -n "$CLUSTER" ] || CLUSTER=$(tfvar cluster_name)
[ -n "$REGION" ]  || REGION=$(tfvar aws_region)
[ -n "$CLUSTER" ] || die "cluster name not given: pass --cluster or set CLUSTER_NAME"
[ -n "$REGION" ]  || REGION=us-east-1

# Refuse to run when Terraform owns the release.
#
# `cilium_install_method` defaults to "terraform" now, which means the common
# case is that `terraform apply` has already installed Cilium and running this
# script would fight it over the same Helm release. The --from-terraform path
# below catches that from the state file, but the default path reads the AWS
# API and would not, so the check has to happen here as well.
#
# tfvars is the only source readable while an apply holds the state lock, and
# an unset value means the variable default -- which is "terraform". So the
# script proceeds only when tfvars says "helm" explicitly.
INSTALL_METHOD=$(tfvar cilium_install_method || true)
if [ "${INSTALL_METHOD:-terraform}" != "helm" ]; then
  die "cilium_install_method is \"${INSTALL_METHOD:-terraform (unset, so the default)}\".
Terraform installs Cilium itself under that setting, and installing it again
here would fight over the same Helm release.

This script is only for cilium_install_method = \"helm\". If that is what you
want, set it explicitly in $TF_DIR/terraform.tfvars and re-apply; otherwise
just let \`terraform apply\` do it."
fi

CHART="$CHART_DIR/cilium-${CILIUM_CHART_VERSION}.tgz"
require_chart "$CHART"

###############################################################################
# Gather the six values the chart needs from this cluster
###############################################################################

if [ "$SOURCE" = terraform ]; then
  log "Reading values from terraform output"
  J=$(tf_output helm_cilium_values)
  [ "$J" != "null" ] || die "helm_cilium_values is null -- install_cilium is false."

  if [ "$(echo "$J" | jq -r .installed_by_terraform)" = "true" ]; then
    die "cilium_install_method is \"terraform\": the release is already owned by
Terraform, and installing it again here would fight over the same Helm
release. Set cilium_install_method = \"helm\" and re-apply first."
  fi
  OPERATOR_ROLE_ARN=$(echo "$J" | jq -r .operator_role_arn)
  VPC_CIDR=$(echo "$J"          | jq -r .vpc_cidr)
  K8S_SERVICE_HOST=$(echo "$J"  | jq -r .k8s_service_host)
  OPERATOR_REPLICAS=$(echo "$J" | jq -r .operator_replicas)
  PREFIX_DELEGATION=$(echo "$J" | jq -r .prefix_delegation)
  HUBBLE_RELAY=$(echo "$J"      | jq -r .hubble_relay)
else
  log "Describing cluster $CLUSTER from the AWS API"
  DESC=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --output json) \
    || die "cluster $CLUSTER not found in $REGION"

  # With kube-proxy gone, Cilium cannot reach the API server through the
  # kubernetes.default ClusterIP -- nothing would translate it. It needs the
  # real endpoint host, without the scheme.
  K8S_SERVICE_HOST=$(echo "$DESC" | jq -r .cluster.endpoint | sed 's|^https://||')

  VPC_ID=$(echo "$DESC" | jq -r .cluster.resourcesVpcConfig.vpcId)
  VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" \
    --query 'Vpcs[0].CidrBlock' --output text)

  # Created by aws_iam_role.operator in modules/cilium. The name is derived
  # from the cluster name there, so it is predictable without reading state.
  OPERATOR_ROLE_ARN=$(aws iam get-role --role-name "${CLUSTER}-cilium-operator" \
    --query 'Role.Arn' --output text 2>/dev/null) \
    || die "IAM role ${CLUSTER}-cilium-operator not found.
Terraform creates it; let the apply get past the IAM stage before running this."

  # Not discoverable from AWS -- these are chart tuning, not cluster facts.
  # Defaults match the Terraform variable defaults.
  OPERATOR_REPLICAS="${OPERATOR_REPLICAS:-2}"
  PREFIX_DELEGATION="${PREFIX_DELEGATION:-true}"
  HUBBLE_RELAY="${HUBBLE_RELAY:-true}"
fi

ok "api server      $K8S_SERVICE_HOST"
ok "vpc cidr        $VPC_CIDR"
ok "operator role   $OPERATOR_ROLE_ARN"

render "$VALUES_DIR/cilium.values.yaml" "$RENDER_DIR/cilium.values.yaml" \
  "OPERATOR_ROLE_ARN=$OPERATOR_ROLE_ARN" \
  "VPC_CIDR=$VPC_CIDR" \
  "K8S_SERVICE_HOST=$K8S_SERVICE_HOST" \
  "OPERATOR_REPLICAS=$OPERATOR_REPLICAS" \
  "PREFIX_DELEGATION=$PREFIX_DELEGATION" \
  "HUBBLE_RELAY=$HUBBLE_RELAY"
ok "rendered        .rendered/cilium.values.yaml"

if [ "$DRY_RUN" = 1 ]; then
  log "Dry run -- rendering manifests only"
  helm template cilium "$CHART" \
    --namespace kube-system \
    --values "$RENDER_DIR/cilium.values.yaml"
  exit 0
fi

###############################################################################
# Install
###############################################################################

use_cluster "$CLUSTER" "$REGION"

log "Nodes before install"
kubectl get nodes -o wide 2>/dev/null >&2 || warn "no nodes registered yet"

# The nodes have to exist before the install is worth doing: cilium-agent is a
# DaemonSet, and on an empty cluster it would schedule nowhere and --wait would
# simply time out.
wait_for_nodes_registered 1

log "helm upgrade --install cilium (chart $CILIUM_CHART_VERSION)"
# --wait, but deliberately NOT --atomic. A rollback here would uninstall the
# only CNI on the cluster, turning a slow install into a broken one. If this
# times out, leave the release in place and debug it with
# `kubectl -n kube-system logs ds/cilium`.
helm upgrade --install cilium "$CHART" \
  --namespace kube-system \
  --values "$RENDER_DIR/cilium.values.yaml" \
  --wait --timeout "$WAIT_TIMEOUT"

###############################################################################
# Verify -- this is the NotReady -> Ready transition the whole order exists for
###############################################################################

log "Waiting for every node to report Ready"
kubectl wait --for=condition=Ready nodes --all --timeout="${NODE_READY_TIMEOUT}s"

ok "Nodes Ready:"
kubectl get nodes >&2

log "Confirming Cilium really is the only CNI"
kubectl -n kube-system get daemonset cilium >&2
if kubectl -n kube-system get daemonset aws-node kube-proxy >/dev/null 2>&1; then
  warn "aws-node and/or kube-proxy still present -- Cilium is not the sole CNI"
else
  ok "no aws-node, no kube-proxy"
fi

ok "Cilium installed. Manage it from here with plain helm:"
printf '      helm -n kube-system list\n' >&2
printf '      helm -n kube-system upgrade cilium %s -f %s/cilium.values.yaml\n' "$CHART" "$RENDER_DIR" >&2
