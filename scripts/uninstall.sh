#!/usr/bin/env bash
# =============================================================================
# Uninstall everything — management cluster, edge workers, SeaweedFS, k0smotron
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/config/management.env"
source "${SCRIPT_DIR}/config/edge-nodes.env"

echo "============================================"
echo "WARNING: This will destroy EVERYTHING:"
echo "  - All edge workers and their data"
echo "  - /etc/hosts entries on edge VMs (Phase 2 hostnames)"
echo "  - SeaweedFS and all stored files (/data/seaweedfs)"
echo "  - k0smotron and all hosted clusters"
echo "  - nginx-ingress (Phase 2 :443 listener)"
echo "  - observability stack (Loki / Grafana / Prometheus / Vector)"
echo "  - cert-manager Issuers + the self-signed CA"
echo "  - ais-edge-ca.crt (the public CA cert for edges)"
echo "  - all local-path-provisioner PVC contents on this VM"
echo "  - k0s controller (if fresh install)"
echo "============================================"
# `-y` / `--yes` skips the confirmation so install.sh -y can chain
# uninstall+install non-interactively.
if [ "${1:-}" = "-y" ] || [ "${1:-}" = "--yes" ]; then
    echo "Confirmation skipped (-y flag)."
else
    read -p "Are you sure? (y/N) " -r
    [[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# --- Remove edge workers ---
for entry in "${EDGE_NODES[@]}"; do
    IFS='|' read -r CLUSTER_NAME NODE_IP SSH_USER SSH_KEY _ _ _ <<< "$entry"
    SSH_KEY_OPT=""
    [ -n "${SSH_KEY}" ] && SSH_KEY_OPT="-i ${SSH_KEY}"
    EDGE_SSH="${SSH_USER}@${NODE_IP}"

    echo ""
    echo "=== Removing edge: ${CLUSTER_NAME} (${NODE_IP}) ==="
    ssh ${SSH_KEY_OPT} "${EDGE_SSH}" bash -s <<'EOF' 2>/dev/null || echo "  (skipped)"
sudo k0s stop 2>/dev/null || true
sudo k0s reset 2>/dev/null || true
sudo rm -rf /data/xnat-ingest 2>/dev/null || true
sudo rm -rf "${EDGE_K0S_DATA_DIR:-/data/k0s}" 2>/dev/null || true
sudo rm -f /etc/k0s/join-token 2>/dev/null || true
# Phase 2: drop the /etc/hosts block we added in 06
sudo sed -i '/# ais-edge phase2 tls hostnames/,+1d' /etc/hosts 2>/dev/null || true
# Phase 2: remove the haproxy certs we staged in 06
sudo rm -rf /etc/haproxy/certs 2>/dev/null || true
sudo rmdir /etc/haproxy 2>/dev/null || true
EOF

    kubectl delete namespace "${CLUSTER_NAME}" --ignore-not-found 2>/dev/null || true
    rm -f "${SCRIPT_DIR}/kubeconfig-${CLUSTER_NAME}" "${SCRIPT_DIR}/join-token-${CLUSTER_NAME}"
done

# --- Remove management workloads ---
echo ""
echo "=== Removing SeaweedFS and XNAT upload ==="
kubectl delete namespace xnat-upload --ignore-not-found 2>/dev/null || true
kubectl delete namespace seaweedfs --ignore-not-found 2>/dev/null || true
sudo rm -rf /data/seaweedfs

echo ""
echo "=== Removing observability stack (Loki + Prom + Grafana + Vector) ==="
helm uninstall vector-mgmt          -n observability 2>/dev/null || true
helm uninstall loki                 -n observability 2>/dev/null || true
helm uninstall kube-prometheus-stack -n observability 2>/dev/null || true
kubectl delete namespace observability --ignore-not-found 2>/dev/null || true
# /etc/hosts marker added by 02d
sudo sed -i '/# ais-edge observability hostnames/,+1d' /etc/hosts 2>/dev/null || true

echo ""
echo "=== Removing nginx-ingress (Phase 2 :443 listener) ==="
helm uninstall ingress-nginx -n ingress-nginx 2>/dev/null || true
kubectl delete namespace ingress-nginx --ignore-not-found 2>/dev/null || true

echo ""
echo "=== Removing Phase 2 /etc/hosts entry on management node ==="
sudo sed -i '/# ais-edge phase2 tls hostnames/,+1d' /etc/hosts 2>/dev/null || true

echo ""
echo "=== Removing CA Issuers + bundled CA cert ==="
kubectl delete clusterissuer ais-edge-ca-issuer selfsigned-bootstrap --ignore-not-found 2>/dev/null || true
kubectl delete certificate ais-edge-ca ais-edge-ca-2 -n cert-manager --ignore-not-found 2>/dev/null || true
kubectl delete secret ais-edge-ca-secret ais-edge-ca-2-secret -n cert-manager --ignore-not-found 2>/dev/null || true
rm -f "${SCRIPT_DIR}/ais-edge-ca.crt" "${SCRIPT_DIR}/ca-bundle.crt"

echo ""
echo "=== Removing k0smotron ==="
kubectl delete -f https://docs.k0smotron.io/stable/install.yaml --ignore-not-found 2>/dev/null || true

echo ""
echo "=== Removing cert-manager ==="
kubectl delete -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml --ignore-not-found 2>/dev/null || true

echo ""
echo "=== Removing local-path-provisioner ==="
kubectl delete -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml --ignore-not-found 2>/dev/null || true

# Wipe the host directories backing every PVC that local-path-provisioner
# created. helm uninstall and `kubectl delete namespace` remove the PVC
# objects, but the data on disk under /opt/local-path-provisioner/ is the
# host's responsibility. Without this, fresh installs reuse stale state
# (e.g. an old grafana.db with auto-generated datasource UIDs) and break
# in subtle ways.
if [ -d /opt/local-path-provisioner ]; then
    echo ""
    echo "=== Wiping local-path PVC host directories ==="
    sudo rm -rf /opt/local-path-provisioner/*
fi

if [ "${INSTALL_MODE}" = "fresh" ]; then
    echo ""
    echo "=== Stopping k0s ==="
    sudo k0s stop 2>/dev/null || true
    sudo k0s reset 2>/dev/null || true
    rm -f ~/.kube/config
fi

# Helm cache (chart tarballs) — harmless but tidy.
helm repo update >/dev/null 2>&1 || true

echo ""
echo "=== Uninstall complete ==="
echo "All state on this VM has been wiped. Run scripts/install.sh -y for a"
echo "completely fresh deployment."
