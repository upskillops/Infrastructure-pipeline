#!/usr/bin/env bash
#
# Install (or upgrade) GitLab from the vendored chart, plus the namespace and
# the four secrets the chart expects to already exist.
#
#   ./bin/install-gitlab.sh              # returns as soon as helm has applied
#   ./bin/install-gitlab.sh --wait       # block until every pod is Ready
#   ./bin/install-gitlab.sh --dry-run    # render manifests, touch nothing
#   ./bin/install-gitlab.sh --secrets-only
#
# Unlike install-cilium.sh this DOES read Terraform outputs: by the time
# GitLab can be installed the apply has finished, and the values it needs --
# the RDS address, the ElastiCache address, the generated passwords, the
# bucket names, the IRSA role ARN -- are decisions Terraform made and are not
# reconstructable from the AWS API alone.

. "$(dirname "$0")/lib.sh"

need helm kubectl aws jq terraform

WAIT=0
DRY_RUN=0
SECRETS_ONLY=0
WAIT_TIMEOUT="${WAIT_TIMEOUT:-40m}"

while [ $# -gt 0 ]; do
  case $1 in
    --wait)         WAIT=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --secrets-only) SECRETS_ONLY=1; shift ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    *)              die "unknown argument: $1" ;;
  esac
done

CHART="$CHART_DIR/gitlab-${GITLAB_CHART_VERSION}.tgz"
require_chart "$CHART"

###############################################################################
# Values from Terraform
###############################################################################

log "Reading terraform outputs from $TF_DIR"
J=$(tf_output helm_gitlab_values)
[ "$J" != "null" ] || die "helm_gitlab_values is null -- enable_gitlab is false in Terraform."

if [ "$(echo "$J" | jq -r .installed_by_terraform)" = "true" ]; then
  die "gitlab_install_method is \"terraform\": the release is already owned by
Terraform, and installing it again here would fight over the same Helm
release. Set gitlab_install_method = \"helm\" and re-apply first."
fi

CLUSTER=$(echo "$J"   | jq -r .cluster_name)
REGION=$(echo "$J"    | jq -r .aws_region)
NAMESPACE=$(echo "$J" | jq -r .namespace)
DOMAIN=$(echo "$J"    | jq -r .domain)
REGISTRY_BUCKET=$(echo "$J" | jq -r .buckets.registry)

ok "cluster    $CLUSTER ($REGION)"
ok "namespace  $NAMESPACE"
ok "domain     gitlab.$DOMAIN"

WEB=$(echo "$J"  | jq -r .webservice_replicas)
SIDE=$(echo "$J" | jq -r .sidekiq_replicas)

render "$VALUES_DIR/gitlab.values.yaml" "$RENDER_DIR/gitlab.values.yaml" \
  "CLUSTER_NAME=$CLUSTER" \
  "INFRA_NODEGROUP=$(echo "$J"    | jq -r .node_selector_value)" \
  "DOMAIN=$DOMAIN" \
  "ACME_EMAIL=$(echo "$J"         | jq -r .acme_email)" \
  "DB_HOST=$(echo "$J"            | jq -r .db_host)" \
  "DB_NAME=$(echo "$J"            | jq -r .db_name)" \
  "DB_USERNAME=$(echo "$J"        | jq -r .db_username)" \
  "REDIS_HOST=$(echo "$J"         | jq -r .redis_host)" \
  "S3_ROLE_ARN=$(echo "$J"        | jq -r .s3_role_arn)" \
  "BUCKET_ARTIFACTS=$(echo "$J"   | jq -r .buckets.artifacts)" \
  "BUCKET_LFS=$(echo "$J"         | jq -r .buckets.lfs)" \
  "BUCKET_UPLOADS=$(echo "$J"     | jq -r .buckets.uploads)" \
  "BUCKET_PACKAGES=$(echo "$J"    | jq -r .buckets.packages)" \
  "BUCKET_EXTERNALDIFFS=$(echo "$J"   | jq -r .buckets.externalDiffs)" \
  "BUCKET_CISECUREFILES=$(echo "$J"   | jq -r .buckets.ciSecureFiles)" \
  "BUCKET_DEPENDENCYPROXY=$(echo "$J" | jq -r .buckets.dependencyProxy)" \
  "BUCKET_TERRAFORMSTATE=$(echo "$J"  | jq -r .buckets.terraformState)" \
  "BUCKET_PAGES=$(echo "$J"       | jq -r .buckets.pages)" \
  "BUCKET_BACKUPS=$(echo "$J"     | jq -r .buckets.backups)" \
  "BUCKET_TMP=$(echo "$J"         | jq -r .buckets.tmp)" \
  "WEBSERVICE_MIN_REPLICAS=$WEB" \
  "WEBSERVICE_MAX_REPLICAS=$(( WEB + 2 ))" \
  "SIDEKIQ_MIN_REPLICAS=$SIDE" \
  "SIDEKIQ_MAX_REPLICAS=$(( SIDE + 2 ))" \
  "GITALY_STORAGE_CLASS=$(echo "$J" | jq -r .gitaly_storage_class)" \
  "GITALY_STORAGE_SIZE=$(echo "$J" | jq -r .gitaly_storage_size)" \
  "RUNNER_HELPER_IMAGE=$(echo "$J" | jq -r .runner_helper_image)"
ok "rendered   .rendered/gitlab.values.yaml"

if [ "$DRY_RUN" = 1 ]; then
  log "Dry run -- rendering manifests only"
  helm template gitlab "$CHART" \
    --namespace "$NAMESPACE" \
    --values "$RENDER_DIR/gitlab.values.yaml"
  exit 0
fi

use_cluster "$CLUSTER" "$REGION"

###############################################################################
# Namespace + the four secrets the chart expects to already exist
#
# Written through a 0700 temp dir rather than --from-literal so the generated
# passwords never appear in `ps` output or a shell trace.
###############################################################################

log "Namespace $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "namespace ready"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

S=$(terraform -chdir="$TF_DIR" output -json helm_gitlab_secrets)
[ "$S" != "null" ] || die "helm_gitlab_secrets is null."

echo "$S" | jq -rj .db_password    > "$TMP/db"
echo "$S" | jq -rj .redis_password > "$TMP/redis"

# `use_iam_profile` makes Fog pick up the IRSA credentials from the pod's
# projected token instead of looking for a static access key.
cat > "$TMP/connection" <<EOF
provider: AWS
region: $REGION
use_iam_profile: true
EOF

# The container registry reads its own storage config, in Docker-registry
# format rather than Fog format. No accesskey/secretkey: IRSA again.
cat > "$TMP/config" <<EOF
s3:
  bucket: $REGISTRY_BUCKET
  region: $REGION
  v4auth: true
EOF

apply_secret() {
  local name=$1 key=$2 file=$3
  kubectl create secret generic "$name" \
    --namespace "$NAMESPACE" \
    --from-file="$key=$file" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "secret $name"
}

log "Secrets"
apply_secret gitlab-postgres-password password   "$TMP/db"
apply_secret gitlab-redis-password    password   "$TMP/redis"
apply_secret gitlab-object-storage    connection "$TMP/connection"
apply_secret gitlab-registry-storage  config     "$TMP/config"

if [ "$SECRETS_ONLY" = 1 ]; then
  ok "Secrets only -- stopping before helm."
  exit 0
fi

###############################################################################
# Prerequisites. All of these are Terraform's job; check rather than create,
# so a missing one is reported here instead of as a stuck pod 20 minutes in.
###############################################################################

log "Checking prerequisites"
GITALY_SC=$(echo "$J" | jq -r .gitaly_storage_class)
# A PVC naming a class that does not exist does not fail -- it sits Pending,
# and the only symptom is Gitaly stuck in ContainerCreating much later.
kubectl get storageclass "$GITALY_SC" >/dev/null 2>&1 \
  && ok "storageclass $GITALY_SC (Gitaly's PVC names it)" \
  || die "no \"$GITALY_SC\" StorageClass on this cluster.
Terraform creates it from var.storage_classes; check enable_ebs_csi_driver
is true and that the apply reached the StorageClass stage. Present:
$(kubectl get storageclass -o name 2>/dev/null | sed 's|^|  |')"

kubectl -n kube-system get deploy aws-load-balancer-controller >/dev/null 2>&1 \
  && ok "aws-load-balancer-controller" \
  || warn "aws-load-balancer-controller missing -- the Gateway's Service will stay Pending"

kubectl -n kube-system get deploy external-dns >/dev/null 2>&1 \
  && ok "external-dns" \
  || warn "external-dns missing -- gitlab.$DOMAIN will not get a Route53 record"

INFRA_NODES=$(kubectl get nodes \
  -l "eks.amazonaws.com/nodegroup=$(echo "$J" | jq -r .node_selector_value)" \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')
[ "${INFRA_NODES:-0}" -ge 1 ] \
  && ok "$INFRA_NODES infra node(s)" \
  || die "no nodes in the infra node group -- every GitLab pod would stay Pending."

###############################################################################
# Install
###############################################################################

log "helm upgrade --install gitlab (chart $GITLAB_CHART_VERSION)"
HELM_ARGS="--namespace $NAMESPACE --values $RENDER_DIR/gitlab.values.yaml"
if [ "$WAIT" = 1 ]; then
  # A first install runs migrations and pulls ~20 images. Not --atomic: a
  # rollback part-way through a schema migration is worse than a stuck install.
  log "Waiting for rollout (first install is typically 10-20 minutes)"
  # shellcheck disable=SC2086
  helm upgrade --install gitlab "$CHART" $HELM_ARGS --wait --timeout "$WAIT_TIMEOUT"
else
  # shellcheck disable=SC2086
  helm upgrade --install gitlab "$CHART" $HELM_ARGS
  warn "Not waiting for rollout. Follow it with:"
  printf '      kubectl -n %s get pods -w\n' "$NAMESPACE" >&2
fi

###############################################################################

ok "GitLab release applied."
cat >&2 <<EOF

  URL          https://gitlab.$DOMAIN
  Registry     https://registry.$DOMAIN

  Root password (rotate after first login):
    kubectl -n $NAMESPACE get secret gitlab-gitlab-initial-root-password \\
      -o jsonpath='{.data.password}' | base64 -d; echo

  DNS: the domain must be delegated to the Route53 zone Terraform created,
  otherwise the UI will not resolve and Let's Encrypt cannot issue the
  certificate. Nameservers:
    terraform -chdir=$TF_DIR output gitlab_nameservers

  Day-2, all plain helm:
    helm -n $NAMESPACE list
    helm -n $NAMESPACE get values gitlab
    helm -n $NAMESPACE history gitlab
    helm -n $NAMESPACE rollback gitlab <revision>
EOF
