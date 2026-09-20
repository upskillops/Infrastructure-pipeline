#!/usr/bin/env bash
#
# Render values/*.yaml into .rendered/ with the Terraform outputs substituted,
# without installing anything. Useful for reviewing a change before applying
# it, and for `helm diff upgrade`.
#
#   ./bin/render-values.sh            # both
#   ./bin/render-values.sh cilium     # one

. "$(dirname "$0")/lib.sh"

need terraform jq

render_cilium() {
  local j; j=$(tf_output helm_cilium_values)
  [ "$j" != "null" ] || die "helm_cilium_values is null -- install_cilium is false in Terraform."

  render "$VALUES_DIR/cilium.values.yaml" "$RENDER_DIR/cilium.values.yaml" \
    "OPERATOR_ROLE_ARN=$(echo "$j"   | jq -r .operator_role_arn)" \
    "VPC_CIDR=$(echo "$j"            | jq -r .vpc_cidr)" \
    "K8S_SERVICE_HOST=$(echo "$j"    | jq -r .k8s_service_host)" \
    "OPERATOR_REPLICAS=$(echo "$j"   | jq -r .operator_replicas)" \
    "PREFIX_DELEGATION=$(echo "$j"   | jq -r .prefix_delegation)" \
    "HUBBLE_RELAY=$(echo "$j"        | jq -r .hubble_relay)"

  ok ".rendered/cilium.values.yaml"
}

render_gitlab() {
  local j; j=$(tf_output helm_gitlab_values)
  [ "$j" != "null" ] || die "helm_gitlab_values is null -- enable_gitlab is false in Terraform."

  local web side
  web=$(echo "$j"  | jq -r .webservice_replicas)
  side=$(echo "$j" | jq -r .sidekiq_replicas)

  render "$VALUES_DIR/gitlab.values.yaml" "$RENDER_DIR/gitlab.values.yaml" \
    "CLUSTER_NAME=$(echo "$j"        | jq -r .cluster_name)" \
    "INFRA_NODEGROUP=$(echo "$j"     | jq -r .node_selector_value)" \
    "DOMAIN=$(echo "$j"              | jq -r .domain)" \
    "ACME_EMAIL=$(echo "$j"          | jq -r .acme_email)" \
    "DB_HOST=$(echo "$j"             | jq -r .db_host)" \
    "DB_NAME=$(echo "$j"             | jq -r .db_name)" \
    "DB_USERNAME=$(echo "$j"         | jq -r .db_username)" \
    "REDIS_HOST=$(echo "$j"          | jq -r .redis_host)" \
    "S3_ROLE_ARN=$(echo "$j"         | jq -r .s3_role_arn)" \
    "BUCKET_ARTIFACTS=$(echo "$j"    | jq -r .buckets.artifacts)" \
    "BUCKET_LFS=$(echo "$j"          | jq -r .buckets.lfs)" \
    "BUCKET_UPLOADS=$(echo "$j"      | jq -r .buckets.uploads)" \
    "BUCKET_PACKAGES=$(echo "$j"     | jq -r .buckets.packages)" \
    "BUCKET_EXTERNALDIFFS=$(echo "$j"    | jq -r .buckets.externalDiffs)" \
    "BUCKET_CISECUREFILES=$(echo "$j"    | jq -r .buckets.ciSecureFiles)" \
    "BUCKET_DEPENDENCYPROXY=$(echo "$j"  | jq -r .buckets.dependencyProxy)" \
    "BUCKET_TERRAFORMSTATE=$(echo "$j"   | jq -r .buckets.terraformState)" \
    "BUCKET_PAGES=$(echo "$j"        | jq -r .buckets.pages)" \
    "BUCKET_BACKUPS=$(echo "$j"      | jq -r .buckets.backups)" \
    "BUCKET_TMP=$(echo "$j"          | jq -r .buckets.tmp)" \
    "WEBSERVICE_MIN_REPLICAS=$web" \
    "WEBSERVICE_MAX_REPLICAS=$(( web + 2 ))" \
    "SIDEKIQ_MIN_REPLICAS=$side" \
    "SIDEKIQ_MAX_REPLICAS=$(( side + 2 ))" \
    "GITALY_STORAGE_CLASS=$(echo "$j" | jq -r .gitaly_storage_class)" \
    "GITALY_STORAGE_SIZE=$(echo "$j" | jq -r .gitaly_storage_size)" \
    "RUNNER_HELPER_IMAGE=$(echo "$j" | jq -r .runner_helper_image)"

  ok ".rendered/gitlab.values.yaml"
}

case "${1:-all}" in
  cilium) render_cilium ;;
  gitlab) render_gitlab ;;
  all)    render_cilium; render_gitlab ;;
  *)      die "usage: $0 [cilium|gitlab|all]" ;;
esac
