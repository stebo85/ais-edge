#!/usr/bin/env bash
# =============================================================================
# Join this machine to its hosted control plane as a k0s worker
# =============================================================================
# THIS RUNS ON THE EDGE, NOT ON THE MANAGEMENT NODE.
#
# There is exactly ONE copy of the join logic, and two ways of delivering it:
#
#   join: ssh      scripts/06-join-edge-worker.sh pipes THIS FILE over ssh
#                  (`ssh host bash -s < scripts/files/edge-join.sh`)
#   join: bundle   scripts/06b-make-bootstrap.sh embeds THIS FILE, verbatim,
#                  in a self-extracting script the operator carries to the edge
#
# Keeping one implementation is deliberate. Every serious bug this repo has
# found recently was two copies of one fact drifting apart: the chart serving
# konnectivity-<edge> while install.sh wrote konnect-<edge>, an /etc/hosts
# writer deleted with the imperative installer, the same REPLACE_ check wrong in
# two files. A second copy of the join would drift the same way, and the symptom
# would be "joins over ssh but not from a bundle", found in a hospital.
# scripts/ci/runtime-templates.sh asserts both paths reference this file.
#
# The repo is NOT available here. Nothing may be sourced; everything arrives as
# environment variables and as three files in AIS_STAGE_DIR.
#
# INPUTS (environment)
#   EDGE_NAME                 this edge's name, for messages only
#   MGMT_NODE_IP              management node address
#   SEAWEEDFS_HOSTNAME        }
#   K0S_API_HOSTNAME          } the three names /etc/hosts must resolve
#   KONNECTIVITY_HOSTNAME     }
#   KUBELET_EXTRA_ARGS        container log rotation bounds
#   INSTALL_TOPOLOGY          onprem (default) | cloud — cloud skips /etc/hosts
#   AIS_STAGE_DIR             where the three files are (default /tmp)
#   NODE_JOINED               OPTIONAL. true/false, from the management side,
#                             which can ask the child cluster directly. When it
#                             is not set — the bundle path, where this machine
#                             cannot see the child cluster — we work it out
#                             locally instead. See is_already_joined below.
#
# INPUTS (files in AIS_STAGE_DIR)
#   k0s-ca.crt                cluster CA, for haproxy's upstream verification
#   haproxy-server.pem        cert+key haproxy serves to in-cluster clients
#   join-token                the worker join token — A BEARER CREDENTIAL
# =============================================================================
set -euo pipefail

STAGE="${AIS_STAGE_DIR:-/tmp}"
TOPOLOGY="${INSTALL_TOPOLOGY:-onprem}"
WORKER_DATA_DIR="${EDGE_K0S_DATA_DIR:-/var/lib/k0s}"

step() { printf '  [%s/6] %-34s ' "$1" "$2"; }
ok()   { printf 'ok%s\n' "${1:+ ($1)}"; }
die()  { printf '\n  FAILED: %s\n' "$*" >&2; exit 1; }
# Leading newline because step() leaves the cursor mid-line: without it a
# warning is appended to "[6/6] k0s worker" and reads as part of the status.
warn() { printf '\n  WARNING: %s\n' "$*" >&2; }

# -----------------------------------------------------------------------------
# 1. Preconditions
# -----------------------------------------------------------------------------
# Everything that can be checked without changing the machine is checked BEFORE
# anything is changed. A half-joined node is the worst outcome here: on the
# bundle path the operator standing at the edge cannot see the management
# cluster, so they cannot tell a partial join from a working one.
step 1 "preconditions"
[ "$(id -u)" -eq 0 ] || command -v sudo >/dev/null 2>&1 || die "need root or sudo"
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"
for f in k0s-ca.crt haproxy-server.pem join-token; do
    [ -s "${STAGE}/${f}" ] || die "${STAGE}/${f} is missing or empty"
done
for v in MGMT_NODE_IP K0S_API_HOSTNAME; do
    [ -n "${!v:-}" ] || die "${v} is not set"
done
case "$WORKER_DATA_DIR" in
    /*) ;;
    *) die "EDGE_K0S_DATA_DIR must be absolute" ;;
esac
[ "$WORKER_DATA_DIR" != / ] || die "EDGE_K0S_DATA_DIR cannot be /"
ok "root, 3 staged files"

# -----------------------------------------------------------------------------
# 2. /etc/hosts
# -----------------------------------------------------------------------------
# onprem resolves the management hostnames through /etc/hosts rather than real
# DNS, so `domain.internal` need not be registered anywhere. Pods get the same
# names via the charts' hostAliases; this entry is for the HOST — the kubelet's
# bootstrap connection to the child API is a host process, not a pod, and it is
# the thing that fails first when this is missing ("no such host" against
# whatever public resolver the box happens to use).
step 2 "/etc/hosts"
if [ "$TOPOLOGY" = "onprem" ]; then
    for v in SEAWEEDFS_HOSTNAME KONNECTIVITY_HOSTNAME; do
        [ -n "${!v:-}" ] || die "${v} is not set (needed for the /etc/hosts entry)"
    done
    MARKER="# ais-edge phase2 tls hostnames"
    LINE="${MGMT_NODE_IP} ${SEAWEEDFS_HOSTNAME} ${K0S_API_HOSTNAME} ${KONNECTIVITY_HOSTNAME}"
    # REWRITE, never skip-if-present. A guard keyed on the marker makes a stale
    # or truncated block permanent — every later run sees the comment and
    # short-circuits, so the node can never be repaired by re-running. `,+1d`
    # removes the comment AND the entry under it; deleting only the comment
    # orphans the old addresses and appends a second pair.
    $SUDO sed -i "\|^${MARKER}\$|,+1d" /etc/hosts 2>/dev/null || true
    printf '%s\n%s\n' "$MARKER" "$LINE" | $SUDO tee -a /etc/hosts >/dev/null
    ok "$K0S_API_HOSTNAME -> $MGMT_NODE_IP"
else
    ok "skipped (cloud topology resolves via real DNS)"
fi

# -----------------------------------------------------------------------------
# 3. Can we actually reach the control plane?
# -----------------------------------------------------------------------------
# Deliberately AFTER /etc/hosts and BEFORE installing anything. This is the
# check that distinguishes "the network path is wrong" from "k0s failed", and
# those get diagnosed very differently. The edge dials OUT to the management
# node; nothing ever connects inward, which is why a site with no inbound access
# can still run a worker at all.
step 3 "reach ${K0S_API_HOSTNAME}:443"
if command -v curl >/dev/null 2>&1; then
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 \
           "https://${K0S_API_HOSTNAME}:443/version" 2>/dev/null || echo 000)
    [ "$code" = "000" ] && die "cannot reach https://${K0S_API_HOSTNAME}:443 from this machine.
          The edge must be able to reach the management node outbound on 443.
          Check egress/proxy rules and that /etc/hosts above points at the right address."
    ok "HTTP $code"
else
    ok "skipped (curl not installed)"
fi

# -----------------------------------------------------------------------------
# 4. Is this node already joined?
# -----------------------------------------------------------------------------
# `systemctl is-active k0sworker` is NOT the question. Step 05 mints a fresh
# token on every run, and a kubelet keeps a client certificate under
# /var/lib/k0s/kubelet/pki that it PREFERS to the token — so a worker rebuilt
# against a new control plane stays `active` while being refused with
# "the server has asked for the client to provide credentials", forever.
#
# The management side can just ask the child cluster. From here we cannot, so we
# ask the API whether it still accepts this node's identity: 200 or 403 both
# mean the certificate authenticated (403 is merely "not allowed to list
# nodes"), while 401 means the identity is stale and we must reset.
is_already_joined() {
    [ "${NODE_JOINED:-}" = "true" ] && return 0
    [ -n "${NODE_JOINED:-}" ] && return 1          # management side said false
    $SUDO systemctl is-active k0sworker >/dev/null 2>&1 || return 1
    local cert="${WORKER_DATA_DIR}/kubelet/pki/kubelet-client-current.pem"
    $SUDO test -f "$cert" || return 1
    command -v curl >/dev/null 2>&1 || return 1
    local c
    c=$($SUDO curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
        --cert "$cert" --key "$cert" \
        "https://${K0S_API_HOSTNAME}:443/api/v1/nodes?limit=1" 2>/dev/null || echo 000)
    case "$c" in 200|403) return 0 ;; *) return 1 ;; esac
}

step 4 "current join state"
if is_already_joined; then
    JOINED=true;  ok "already joined — worker will be left alone"
else
    JOINED=false; ok "not joined — will install"
fi

# -----------------------------------------------------------------------------
# 5. haproxy certs
# -----------------------------------------------------------------------------
# k0smotron runs a hostNetwork haproxy DaemonSet on the worker exposing
# 127.0.0.1:7443 as the local API endpoint. It needs a server cert signed by the
# CLUSTER's internal CA, or every pod calling the kubernetes Service fails with
# "x509: certificate signed by unknown authority". 0644 because the haproxy
# container runs non-root and must read them.
step 5 "haproxy certs"
$SUDO mkdir -p /etc/haproxy/certs
$SUDO chmod 0755 /etc/haproxy/certs
$SUDO install -m 0644 "${STAGE}/k0s-ca.crt"         /etc/haproxy/certs/ca.crt
$SUDO install -m 0644 "${STAGE}/haproxy-server.pem" /etc/haproxy/certs/server.pem
ok "/etc/haproxy/certs"

# -----------------------------------------------------------------------------
# 6. The worker itself
# -----------------------------------------------------------------------------
step 6 "k0s worker"
if [ "$JOINED" != "true" ]; then
    # THE WORKER MUST MATCH ITS CONTROL PLANE. K0S_VERSION is set by
    # scripts/06b from the Cluster CR, so it is whatever k0smotron actually
    # built the hosted control plane from.
    #
    # This used to be a bare `curl get.k0s.sh | sh`, taking whatever upstream
    # published that day, guarded only by `command -v k0s`. Two ways that broke:
    #
    #   1. Fresh host, upstream has moved on -> a newer worker than the pinned
    #      control plane. It bootstraps, its CSR is APPROVED, then it asks for
    #      `worker-config-default-<its own minor>`, which the older control
    #      plane never created and whose RBAC does not cover. The Node
    #      authorizer denies it, k0s exits 1, systemd restarts it forever and
    #      the node never appears. The installer just waits. Hit on cai-lfs3
    #      with a 1.36.1 worker against a 1.35.2 control plane.
    #   2. Re-join of a host that already has the WRONG k0s -> `command -v k0s`
    #      is satisfied, nothing is installed, and the mismatch is preserved.
    #
    # So: install when absent, and REPLACE when present but wrong.
    if [ -n "${K0S_VERSION:-}" ]; then
        have=$(k0s version 2>/dev/null || echo none)
        if [ "$have" != "$K0S_VERSION" ]; then
            [ "$have" = none ] || warn "k0s ${have} is installed but the control plane runs ${K0S_VERSION} — replacing"
            curl -sSLf https://get.k0s.sh | $SUDO K0S_VERSION="$K0S_VERSION" sh >/dev/null \
                || die "could not install k0s ${K0S_VERSION}"
            got=$(k0s version 2>/dev/null || echo none)
            [ "$got" = "$K0S_VERSION" ] || die "installed k0s reports ${got}, expected ${K0S_VERSION}"
        fi
    else
        # No pin available. Say so rather than silently reintroducing the bug.
        warn "K0S_VERSION not set by the bundle — installing UNPINNED k0s."
        warn "  If this worker's minor version differs from its control plane it"
        warn "  will crash-loop on a missing worker-config ConfigMap."
        # UNPINNED-OK: the last-resort branch, reached only when the bundle or
        # the ssh join failed to supply a version. Both paths now do, so this
        # should be unreachable; it warns loudly above rather than failing,
        # because refusing to join is worse than joining with a caveat.
        command -v k0s >/dev/null 2>&1 || { curl -sSLf https://get.k0s.sh | $SUDO sh >/dev/null; }
    fi
    $SUDO mkdir -p /etc/k0s "$WORKER_DATA_DIR"
    $SUDO install -m 0600 "${STAGE}/join-token" /etc/k0s/join-token
    # Clear stale worker state before re-joining, or the cached kubelet identity
    # above survives the reinstall and keeps being refused. Only reached when the
    # node is NOT joined, so there is nothing running to lose.
    if $SUDO systemctl is-active k0sworker >/dev/null 2>&1; then
        printf '\n      worker active but not joined — resetting first\n      '
        $SUDO k0s stop 2>/dev/null || true
        $SUDO k0s reset --data-dir "$WORKER_DATA_DIR" 2>/dev/null || true
    fi
    # Capture rather than stream. `--force` logs
    #   level=warning msg="failed to uninstall service: exit status 1"
    # whenever there is no previous unit to remove, which is the normal case on
    # a first join. Printed live it lands in the middle of this step's status
    # line and reads as a failure to an operator who has no other feedback.
    # Real failures still surface: the output is replayed on a non-zero exit.
    if ! install_out=$($SUDO k0s install worker --force --data-dir "$WORKER_DATA_DIR" \
            --kubelet-root-dir "${WORKER_DATA_DIR}/kubelet" --token-file /etc/k0s/join-token \
            --kubelet-extra-args="${KUBELET_EXTRA_ARGS:---container-log-max-size=10Mi --container-log-max-files=5}" 2>&1); then
        printf '\n'
        printf '%s\n' "$install_out" >&2
        die "k0s install worker failed"
    fi
    $SUDO systemctl reset-failed k0sworker 2>/dev/null || true
    $SUDO k0s start
    for i in $(seq 1 18); do
        if $SUDO systemctl is-active k0sworker >/dev/null 2>&1 && pgrep -f kubelet >/dev/null 2>&1; then
            ok "installed, kubelet active"; break
        fi
        [ "$i" -eq 18 ] && die "kubelet did not start. Check: sudo journalctl -u k0sworker -n 50"
        sleep 10
    done
else
    ok "unchanged"
fi

# The token is a bearer credential that grants cluster membership. It is now in
# /etc/k0s/join-token at 0600 where k0s needs it; the staged copy must not
# linger in a world-readable directory.
shred -u "${STAGE}/join-token" 2>/dev/null || rm -f "${STAGE}/join-token"

echo
echo "  JOINED — ${EDGE_NAME:-this edge} is a k0s worker."
echo "  Report this line to whoever ran the installer:"
echo "    ${EDGE_NAME:-edge}  $(hostname)  $(date -u +%Y-%m-%dT%H:%M:%SZ)  ok"
