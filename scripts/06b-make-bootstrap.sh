#!/usr/bin/env bash
# =============================================================================
# Step 06b: build a carry-over bootstrap bundle for an edge we cannot ssh to
#           Usage: ./06b-make-bootstrap.sh <edge-name>
# =============================================================================
# WHY THIS EXISTS
#
# scripts/06 joins a worker by pushing over ssh: management node -> edge. A
# hospital edge behind a whitelisted-IP allowlist, a VPN, or GlobalProtect has
# no inbound path at all, so that step cannot run, and it fails AFTER the
# management cluster is already built.
#
# Only the BOOTSTRAP is push-shaped. The running system is already pull-shaped:
# the konnectivity agent dials out to the management node and the kubelet talks
# outbound to its hosted control plane, so nothing ever connects into the
# hospital. Joining therefore needs exactly three files and one command to reach
# the edge ONCE, by whatever route the operator already has.
#
# This produces a single self-extracting shell script for that trip.
#
# WHY ONE TEXT FILE AND NOT A TARBALL
#   A tarball needs a binary-safe channel. A single ASCII file also survives a
#   console paste, a ticketing system, or an email body — and in a locked-down
#   site the console is often the only channel there is. Designing for the worst
#   channel makes every better one work too.
#
# WHAT IS NOT HERE, DELIBERATELY
#   No callback service and no "edge pulls from mgmt over HTTPS". Both need
#   either inbound access or a credential to authenticate the pull — so you
#   would still be carrying a secret, with an extra endpoint to secure.
#
# THE BUNDLE IS A CREDENTIAL. It contains the join token, which grants cluster
# membership. It expires (see JOIN_TOKEN_TTL in step 05), it names the machine
# it is for, and it shreds itself after use — but treat it like a password until
# it is used, and delete it afterwards.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

[ $# -ge 1 ] || { echo "Usage: $0 <edge-name>" >&2; exit 1; }

# Configuration comes from sites/<site>/values.yaml, exported by install.sh.
# There is no second source: the `else parse_edge_entry "$1"` branch that used
# to sit here read config/edge-nodes.env, which could contradict the site file
# the charts were rendered from.
: "${CLUSTER_NAME:?install.sh must export CLUSTER_NAME}"

OUT="${REPO_DIR}/${CLUSTER_NAME}-join.sh"
JOIN_SRC="${REPO_DIR}/scripts/files/edge-join.sh"
[ -f "$JOIN_SRC" ] || { echo "ERROR: ${JOIN_SRC} not found" >&2; exit 1; }

# =============================================================================
# THE WORKER MUST RUN THE SAME k0s AS ITS CONTROL PLANE
# =============================================================================
# edge-join.sh used to install k0s with a bare `curl get.k0s.sh | sh`, which
# takes whatever upstream published that day. The hosted control plane is
# PINNED (k0smotron.k0sVersion), so the two only agree by luck — and they
# stopped agreeing the moment upstream moved on.
#
# When they disagree the failure is silent and deeply misleading. A 1.36 worker
# against a 1.35 control plane:
#   * bootstraps its client config       -> looks fine
#   * gets its CSR approved              -> looks fine
#   * asks for `worker-config-default-1.36`, which the 1.35 control plane never
#     created and whose RBAC does not cover it
#   * is denied by the Node authorizer, exits 1, and systemd restarts it forever
# The node NEVER appears, so the installer just waits. Observed on cai-lfs3.
#
# The Cluster CR is the authority: it is what k0smotron actually built the
# control plane from, so it cannot drift from what is running the way a chart
# value read at a different moment could.
K0S_VERSION="$(kubectl get cluster.k0smotron.io -n "$CLUSTER_NAME" "$CLUSTER_NAME" \
    -o jsonpath='{.spec.version}' 2>/dev/null || true)"
if [ -z "$K0S_VERSION" ]; then
    echo "ERROR: cannot read .spec.version from cluster.k0smotron.io/${CLUSTER_NAME}" >&2
    echo "       Without it the bundle would install an unpinned k0s, and a worker" >&2
    echo "       whose minor version differs from its control plane crash-loops on" >&2
    echo "       a worker-config ConfigMap that does not exist. Refusing to build" >&2
    echo "       a bundle that can fail that way." >&2
    exit 1
fi
echo "  k0s version (from the Cluster CR): ${K0S_VERSION}"

echo "=== 06b: building bootstrap bundle for ${CLUSTER_NAME} ==="

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
chmod 0700 "$STAGE"

# The same three files scripts/06 scps, produced by the same function, so the
# two delivery paths cannot diverge on cert generation.
stage_edge_join_payload "$STAGE"
cp "$JOIN_SRC" "${STAGE}/edge-join.sh"

EXPIRES_FILE="${REPO_DIR}/join-token-${CLUSTER_NAME}.expires"
EXPIRES_AT=$(cat "$EXPIRES_FILE" 2>/dev/null || echo 0)

PAYLOAD_B64="$(tar czf - -C "$STAGE" k0s-ca.crt haproxy-server.pem join-token edge-join.sh | base64 -w0)"
PAYLOAD_SHA="$(printf '%s' "$PAYLOAD_B64" | sha256sum | cut -d' ' -f1)"

# NOTE ON QUOTING: every value below is written through printf %q, because these
# become shell assignments on a machine we cannot test first. scripts/06 was
# broken for exactly this reason — `ssh host VAR="a b" bash -s` split on the
# space and ran the remainder as a command.
{
cat <<HEADER
#!/usr/bin/env bash
# =============================================================================
# AIS Edge — join $(printf '%s' "$CLUSTER_NAME") to its hosted control plane
# =============================================================================
# Generated by scripts/06b-make-bootstrap.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
#
#   RUN THIS ON THE EDGE MACHINE:   sudo bash $(basename "$OUT")
#
# It contains this edge's join token and is therefore a CREDENTIAL: do not
# commit it, do not share it, delete it once the join has succeeded.
#
# It refuses to run on the wrong machine, refuses once the token has expired,
# and verifies its own payload before touching anything. Re-running it is safe:
# the join converges rather than skipping, so it repairs a partial join.
# =============================================================================
set -euo pipefail

BUNDLE_EDGE=$(printf '%q' "$CLUSTER_NAME")
BUNDLE_TARGET_IP=$(printf '%q' "${NODE_IP:-}")
BUNDLE_EXPIRES_AT=$(printf '%q' "$EXPIRES_AT")
BUNDLE_SHA256=$(printf '%q' "$PAYLOAD_SHA")

export EDGE_K0S_DATA_DIR=$(printf '%q' "${EDGE_K0S_DATA_DIR:-/var/lib/k0s}")
export EDGE_NAME=$(printf '%q' "$CLUSTER_NAME")
export MGMT_NODE_IP=$(printf '%q' "${MGMT_NODE_IP:-}")
export SEAWEEDFS_HOSTNAME=$(printf '%q' "${SEAWEEDFS_HOSTNAME:-}")
export K0S_API_HOSTNAME=$(printf '%q' "${K0S_API_HOSTNAME:-}")
export KONNECTIVITY_HOSTNAME=$(printf '%q' "${KONNECTIVITY_HOSTNAME:-}")
export KUBELET_EXTRA_ARGS=$(printf '%q' "--container-log-max-size=${KUBELET_LOG_MAX_SIZE:-10Mi} --container-log-max-files=${KUBELET_LOG_MAX_FILES:-5}")
# Pinned to the control plane's own version — see the note where this is read.
export K0S_VERSION=$(printf '%q' "$K0S_VERSION")
export INSTALL_TOPOLOGY=$(printf '%q' "${INSTALL_TOPOLOGY:-onprem}")

FORCE_HOST=false
[ "\${1:-}" = "--any-host" ] && FORCE_HOST=true

echo
echo "  AIS Edge join — \${BUNDLE_EDGE}"
echo

# --- pre-flight, before anything on this machine is modified -----------------
# A truncated paste is the single most likely failure of this delivery method,
# and it would otherwise surface as a corrupt tar or a half-written cert.
PAYLOAD_START=\$(awk '/^__AIS_PAYLOAD__\$/{print NR+1; exit}' "\$0")
ACTUAL_SHA=\$(tail -n +\${PAYLOAD_START} "\$0" | tr -d '\n' | sha256sum | cut -d' ' -f1)
if [ "\$ACTUAL_SHA" != "\$BUNDLE_SHA256" ]; then
    echo "  FAILED: payload checksum mismatch — this file is truncated or altered." >&2
    echo "          Copy it again, whole. (expected \${BUNDLE_SHA256:0:16}…, got \${ACTUAL_SHA:0:16}…)" >&2
    exit 1
fi

if [ "\$BUNDLE_EXPIRES_AT" -gt 0 ] 2>/dev/null; then
    NOW=\$(date +%s)
    if [ "\$NOW" -ge "\$BUNDLE_EXPIRES_AT" ]; then
        echo "  FAILED: the join token in this bundle expired on \$(date -u -d @\${BUNDLE_EXPIRES_AT} 2>/dev/null || echo '?')." >&2
        echo "          Ask for a fresh bundle: scripts/06b-make-bootstrap.sh \${BUNDLE_EDGE}" >&2
        exit 1
    fi
    echo "  token valid for another \$(( (BUNDLE_EXPIRES_AT - NOW) / 60 )) minute(s)"
fi

# Running hospital-a's bundle on hospital-b would join the wrong machine to the
# wrong control plane, and in a fleet the bundles look identical.
if [ -n "\$BUNDLE_TARGET_IP" ] && [ "\$FORCE_HOST" != "true" ]; then
    if ! ip -o addr show 2>/dev/null | grep -qw "\$BUNDLE_TARGET_IP"; then
        echo "  FAILED: this bundle is for \${BUNDLE_EDGE} (\${BUNDLE_TARGET_IP}), but this machine" >&2
        echo "          (\$(hostname)) does not hold that address." >&2
        echo "          If that is expected — NAT, or a renumbered host — re-run with: --any-host" >&2
        exit 1
    fi
fi

# --- extract and hand over to the shared join ---------------------------------
WORK=\$(mktemp -d); chmod 0700 "\$WORK"
cleanup() { find "\$WORK" -type f -exec shred -u {} + 2>/dev/null || true; rm -rf "\$WORK"; }
trap cleanup EXIT
tail -n +\${PAYLOAD_START} "\$0" | tr -d '\n' | base64 -d | tar xz -C "\$WORK"

export AIS_STAGE_DIR="\$WORK"
bash "\$WORK/edge-join.sh"
echo
echo "  You can delete this bundle now: rm -f \$(basename "\$0")"
exit 0
__AIS_PAYLOAD__
HEADER
printf '%s\n' "$PAYLOAD_B64"
} > "$OUT"

chmod 0700 "$OUT"

echo "  wrote $(basename "$OUT")  ($(du -h "$OUT" | cut -f1))"
if [ "$EXPIRES_AT" -gt 0 ] 2>/dev/null; then
    echo "  token valid until $(date -u -d "@${EXPIRES_AT}" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo '?')"
fi
cat <<NEXT

  This file contains ${CLUSTER_NAME}'s join token. Treat it as a credential.

  1. Copy it to the edge by whatever route you have (VPN, jump host, console
     paste — it is plain text on purpose).
  2. On the edge:   sudo bash $(basename "$OUT")
  3. Delete it there and here once the join reports ok.
  4. Back here, confirm the node arrived:
         scripts/verify-live.sh <site>

NEXT
