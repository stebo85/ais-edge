#!/usr/bin/env bash
# =============================================================================
# Local edge bootstrap for workers the management node cannot SSH into.
#
# This script is copied into a per-edge bundle by
# scripts/06a-create-edge-bootstrap-bundle.sh. Run it locally on the facility
# edge machine after transferring and unpacking that bundle.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [ -f edge-bootstrap.env ]; then
    # shellcheck disable=SC1091
    source edge-bootstrap.env
else
    echo "ERROR: edge-bootstrap.env not found in ${SCRIPT_DIR}" >&2
    exit 1
fi

SUDO="sudo"
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
fi

require_file() {
    local f="$1"
    if [ ! -f "$f" ]; then
        echo "ERROR: required file missing from bootstrap bundle: $f" >&2
        exit 1
    fi
}

require_file join-token
require_file haproxy/ca.crt
require_file haproxy/server.pem

EDGE_DATA_HOST_PATH="${EDGE_DATA_HOST_PATH:-/data/xnat-ingest}"
EDGE_ORTHANC_MODE="${EDGE_ORTHANC_MODE:-managed}"
EDGE_ORTHANC_STORAGE_HOST_PATH="${EDGE_ORTHANC_STORAGE_HOST_PATH:-${EDGE_DATA_HOST_PATH}/orthanc-storage}"

echo "=== AIS Edge local bootstrap: ${CLUSTER_NAME:-unknown} ==="

if [ "${INSTALL_TOPOLOGY:-onprem}" = "onprem" ]; then
    HOSTS_MARKER="# ais-edge phase2 tls hostnames"
    HOSTS_LINE="${MGMT_NODE_IP} ${SEAWEEDFS_HOSTNAME} ${K0S_API_HOSTNAME} ${KONNECTIVITY_HOSTNAME}"
    echo "Ensuring /etc/hosts has management TLS hostnames..."
    if ! grep -qF "${HOSTS_MARKER}" /etc/hosts; then
        printf '%s\n%s\n' "${HOSTS_MARKER}" "${HOSTS_LINE}" | ${SUDO} tee -a /etc/hosts >/dev/null
    fi
else
    echo "Cloud/DNS topology: not editing /etc/hosts."
fi

echo "Installing k0smotron haproxy certs..."
${SUDO} mkdir -p /etc/haproxy/certs
${SUDO} install -m 0644 haproxy/ca.crt /etc/haproxy/certs/ca.crt
${SUDO} install -m 0644 haproxy/server.pem /etc/haproxy/certs/server.pem

echo "Installing k0s join token..."
${SUDO} mkdir -p /etc/k0s
${SUDO} install -m 0600 join-token /etc/k0s/join-token

if [ -f ais-edge-ca.crt ]; then
    echo "Installing AIS Edge public CA for local smoke tests..."
    ${SUDO} mkdir -p /etc/ais-edge
    ${SUDO} install -m 0644 ais-edge-ca.crt /etc/ais-edge/ais-edge-ca.crt
fi

echo "Preparing edge data directories..."
${SUDO} mkdir -p "${EDGE_DATA_HOST_PATH}/staging"
${SUDO} chmod 777 "${EDGE_DATA_HOST_PATH}/staging"

case "${EDGE_ORTHANC_MODE}" in
    external)
        echo "Existing Orthanc mode: not installing or configuring Orthanc."
        if [ -n "${EDGE_ORTHANC_STORAGE_HOST_PATH:-}" ]; then
            if [ -d "${EDGE_ORTHANC_STORAGE_HOST_PATH}" ]; then
                echo "Existing Orthanc storage path found: ${EDGE_ORTHANC_STORAGE_HOST_PATH}"
            else
                echo "WARNING: EDGE_ORTHANC_STORAGE_HOST_PATH does not exist yet:"
                echo "  ${EDGE_ORTHANC_STORAGE_HOST_PATH}"
                echo "Create a bind mount or directory there before deploying the sort pod."
            fi
        fi
        ;;
    managed)
        ${SUDO} mkdir -p "${EDGE_DATA_HOST_PATH}/orthanc-storage" /data/facility-backup
        ${SUDO} chmod 777 "${EDGE_DATA_HOST_PATH}/orthanc-storage"
        ${SUDO} chmod 750 /data/facility-backup
        ;;
    *)
        echo "ERROR: unknown EDGE_ORTHANC_MODE='${EDGE_ORTHANC_MODE}'" >&2
        exit 1
        ;;
esac

if ! command -v k0s >/dev/null 2>&1; then
    echo "Installing k0s binary..."
    curl -sSLf https://get.k0s.sh | ${SUDO} sh
fi
echo "k0s: $(k0s version)"

if ! ${SUDO} systemctl is-active k0sworker >/dev/null 2>&1; then
    echo "Installing and starting k0s worker..."
    ${SUDO} k0s install worker --force --token-file /etc/k0s/join-token
    ${SUDO} systemctl reset-failed k0sworker 2>/dev/null || true
    ${SUDO} k0s start
else
    echo "k0sworker already active; leaving it running."
fi

echo "Waiting for local kubelet process..."
for i in $(seq 1 18); do
    if ${SUDO} systemctl is-active k0sworker >/dev/null 2>&1 && pgrep -f kubelet >/dev/null 2>&1; then
        echo "Worker running (kubelet active)."
        break
    fi
    if [ "$i" -eq 18 ]; then
        echo "WARNING: kubelet not detected yet; check: sudo journalctl -u k0sworker -n 50"
        break
    fi
    echo "  Waiting... (${i}/18)"
    sleep 10
done

echo ""
echo "Embedded API server URL:"
${SUDO} cat /etc/k0s/join-token 2>/dev/null | base64 -d 2>/dev/null | gunzip 2>/dev/null | grep 'server:' || true

echo ""
echo "Bootstrap complete. On the management/XNAT side, verify:"
echo "  KUBECONFIG=kubeconfig-${CLUSTER_NAME} kubectl get nodes -o wide"
