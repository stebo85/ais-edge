#!/usr/bin/env bash
# =============================================================================
# Step 07c: Deploy Orthanc DICOM receiver + deid hook on the edge cluster.
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

if [ "${EDGE_ORTHANC_MODE:-managed}" = "external" ] || [ "${AIS_SKIP_ORTHANC_DEPLOY:-}" = "1" ]; then
    echo "=== 07c: Orthanc deploy — SKIPPED for ${CLUSTER_NAME} ==="
    echo "EDGE_ORTHANC_MODE=external means an existing Orthanc is expected at:"
    echo "  ${EDGE_ORTHANC_URL:-<set EDGE_ORTHANC_URL in config/edge-nodes.env>}"
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

# routing.json is site-edited — must be copied from the template
# and filled in with the AETMap entries for this site's modalities.
if [ ! -f "${ORTHANC_CFG_DIR}/routing.json" ]; then
    echo "ERROR: ${ORTHANC_CFG_DIR}/routing.json not found"
    echo "       Copy from the template and edit the AETMap:"
    echo "         cp ${ORTHANC_CFG_DIR}/routing.json.template ${ORTHANC_CFG_DIR}/routing.json"
    echo "         vim ${ORTHANC_CFG_DIR}/routing.json"
    exit 1
fi

if [ -z "${AIS_DEID_HMAC_SALT:-}" ]; then
    echo "ERROR: AIS_DEID_HMAC_SALT not set in config/management.env"
    echo "       Generate one with: openssl rand -hex 32"
    exit 1
fi

ORTHANC_IMAGE="${ORTHANC_IMAGE:-jodogne/orthanc-plugins:1.12.6}"

echo "=== 07c: Deploying Orthanc on ${CLUSTER_NAME} ==="
echo "Image:  ${ORTHANC_IMAGE}"

# --- Site-admin confirmation: deid policy review ---
# Deid is a regulatory + ethical surface. Don't deploy without an explicit
# acknowledgement that the site admin has read what's being applied. Show the
# routing table and the list of profiles, then prompt.
echo
echo "=== Deidentification policy that will be deployed ==="
echo
echo "--- routing.json (AET -> profile + project) ---"
sed -n '/"AETMap"/,/^  }/p' "${ORTHANC_CFG_DIR}/routing.json" | head -30
echo
echo "--- deidentification profile to be installed ---"
echo "  ${ORTHANC_CFG_DIR}/deidentification-profile.json"
echo
# Honour the -y / --yes flag the parent install.sh forwards via env if set.
# Otherwise prompt interactively. Skip if stdin isn't a TTY (CI runs).
if [ "${AIS_AUTO_CONFIRM:-}" != "yes" ] && [ -t 0 ]; then
    read -p "Have you reviewed the AETMap + profiles above? [y/N] " -r REPLY
    [[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborted at deid-policy review."; exit 1; }
fi

# --- Host-side directories on the edge ---
if [ "${AIS_EDGE_NO_SSH:-}" = "1" ] || [ "${EDGE_JOIN_MODE:-ssh}" = "manual" ]; then
    echo "Skipping SSH directory setup for ${CLUSTER_NAME}; expecting local bootstrap already prepared:"
    echo "  /data/xnat-ingest/orthanc-storage"
    echo "  /data/facility-backup"
else
    ssh ${SSH_KEY_OPT} "${EDGE_SSH}" "
        sudo mkdir -p /data/xnat-ingest/orthanc-storage /data/facility-backup
        sudo chmod 777 /data/xnat-ingest/orthanc-storage
        sudo chmod 750 /data/facility-backup
    "
    echo "Edge directories ready: /data/xnat-ingest/orthanc-storage, /data/facility-backup"
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

# orthanc-scripts: lua hooks (deid + forward + study label)
KUBECONFIG="$EDGE_KC" kubectl create configmap orthanc-scripts \
    --namespace xnat-ingest \
    --from-file="${ORTHANC_CFG_DIR}/deidentify-and-forward.lua" \
    --dry-run=client -o yaml \
    | KUBECONFIG="$EDGE_KC" kubectl apply -f -

# orthanc-routing: per-site AET -> project mapping
KUBECONFIG="$EDGE_KC" kubectl create configmap orthanc-routing \
    --namespace xnat-ingest \
    --from-file=routing.json="${ORTHANC_CFG_DIR}/routing.json" \
    --dry-run=client -o yaml \
    | KUBECONFIG="$EDGE_KC" kubectl apply -f -

# orthanc-deidentification-profile: the single deidentification-profile.json
# file (site-edited, copied from .template). Loaded directly
# by the Lua hook for every accepted study.
if [ ! -f "${ORTHANC_CFG_DIR}/deidentification-profile.json" ]; then
    echo "ERROR: ${ORTHANC_CFG_DIR}/deidentification-profile.json not found"
    echo "       Copy the template and customise to your site's deid policy:"
    echo "         cp ${ORTHANC_CFG_DIR}/deidentification-profile.json.template \\"
    echo "            ${ORTHANC_CFG_DIR}/deidentification-profile.json"
    echo "         vim ${ORTHANC_CFG_DIR}/deidentification-profile.json"
    exit 1
fi
KUBECONFIG="$EDGE_KC" kubectl create configmap orthanc-deidentification-profile \
    --namespace xnat-ingest \
    --from-file=deidentification-profile.json="${ORTHANC_CFG_DIR}/deidentification-profile.json" \
    --dry-run=client -o yaml \
    | KUBECONFIG="$EDGE_KC" kubectl apply -f -

echo "ConfigMaps applied: orthanc-config, orthanc-scripts, orthanc-routing, orthanc-deidentification-profile"

# --- Secret + Deployment + Service ---
render "${REPO_DIR}/manifests/02-edge/orthanc.yaml.tpl" \
    ORTHANC_IMAGE "$ORTHANC_IMAGE" \
    AIS_DEID_HMAC_SALT "$AIS_DEID_HMAC_SALT" \
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
