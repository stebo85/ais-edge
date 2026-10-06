#!/usr/bin/env bash
# =============================================================================
# Step 06: Join an edge worker over SSH   (edges[].join: ssh — the default)
#          Usage: ./06-join-edge-worker.sh <edge-entry>
# =============================================================================
# This is the DELIVERY half of joining a worker. The join itself lives in
# scripts/files/edge-join.sh and runs on the edge; this script only gets that
# script and its three files onto the machine and runs them.
#
# The other delivery half is scripts/06b-make-bootstrap.sh, for sites where the
# management node has no inbound path to the edge at all (whitelisted IPs, VPN,
# GlobalProtect). Both push the SAME join script, so a bundle-joined edge and an
# ssh-joined edge are configured identically — see the note at the top of
# scripts/files/edge-join.sh for why that matters, and
# scripts/ci/runtime-templates.sh for the assertion that keeps it true.
#
# Management-side work that follows the join is scripts/06c-post-join.sh, shared
# for the same reason.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <edge-entry>"
    exit 1
fi

# Configuration comes from sites/<site>/values.yaml, exported by install.sh.
# There is no second source: the `else parse_edge_entry "$1"` branch that used
# to sit here read config/edge-nodes.env, which could contradict the site file
# the charts were rendered from.
: "${CLUSTER_NAME:?install.sh must export CLUSTER_NAME}"
# `~` is expanded explicitly: it comes from a YAML value, so the shell never
# sees it in a position where tilde expansion happens, and ssh would be handed
# a literal "~/.ssh/id_ed25519" that does not exist.
SSH_KEY="${SSH_KEY/#\~/$HOME}"
EDGE_SSH="${SSH_USER}@${NODE_IP}"
SSH_KEY_OPT=""
[ -n "${SSH_KEY:-}" ] && SSH_KEY_OPT="-i ${SSH_KEY}"
EDGE_KC="${REPO_DIR}/kubeconfig-${CLUSTER_NAME}"

# THE WORKER MUST RUN THE SAME k0s AS ITS CONTROL PLANE — on THIS path too.
#
# The bundle path (06b) reads this from the Cluster CR and exports it. This
# path did not, so edge-join.sh fell through to its unpinned branch and the
# DEFAULT join mode kept the bug the bundle path had just been fixed for: a
# worker one minor ahead of its control plane bootstraps, gets its CSR
# approved, then asks for a `worker-config-default-<its minor>` ConfigMap the
# control plane never created. The Node authorizer denies it, k0s exits 1, and
# systemd restarts it forever while the node never appears.
#
# Same source as 06b: the Cluster CR is what k0smotron actually built the
# control plane from, so it cannot drift from what is running.
K0S_VERSION="$(kubectl get cluster.k0smotron.io -n "$CLUSTER_NAME" "$CLUSTER_NAME" \
    -o jsonpath='{.spec.version}' 2>/dev/null || true)"
if [ -z "$K0S_VERSION" ]; then
    echo "ERROR: cannot read .spec.version from cluster.k0smotron.io/${CLUSTER_NAME}" >&2
    echo "       Refusing to join a worker without pinning it to the control" >&2
    echo "       plane's version — an unpinned worker crash-loops on a missing" >&2
    echo "       worker-config ConfigMap when upstream has moved on." >&2
    exit 1
fi
echo "  k0s version (from the Cluster CR): ${K0S_VERSION}"

echo "=== 06: Installing k0s worker on ${NODE_IP} for ${CLUSTER_NAME} ==="

ssh ${SSH_KEY_OPT} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${EDGE_SSH}" "hostname" || {
    echo "ERROR: Cannot SSH to ${EDGE_SSH}"
    echo "       If this site has no inbound path from here, set join: bundle on its"
    echo "       edges[] entry and the installer will produce a carry-over bundle instead."
    exit 1
}

# The three files the edge needs, built by the same function the bundle path
# uses so the two cannot diverge on cert generation.
STAGE="$(mktemp -d)"
trap 'find "$STAGE" -type f -exec shred -u {} + 2>/dev/null || true; rm -rf "$STAGE"' EXIT
stage_edge_join_payload "$STAGE"

# ASK THE CHILD CLUSTER, not the edge's systemd, whether this node is joined.
# A worker whose unit is merely `active` may be holding a token or a kubelet
# certificate the rebuilt control plane refuses ("the server has asked for the
# client to provide credentials"), and a guard keyed on `is-active` made that
# state permanent — the join was skipped on every subsequent run, so the node
# could never be repaired by re-running the installer.
#
# edge-join.sh can work this out for itself when it has to (the bundle path,
# where the edge cannot see the child cluster), but the answer from here is
# authoritative, so pass it.
NODE_JOINED=false
if KUBECONFIG="$EDGE_KC" kubectl get nodes --no-headers 2>/dev/null | grep -q ' Ready'; then
    NODE_JOINED=true
fi
echo "  already joined and Ready: ${NODE_JOINED}"

REMOTE_DIR="/tmp/ais-join-$$"
ssh ${SSH_KEY_OPT} "${EDGE_SSH}" "mkdir -p ${REMOTE_DIR} && chmod 0700 ${REMOTE_DIR}"
scp -q ${SSH_KEY_OPT} \
    "${STAGE}/k0s-ca.crt" "${STAGE}/haproxy-server.pem" "${STAGE}/join-token" \
    "${REPO_DIR}/scripts/files/edge-join.sh" \
    "${EDGE_SSH}:${REMOTE_DIR}/"

# EVERY VALUE GOES THROUGH printf %q. ssh does not take an argv: it joins its
# arguments into ONE string that the REMOTE shell re-splits on whitespace, so
# `ssh host VAR="a b" cmd` assigns only "a" and runs "b" as the command. That
# broke the kubelet log-rotation flags here and left the worker uninstalled
# while the error named a stray k0s argument.
ssh ${SSH_KEY_OPT} "${EDGE_SSH}" \
    "EDGE_K0S_DATA_DIR=$(printf '%q' "${EDGE_K0S_DATA_DIR:-/var/lib/k0s}") \
     EDGE_NAME=$(printf '%q' "$CLUSTER_NAME") \
     MGMT_NODE_IP=$(printf '%q' "${MGMT_NODE_IP:-}") \
     SEAWEEDFS_HOSTNAME=$(printf '%q' "${SEAWEEDFS_HOSTNAME:-}") \
     K0S_API_HOSTNAME=$(printf '%q' "${K0S_API_HOSTNAME:-}") \
     KONNECTIVITY_HOSTNAME=$(printf '%q' "${KONNECTIVITY_HOSTNAME:-}") \
     KUBELET_EXTRA_ARGS=$(printf '%q' "--container-log-max-size=${KUBELET_LOG_MAX_SIZE:-10Mi} --container-log-max-files=${KUBELET_LOG_MAX_FILES:-5}") \
     INSTALL_TOPOLOGY=$(printf '%q' "${INSTALL_TOPOLOGY:-onprem}") \
     NODE_JOINED=$(printf '%q' "$NODE_JOINED") \
     AIS_STAGE_DIR=$(printf '%q' "$REMOTE_DIR") \
     K0S_VERSION=$(printf '%q' "$K0S_VERSION") \
     bash ${REMOTE_DIR}/edge-join.sh"

# The token is shredded by edge-join.sh; remove what is left of the directory.
ssh ${SSH_KEY_OPT} "${EDGE_SSH}" "rm -rf ${REMOTE_DIR}" 2>/dev/null || true

# Node verification and the child-cluster CoreDNS patch are management-side and
# identical for both delivery paths.
WAIT_MINUTES="${WAIT_MINUTES:-3}" \
    bash "${REPO_DIR}/scripts/06c-post-join.sh" "$CLUSTER_NAME"

echo "=== 06: Complete for ${CLUSTER_NAME} ==="
