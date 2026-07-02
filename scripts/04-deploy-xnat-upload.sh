#!/usr/bin/env bash
# =============================================================================
# Step 04: Deploy XNAT upload pod on management cluster
#          Reads from SeaweedFS → uploads to XNAT
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

echo "=== 04: Deploying XNAT upload pod ==="

kubectl create namespace xnat-upload --dry-run=client -o yaml | kubectl apply -f -

XNAT_INTERNAL_URL="${XNAT_INTERNAL_URL:-http://xnat-web.ais-xnat.svc.cluster.local}"
XNAT_UPLOAD_URL="${XNAT_UPLOAD_URL:-$XNAT_URL}"
XNAT_UPLOAD_WAIT_PERIOD="${XNAT_UPLOAD_WAIT_PERIOD:-300}"
XNAT_PROJECT_ADMIN_USERS="${XNAT_PROJECT_ADMIN_USERS:-brosnan,sciget}"

if [[ -n "${XNAT_USER:-}" && -n "${XNAT_PASS:-}" ]]; then
    kubectl create secret generic xnat-token-source \
        -n xnat-upload \
        --from-literal=server="$XNAT_URL" \
        --from-literal=username="$XNAT_USER" \
        --from-literal=password="$XNAT_PASS" \
        --dry-run=client -o yaml | kubectl apply -f -
elif kubectl get secret -n ais-xnat xnat-archiver-creds >/dev/null 2>&1; then
    XNAT_UPLOAD_URL="${XNAT_UPLOAD_URL:-$XNAT_INTERNAL_URL}"
    if [[ -z "${XNAT_USER:-}" && -z "${XNAT_PASS:-}" ]]; then
        XNAT_UPLOAD_URL="$XNAT_INTERNAL_URL"
    fi
    kubectl get secret -n ais-xnat xnat-archiver-creds -o json \
        | jq --arg server "$XNAT_INTERNAL_URL" \
            '{apiVersion:"v1",kind:"Secret",metadata:{name:"xnat-token-source",namespace:"xnat-upload"},type:"Opaque",data:{server:($server|@base64),username:.data.username,password:.data.password}}' \
        | kubectl apply -f -
else
    echo "ERROR: Set XNAT_USER/XNAT_PASS or provide ais-xnat/xnat-archiver-creds for token refresh" >&2
    exit 1
fi

render "${REPO_DIR}/manifests/01-management/xnat-upload.yaml.tpl" \
    XNAT_URL "$XNAT_UPLOAD_URL" \
    XNAT_USER "$XNAT_USER" \
    XNAT_PASS "$XNAT_PASS" \
    S3_ADMIN_ACCESS_KEY "$S3_ADMIN_ACCESS_KEY" \
    S3_ADMIN_SECRET_KEY "$S3_ADMIN_SECRET_KEY" \
    S3_BUCKET "$S3_BUCKET" \
    XNAT_UPLOAD_WAIT_PERIOD "$XNAT_UPLOAD_WAIT_PERIOD" \
    XNAT_PROJECT_ADMIN_USERS "$XNAT_PROJECT_ADMIN_USERS" \
    XNAT_INGEST_IMAGE "${XNAT_INGEST_IMAGE:-ghcr.io/australian-imaging-service/xnat-ingest:latest}" \
    | kubectl apply -f -

refresh_job="xnat-token-refresh-manual-$(date -u +%s)"
kubectl create job -n xnat-upload --from=cronjob/xnat-token-refresh "$refresh_job"
kubectl wait -n xnat-upload --for=condition=complete "job/$refresh_job" --timeout=180s
kubectl logs -n xnat-upload "job/$refresh_job"
kubectl delete job -n xnat-upload "$refresh_job" --ignore-not-found >/dev/null

kubectl rollout status deployment/xnat-ingest-upload -n xnat-upload --timeout=180s
kubectl wait --for=condition=Available deployment/xnat-ingest-upload -n xnat-upload --timeout=180s 2>/dev/null || true

echo "=== 04: Complete ==="
kubectl get pods -n xnat-upload
