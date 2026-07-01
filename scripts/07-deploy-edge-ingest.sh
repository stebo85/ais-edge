#!/usr/bin/env bash
# =============================================================================
# Step 07: Deploy xnat-ingest pods on the edge cluster
#          Usage: ./07-deploy-edge-ingest.sh <edge-entry>
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <edge-entry>"
    exit 1
fi

parse_edge_entry "$1"

echo "=== 07: Deploying xnat-ingest on ${CLUSTER_NAME} ==="

EDGE_DATA_HOST_PATH="${EDGE_DATA_HOST_PATH:-/data/xnat-ingest}"
ORTHANC_URL="${EDGE_ORTHANC_URL:-http://orthanc.xnat-ingest.svc.cluster.local:8042}"
ORTHANC_STORAGE_DIR="${EDGE_ORTHANC_STORAGE_DIR:-/data/orthanc-storage}"
ORTHANC_LABEL="${EDGE_ORTHANC_LABEL:-xnat-ingest-ready}"
ORTHANC_SKIP_LABEL="${EDGE_ORTHANC_SKIP_LABEL:-xnat-ingest-skip}"
S3_UPLOAD_MAX_WORKERS="${S3_UPLOAD_MAX_WORKERS:-2}"
S3_UPLOAD_LIMIT_UPLOAD="${S3_UPLOAD_LIMIT_UPLOAD:-80MiB}"
EDGE_PATIENTID_PROJECT_ROUTING="${EDGE_PATIENTID_PROJECT_ROUTING:-0}"
EDGE_PATIENTID_PROJECT_ROUTING_FIELD="${EDGE_PATIENTID_PROJECT_ROUTING_FIELD:-PatientID}"
EDGE_AUTO_IMPORT_UNLABELED="${EDGE_AUTO_IMPORT_UNLABELED:-0}"
EDGE_AUTO_IMPORT_REQUIRE_ROUTING_MATCH="${EDGE_AUTO_IMPORT_REQUIRE_ROUTING_MATCH:-0}"
EDGE_AUTO_IMPORT_BATCH_SIZE="${EDGE_AUTO_IMPORT_BATCH_SIZE:-10}"
EDGE_AUTO_IMPORT_ALLOWED_PROJECTS="${EDGE_AUTO_IMPORT_ALLOWED_PROJECTS:-}"

redact_url_userinfo() {
    printf '%s' "$1" | sed -E 's#^(https?://)[^/@]+@#\1<redacted>@#'
}

if [[ "${PROJECT_ID}" == *REPLACE_WITH* ]] || [[ "${ORTHANC_URL}" == *REPLACE_WITH* ]]; then
    echo "ERROR: edge config still contains placeholder values." >&2
    echo "  PROJECT_ID=${PROJECT_ID}" >&2
    echo "  EDGE_ORTHANC_URL=${ORTHANC_URL}" >&2
    echo "Edit config/edge-nodes.env before deploying xnat-ingest." >&2
    exit 1
fi

ORTHANC_LABEL_ARGS=""
if [ -n "${ORTHANC_LABEL}" ]; then
    ORTHANC_LABEL_ARGS=$(printf '            - "--orthanc-label"\n            - "%s"' "${ORTHANC_LABEL}")
fi
if [ -n "${ORTHANC_SKIP_LABEL}" ]; then
    if [ -n "${ORTHANC_LABEL_ARGS}" ]; then
        ORTHANC_LABEL_ARGS="${ORTHANC_LABEL_ARGS}"$'\n'
    fi
    ORTHANC_LABEL_ARGS="${ORTHANC_LABEL_ARGS}$(printf '            - "--orthanc-skip-label"\n            - "%s"' "${ORTHANC_SKIP_LABEL}")"
fi

# Sort's hardlink target. Other edge data dirs are created by 07c for
# repo-managed Orthanc, or by scripts/edge-local-bootstrap.sh for manual
# / unreachable-edge installs.
if [ "${AIS_EDGE_NO_SSH:-}" = "1" ] || [ "${EDGE_JOIN_MODE:-ssh}" = "manual" ]; then
    echo "Skipping SSH directory setup for ${CLUSTER_NAME}; expecting local bootstrap already prepared:"
    echo "  ${EDGE_DATA_HOST_PATH}/staging"
else
    ssh ${SSH_KEY_OPT} "${EDGE_SSH}" \
        "sudo mkdir -p '${EDGE_DATA_HOST_PATH}/staging' && sudo chmod 777 '${EDGE_DATA_HOST_PATH}/staging'"
    echo "Data directories ready on ${NODE_IP}"
fi

# Phase 2: ensure namespace exists and push the CA bundle as a Secret. The
# s3-uploader pod mounts this so mc can verify the seaweedfs-tls server cert
# (issued by ais-edge-ca-issuer).
KUBECONFIG="$EDGE_KC" kubectl create namespace xnat-ingest --dry-run=client -o yaml \
    | KUBECONFIG="$EDGE_KC" kubectl apply -f -

if [ -f "${REPO_DIR}/ais-edge-ca.crt" ]; then
    KUBECONFIG="$EDGE_KC" kubectl create secret generic ca-bundle \
        --namespace xnat-ingest \
        --from-file=ca.crt="${REPO_DIR}/ais-edge-ca.crt" \
        --dry-run=client -o yaml \
        | KUBECONFIG="$EDGE_KC" kubectl apply -f -
    echo "CA bundle Secret pushed to edge cluster"
else
    echo "WARNING: ais-edge-ca.crt not found at ${REPO_DIR} — run 02b-bootstrap-ca.sh first."
    echo "         Phase 2 TLS path will fail until the CA bundle is in place."
fi

# Deploy manifests — render_with_topology strips the {{#ONPREM_ONLY}}
# hostAliases block when INSTALL_TOPOLOGY=cloud, leaving the pod with
# normal DNS resolution.
render_with_topology "${REPO_DIR}/manifests/02-edge/xnat-ingest.yaml.tpl" \
    CLUSTER_NAME "$CLUSTER_NAME" \
    S3_EDGE_ACCESS_KEY "$EDGE_ACCESS_KEY" \
    S3_EDGE_SECRET_KEY "$EDGE_SECRET_KEY" \
    PROJECT_ID "$PROJECT_ID" \
    INGEST_LOOP_SECONDS "$INGEST_LOOP_SECONDS" \
    INGEST_WAIT_PERIOD "$INGEST_WAIT_PERIOD" \
    EDGE_DATA_HOST_PATH "$EDGE_DATA_HOST_PATH" \
    S3_UPLOAD_MAX_WORKERS "$S3_UPLOAD_MAX_WORKERS" \
    S3_UPLOAD_LIMIT_UPLOAD "$S3_UPLOAD_LIMIT_UPLOAD" \
    EDGE_PATIENTID_PROJECT_ROUTING "$EDGE_PATIENTID_PROJECT_ROUTING" \
    EDGE_PATIENTID_PROJECT_ROUTING_FIELD "$EDGE_PATIENTID_PROJECT_ROUTING_FIELD" \
    EDGE_AUTO_IMPORT_UNLABELED "$EDGE_AUTO_IMPORT_UNLABELED" \
    EDGE_AUTO_IMPORT_REQUIRE_ROUTING_MATCH "$EDGE_AUTO_IMPORT_REQUIRE_ROUTING_MATCH" \
    EDGE_AUTO_IMPORT_BATCH_SIZE "$EDGE_AUTO_IMPORT_BATCH_SIZE" \
    EDGE_AUTO_IMPORT_ALLOWED_PROJECTS "$EDGE_AUTO_IMPORT_ALLOWED_PROJECTS" \
    ORTHANC_URL "$ORTHANC_URL" \
    ORTHANC_STORAGE_DIR "$ORTHANC_STORAGE_DIR" \
    ORTHANC_LABEL_ARGS "$ORTHANC_LABEL_ARGS" \
    S3_BUCKET "$S3_BUCKET" \
    MGMT_NODE_IP "${MGMT_NODE_IP:-}" \
    SEAWEEDFS_HOSTNAME "$SEAWEEDFS_HOSTNAME" \
    K0S_API_HOSTNAME "$K0S_API_HOSTNAME" \
    KONNECTIVITY_HOSTNAME "$KONNECTIVITY_HOSTNAME" \
    LOKI_HOSTNAME "${LOKI_HOSTNAME:-loki.aisedge.local}" \
    GRAFANA_HOSTNAME "${GRAFANA_HOSTNAME:-grafana.aisedge.local}" \
    INGRESS_PORT "$INGRESS_PORT" \
    XNAT_INGEST_IMAGE "${XNAT_INGEST_IMAGE:-ghcr.io/australian-imaging-service/xnat-ingest:latest}" \
    | KUBECONFIG="$EDGE_KC" kubectl apply -f -

echo "Waiting for pods..."
sleep 30
KUBECONFIG="$EDGE_KC" kubectl get pods -n xnat-ingest -o wide

# Verify the TLS path from the edge VM. Phase 2 has no HTTP fallback —
# only :443 is exposed. Expect HTTP 403 (S3 unauthenticated GET on /).
if [ "${AIS_EDGE_NO_SSH:-}" = "1" ] || [ "${EDGE_JOIN_MODE:-ssh}" = "manual" ]; then
    echo "Skipping edge-host TLS smoke test for ${CLUSTER_NAME}; SSH is disabled for this edge."
elif [ -f "${REPO_DIR}/ais-edge-ca.crt" ]; then
    echo "Verifying TLS path from edge VM..."
    scp -q ${SSH_KEY_OPT} "${REPO_DIR}/ais-edge-ca.crt" "${EDGE_SSH}:/tmp/ais-edge-ca.crt"
    TLS_HTTP=$(ssh ${SSH_KEY_OPT} "${EDGE_SSH}" \
        "curl -s -o /dev/null -w '%{http_code}' --cacert /tmp/ais-edge-ca.crt https://${SEAWEEDFS_HOSTNAME}/" \
        || echo "000")
    ssh ${SSH_KEY_OPT} "${EDGE_SSH}" "rm -f /tmp/ais-edge-ca.crt"
    echo "SeaweedFS HTTPS (Ingress :${INGRESS_PORT}) from edge: HTTP ${TLS_HTTP:-000}  (expect 403)"
fi

echo "=== 07: Complete for ${CLUSTER_NAME} ==="
echo "Sort is in REST-pull mode against Orthanc: $(redact_url_userinfo "${ORTHANC_URL}")"
if [ "${EDGE_ORTHANC_MODE:-managed}" = "external" ]; then
    echo "Existing Orthanc mode: confirm rsl60's Orthanc is receiving DICOMs and exposes the storage mounted at ${ORTHANC_STORAGE_DIR} in the sort pod."
else
    echo "Push test DICOMs via C-STORE to AET=AISEDGE ${NODE_IP}:4242 (see step 07c output)."
fi
