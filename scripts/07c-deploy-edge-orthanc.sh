#!/usr/bin/env bash
# =============================================================================
# Step 07c: Deploy Orthanc DICOM receiver + label hook on the edge cluster.
#           Runs alongside xnat-ingest sort (deployed in step 07).
#           Usage: ./07c-deploy-edge-orthanc.sh <edge-entry>
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <edge-entry>"
    exit 1
fi
parse_edge_entry "$1"

redact_url_userinfo() {
    printf '%s' "$1" | sed -E 's#^(https?://)[^/@]+@#\1<redacted>@#'
}

if [ "${EDGE_ORTHANC_MODE:-managed}" = "external" ] || [ "${AIS_SKIP_ORTHANC_DEPLOY:-}" = "1" ]; then
    echo "=== 07c: Orthanc deploy — SKIPPED for ${CLUSTER_NAME} ==="
    echo "EDGE_ORTHANC_MODE=external means an existing Orthanc is expected at:"
    if [ -n "${EDGE_ORTHANC_URL:-}" ]; then
        echo "  $(redact_url_userinfo "${EDGE_ORTHANC_URL}")"
    else
        echo "  <set EDGE_ORTHANC_URL in config/edge-nodes.env>"
    fi
    exit 0
fi

ORTHANC_CFG_DIR="${REPO_DIR}/config/orthanc"

# --- Validate required inputs ---
for f in orthanc.json deidentify-and-forward.lua; do
    if [ ! -f "${ORTHANC_CFG_DIR}/${f}" ]; then
        echo "ERROR: ${ORTHANC_CFG_DIR}/${f} not found"
        exit 1
    fi
done

ORTHANC_IMAGE="${ORTHANC_IMAGE:-jodogne/orthanc-plugins:1.12.6}"

echo "=== 07c: Deploying Orthanc on ${CLUSTER_NAME} ==="
echo "Image:  ${ORTHANC_IMAGE}"

# --- Host-side directories on the edge ---
if [ "${AIS_EDGE_NO_SSH:-}" = "1" ] || [ "${EDGE_JOIN_MODE:-ssh}" = "manual" ]; then
    echo "Skipping SSH directory setup for ${CLUSTER_NAME}; expecting local bootstrap already prepared:"
    echo "  /data/xnat-ingest/orthanc-storage"
else
    ssh ${SSH_KEY_OPT} "${EDGE_SSH}" "
        sudo mkdir -p /data/xnat-ingest/orthanc-storage
        sudo chmod 777 /data/xnat-ingest/orthanc-storage
    "
    echo "Edge directories ready: /data/xnat-ingest/orthanc-storage"
fi

# --- Namespace (idempotent if 07 already ran) ---
KUBECONFIG="$EDGE_KC" kubectl create namespace xnat-ingest --dry-run=client -o yaml \
    | KUBECONFIG="$EDGE_KC" kubectl apply -f -

# --- ConfigMaps from config/orthanc/ files ---
# orthanc.json: the daemon config (ports, storage paths, lua scripts list)
KUBECONFIG="$EDGE_KC" kubectl create configmap orthanc-config \
    --namespace xnat-ingest \
    --from-file=orthanc.json="${ORTHANC_CFG_DIR}/orthanc.json" \
    --dry-run=client -o yaml \
    | KUBECONFIG="$EDGE_KC" kubectl apply -f -

# orthanc-scripts: lua hook that labels stable studies for ingest
KUBECONFIG="$EDGE_KC" kubectl create configmap orthanc-scripts \
    --namespace xnat-ingest \
    --from-file="${ORTHANC_CFG_DIR}/deidentify-and-forward.lua" \
    --dry-run=client -o yaml \
    | KUBECONFIG="$EDGE_KC" kubectl apply -f -

echo "ConfigMaps applied: orthanc-config, orthanc-scripts"

# --- Secret + Deployment + Service ---
render "${REPO_DIR}/manifests/02-edge/orthanc.yaml.tpl" \
    ORTHANC_IMAGE "$ORTHANC_IMAGE" \
    | KUBECONFIG="$EDGE_KC" kubectl apply -f -

echo "Waiting for Orthanc pod..."
KUBECONFIG="$EDGE_KC" kubectl rollout status -n xnat-ingest deployment/orthanc --timeout=180s || true
KUBECONFIG="$EDGE_KC" kubectl get pods -n xnat-ingest -l app=orthanc -o wide

# --- REST API smoke test from the edge host (hostPort exposes 4242; 8042 is ClusterIP) ---
ORTHANC_POD=$(KUBECONFIG="$EDGE_KC" kubectl get pod -n xnat-ingest -l app=orthanc -o name 2>/dev/null | head -1)
if [ -n "$ORTHANC_POD" ]; then
    KUBECONFIG="$EDGE_KC" kubectl exec -n xnat-ingest "$ORTHANC_POD" -- \
        sh -c 'wget -qO- http://localhost:8042/system 2>/dev/null | head -c 200' || true
    echo
fi

echo "=== 07c: Complete for ${CLUSTER_NAME} ==="
echo
echo "Modality DICOM endpoint (C-STORE target):"
echo "  AET=AISEDGE  Host=${NODE_IP}  Port=4242"
echo
echo "Smoke test from a modality or storescu:"
echo "  storescu -aec AISEDGE -aet TEST_MOD ${NODE_IP} 4242 path/to/study/*.dcm"
