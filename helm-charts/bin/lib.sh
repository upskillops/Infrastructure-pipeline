# Shared helpers for the install scripts. Sourced, not executed.
#
# Deliberately bash 3.2 compatible (no associative arrays, no `mapfile`) so
# these run unchanged on stock macOS as well as in CI containers.

set -euo pipefail

HELM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$HELM_DIR/.." && pwd)"
TF_DIR="${TF_DIR:-$REPO_ROOT/terraform-karpenter-nodepools}"
CHART_DIR="$HELM_DIR/charts"
VALUES_DIR="$HELM_DIR/values"
RENDER_DIR="$HELM_DIR/.rendered"

CILIUM_CHART_VERSION="${CILIUM_CHART_VERSION:-1.19.8}"
GITLAB_CHART_VERSION="${GITLAB_CHART_VERSION:-10.4.0}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

need() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "$c is required but not on PATH"
  done
}

# Read one output object out of the Terraform state as JSON.
#
# Note this shells into TF_DIR rather than taking a -chdir on every call, and
# that it will block if an apply is holding the state lock -- which is exactly
# why install-cilium.sh reads the cluster's details from the AWS API instead.
tf_output() {
  local name=$1
  terraform -chdir="$TF_DIR" output -json "$name" 2>/dev/null \
    || die "could not read terraform output \"$name\" from $TF_DIR -- has terraform apply run?"
}

# Substitute __TOKEN__ placeholders in a values template.
#
# Uses bash parameter expansion rather than sed so that values containing
# slashes, colons and ampersands (IAM role ARNs, container image references)
# need no escaping.
#
#   render <template> <output> KEY=value [KEY=value ...]
render() {
  local template=$1 out=$2
  shift 2

  [ -f "$template" ] || die "values template not found: $template"

  local content pair key val
  content=$(cat "$template")

  for pair in "$@"; do
    key=${pair%%=*}
    val=${pair#*=}
    content=${content//__${key}__/$val}
  done

  mkdir -p "$(dirname "$out")"
  printf '%s\n' "$content" > "$out"

  # A token that survived substitution means a missing Terraform output, and
  # would otherwise reach the cluster as a literal placeholder string.
  # Comments are stripped first so a template can document its own syntax.
  local leftover
  leftover=$(sed 's/#.*//' "$out" | grep -o '__[A-Z0-9_]\{1,\}__' | sort -u || true)
  if [ -n "$leftover" ]; then
    die "unsubstituted tokens in $out:
$leftover"
  fi
}

# Fail early rather than letting helm report a confusing "chart not found".
require_chart() {
  local path=$1
  [ -f "$path" ] || die "chart not vendored: $path
Run $HELM_DIR/bin/pull-charts.sh to download it."
}

# Point kubectl/helm at the cluster. Safe to re-run.
use_cluster() {
  local cluster=$1 region=$2
  log "Pointing kubeconfig at $cluster ($region)"
  aws eks update-kubeconfig --name "$cluster" --region "$region" >/dev/null
}

# Block until the cluster has at least `n` nodes registered in ANY state --
# including NotReady, which is the normal state before Cilium exists.
wait_for_nodes_registered() {
  local want=$1 timeout=${2:-1800} start count
  start=$(date +%s)
  log "Waiting for $want node(s) to register (NotReady is expected here)"
  while :; do
    count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "${count:-0}" -ge "$want" ]; then
      ok "$count node(s) registered"
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      die "timed out after ${timeout}s waiting for nodes to register"
    fi
    sleep 10
  done
}
