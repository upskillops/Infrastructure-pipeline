#!/usr/bin/env bash
#
# (Re-)download the vendored charts into charts/ and refresh SHA256SUMS.
#
# The .tgz files are committed deliberately: an install should not depend on
# helm.cilium.io and charts.gitlab.io being reachable, and pinning the archive
# rather than the version means `helm upgrade` can never pick up a re-tagged
# chart underneath you.

. "$(dirname "$0")/lib.sh"

need helm shasum

mkdir -p "$CHART_DIR"

log "cilium $CILIUM_CHART_VERSION"
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium >/dev/null
helm pull cilium/cilium --version "$CILIUM_CHART_VERSION" --destination "$CHART_DIR"
ok "charts/cilium-${CILIUM_CHART_VERSION}.tgz"

log "gitlab $GITLAB_CHART_VERSION"
helm repo add gitlab https://charts.gitlab.io/ >/dev/null 2>&1 || true
helm repo update gitlab >/dev/null
helm pull gitlab/gitlab --version "$GITLAB_CHART_VERSION" --destination "$CHART_DIR"
ok "charts/gitlab-${GITLAB_CHART_VERSION}.tgz"

log "Writing charts/SHA256SUMS"
( cd "$CHART_DIR" && shasum -a 256 ./*.tgz > SHA256SUMS )
cat "$CHART_DIR/SHA256SUMS" >&2

ok "Done. Inspect a chart's own defaults with:"
printf '      helm show values %s/cilium-%s.tgz\n' "$CHART_DIR" "$CILIUM_CHART_VERSION" >&2
