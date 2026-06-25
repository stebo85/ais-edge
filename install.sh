#!/usr/bin/env bash
# =============================================================================
# k0s + k0smotron + SeaweedFS Edge Setup — Interactive Installer
# =============================================================================
# Calls each script in order. Only edit config files — never edit scripts.
#
# Config files:
#   config/management.env   — Management node, SeaweedFS, XNAT settings
#   config/edge-nodes.env   — Edge node list (supports multiple sites)
#
# Usage:
#   cp config/management.env.template config/management.env
#   cp config/edge-nodes.env.template config/edge-nodes.env
#   vim config/management.env config/edge-nodes.env
#   ./install.sh           # interactive — prompts before each step
#   ./install.sh -y        # auto-confirm (non-interactive / CI)
#   yes y | ./install.sh   # also non-interactive (stdin not a TTY → auto-confirm)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/00-common.sh"

# Detect non-interactive mode:
#   * --yes / -y on the command line, OR
#   * stdin is not a TTY (piped, redirected, run by an automation tool).
# In non-interactive mode we run every step without asking. In interactive
# mode we prompt at every step (legacy behaviour, useful when triaging).
INTERACTIVE=true
for arg in "$@"; do
    case "$arg" in
        -y|--yes) INTERACTIVE=false ;;
    esac
done
[ -t 0 ] || INTERACTIVE=false

# Forwarded to child scripts (e.g. 07c's deid-policy review prompt). When
# install.sh is non-interactive, child scripts should auto-confirm too.
if ! $INTERACTIVE; then export AIS_AUTO_CONFIRM="yes"; fi

confirm() {
    local prompt="$1"
    if ! $INTERACTIVE; then
        echo "$prompt y (auto)"
        REPLY=y
        return 0
    fi
    REPLY=""
    read -p "$prompt " -r || REPLY=y
}

# --- Validate required config ---
REQUIRED_VARS=(
    MGMT_NODE_IP XNAT_URL XNAT_USER XNAT_PASS
    S3_ADMIN_ACCESS_KEY S3_ADMIN_SECRET_KEY S3_BUCKET
    INTERNAL_DOMAIN SEAWEEDFS_HOSTNAME K0S_API_HOSTNAME
    KONNECTIVITY_HOSTNAME INGRESS_PORT
)
if [ "${EDGE_ORTHANC_MODE:-managed}" != "external" ]; then
    REQUIRED_VARS+=(AIS_DEID_HMAC_SALT)
fi
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: ${var} is not set in config/management.env"
        [ "$var" = "AIS_DEID_HMAC_SALT" ] && echo "       Generate one with: openssl rand -hex 32"
        exit 1
    fi
done

# --- Cloud credentials: generic auto-source + per-provider guard ---
# When INSTALL_TOPOLOGY=cloud, the install needs cloud-provider credentials
# in the environment (OS_* for OpenStack, AWS_* for AWS, etc.). Rather than
# making the operator remember `source openrc.sh` (or its AWS/GCP/Azure
# equivalent) before every install, we:
#   1. Source CLOUD_CREDENTIALS_FILE if it's set (provider-agnostic — it's
#      just a shell script of `export X=Y` lines, same shape for any cloud).
#   2. Run a per-provider guard (provider_guard_<name>) to confirm the
#      variables actually arrived. The guard returns non-empty stdout when
#      something is missing; we print the message and either prompt for a
#      credentials file (interactive) or exit with a fix-up hint (-y).
#
# To add a new provider you only add ONE function below — install.sh and
# 01b each have a single switch table that pick it up. No other file
# touches credentials.
if [ "${INSTALL_TOPOLOGY:-onprem}" = "cloud" ]; then
    CLOUD_PROVIDER="${CLOUD_PROVIDER:-openstack}"

    # Source a credentials file if specified — works for any cloud, the
    # file is just `export X=Y` lines.
    _source_creds() {
        local f="$1"
        [ -z "$f" ] && return 0
        if [ ! -f "$f" ]; then
            echo "ERROR: CLOUD_CREDENTIALS_FILE='${f}' does not exist." >&2
            return 1
        fi
        echo "Sourcing cloud credentials from ${f}"
        set +u
        # shellcheck disable=SC1090
        source "$f"
        set -u
    }
    _source_creds "${CLOUD_CREDENTIALS_FILE:-}" || exit 1

    # Per-provider guard — each one echoes a human-readable error message
    # to stdout if something is missing, or stays silent if everything's
    # in place. Add new providers here and only here.
    # Each guard echoes a human-readable error string when something is
    # missing; otherwise stays silent. ALWAYS returns 0 — we never want
    # a probe to trip `set -e` here, only an unset variable should fail.
    provider_guard_openstack() {
        local m=()
        [ -z "${OS_AUTH_URL:-}" ] && m+=("OS_AUTH_URL")
        [ -z "${OS_REGION_NAME:-}" ] && m+=("OS_REGION_NAME")
        if [ -z "${OS_APPLICATION_CREDENTIAL_ID:-}" ] && \
           [ -z "${OS_USERNAME:-}" ]; then
            m+=("OS_APPLICATION_CREDENTIAL_ID (preferred) OR OS_USERNAME")
        fi
        if [ ${#m[@]} -gt 0 ]; then
            echo "OpenStack credentials missing: ${m[*]}. Easiest fix is to download the Keystone openrc.sh from your dashboard (Identity → Application Credentials)."
        fi
        return 0
    }
    provider_guard_aws() {
        # On managed EKS the AWS SDK chain finds creds in ~/.aws/credentials
        # or in IAM-role metadata. Only flag if we see NONE of the usual
        # signals (no static keys, no profile, no shared file).
        if [ -z "${AWS_ACCESS_KEY_ID:-}" ] && \
           [ -z "${AWS_PROFILE:-}" ] && \
           [ ! -f "${HOME}/.aws/credentials" ]; then
            echo "No AWS credentials found. Either set AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY, run 'aws configure', or set AWS_PROFILE."
        fi
        return 0
    }
    provider_guard_gcp() {
        if [ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && \
           [ ! -f "${HOME}/.config/gcloud/application_default_credentials.json" ]; then
            echo "No GCP credentials found. Either set GOOGLE_APPLICATION_CREDENTIALS=path/to/sa.json or run 'gcloud auth application-default login'."
        fi
        return 0
    }
    provider_guard_azure() {
        if [ ! -d "${HOME}/.azure" ] && [ -z "${AZURE_CLIENT_ID:-}" ]; then
            echo "No Azure credentials found. Run 'az login' or set AZURE_CLIENT_ID/AZURE_TENANT_ID/AZURE_CLIENT_SECRET."
        fi
        return 0
    }
    provider_guard_none() { return 0; }   # bring-your-own-LB: no creds to check

    case "$CLOUD_PROVIDER" in
        openstack|aws|gcp|azure|none) ;;
        *)
            echo "ERROR: unknown CLOUD_PROVIDER='${CLOUD_PROVIDER}'."
            echo "       Valid values: openstack | aws | gcp | azure | none"
            exit 1
            ;;
    esac

    msg="$(provider_guard_${CLOUD_PROVIDER})"

    # If something's missing AND we have a TTY, give the operator one
    # chance to point us at a credentials file interactively. In -y mode
    # we skip the prompt — automation has no human to ask.
    if [ -n "$msg" ] && $INTERACTIVE; then
        echo ""
        echo "$msg"
        echo ""
        read -p "Path to a credentials file to source now (blank to abort): " -r path
        if [ -n "$path" ]; then
            _source_creds "$path" || exit 1
            msg="$(provider_guard_${CLOUD_PROVIDER})"
        fi
    fi

    if [ -n "$msg" ]; then
        echo ""
        echo "ERROR: $msg"
        echo "       Set CLOUD_CREDENTIALS_FILE in config/management.env (or"
        echo "       export the variables in your shell) and re-run install.sh."
        exit 1
    fi

    # LB_PUBLIC_IP is optional now. If set, the cloud LB controller will
    # try to associate that exact IP; if blank, the LB gets an auto-
    # assigned VIP and we use it directly. The latter is the only path that
    # works on Nectar QLD topology — see docs/cloud-deployment.md.
fi

if [ "${EDGE_ORTHANC_MODE:-managed}" != "external" ]; then
    # Orthanc per-site config is edited by hand. Fail fast here rather than
    # 10 minutes into mgmt setup at step 07c.
    if [ ! -f "${SCRIPT_DIR}/config/orthanc/routing.json" ]; then
        echo "ERROR: config/orthanc/routing.json not found"
        echo "       Copy from the template and fill in AETMap:"
        echo "         cp config/orthanc/routing.json.template config/orthanc/routing.json"
        echo "         vim config/orthanc/routing.json"
        exit 1
    fi
    # Deidentification profile must be filled in. Ships as a .template; the
    # Site admin copies it from the template and customises to the site's deid policy.
    if [ ! -f "${SCRIPT_DIR}/config/orthanc/deidentification-profile.json" ]; then
        echo "ERROR: config/orthanc/deidentification-profile.json not found"
        echo "       Copy the template and customise to your site's deid policy:"
        echo "         cp config/orthanc/deidentification-profile.json.template \\"
        echo "            config/orthanc/deidentification-profile.json"
        echo "         vim config/orthanc/deidentification-profile.json"
        exit 1
    fi
else
    echo "EDGE_ORTHANC_MODE=external — skipping repo-managed Orthanc config validation."
fi
if [ ${#EDGE_NODES[@]} -eq 0 ]; then
    echo "ERROR: No edge nodes defined in config/edge-nodes.env"
    exit 1
fi

# --- Show plan ---
echo ""
echo "============================================"
echo " k0s + k0smotron + SeaweedFS Edge Setup"
echo "============================================"
echo ""
echo " Management node:    ${MGMT_NODE_IP}"
echo " Install mode:       ${INSTALL_MODE}"
echo " Internal domain:    ${INTERNAL_DOMAIN}"
echo " Edge ingress port:  ${INGRESS_PORT} (TLS, single outbound)"
echo " SeaweedFS host:     ${SEAWEEDFS_HOSTNAME}"
echo " k0s API host:       ${K0S_API_HOSTNAME}"
echo " konnectivity host:  ${KONNECTIVITY_HOSTNAME}"
echo " XNAT target:        ${XNAT_URL}"
echo ""
echo " Edge nodes (${#EDGE_NODES[@]}):"
for entry in "${EDGE_NODES[@]}"; do
    IFS='|' read -r name ip _ _ project _ _ <<< "$entry"
    echo "   - ${name} → ${ip} (project: ${project})"
done
echo ""
echo " Steps:"
echo "   01.  Install k0s management cluster (or use existing)"
echo "   00a. Pre-create Octavia LB (OpenStack + PRECREATE_LB=1; no-op otherwise)"
echo "   01b. Cloud-controller-manager (cloud topology only; no-op otherwise)"
echo "   02.  Install cert-manager + k0smotron operator"
echo "   02b. Bootstrap self-signed CA (single-port TLS)"
echo "   02c. Install nginx-ingress (hostNetwork :443 or LoadBalancer Service)"
echo "   03.  Deploy SeaweedFS (ClusterIP + TLS Ingress)"
echo "   04.  Deploy XNAT upload pod (in-cluster: SeaweedFS → XNAT)"
echo "   For each edge node:"
echo "     05. Create hosted k0s control plane (with built-in Ingress)"
if [ "${EDGE_JOIN_MODE:-ssh}" = "manual" ]; then
    echo "     06a. Create local bootstrap bundle (manual edge join; no SSH)"
else
    echo "     06. Install k0s worker (sets /etc/hosts + patches CoreDNS)"
fi
echo "     07. Deploy xnat-ingest (sort in REST-pull mode + s3-uploader)"
echo "     07b. Deploy Vector log shipper (skipped if observability disabled)"
if [ "${EDGE_ORTHANC_MODE:-managed}" = "external" ]; then
    echo "     07c. Skip Orthanc deploy (EDGE_ORTHANC_MODE=external)"
else
    echo "     07c. Deploy Orthanc DICOM receiver + deid hook"
fi
echo ""
echo "============================================"
confirm "Proceed with installation? (y/N) "
[[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ============================================================================
echo ""
echo "========================================"
echo " Phase 1: Management Cluster"
echo "========================================"

echo ""
echo "--- Step 01: k0s management cluster ---"
confirm "Run step 01? (y/s to skip) "
[[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/01-install-k0s.sh"

# Step 00a: pre-create the Octavia LB on Nectar / OpenStack shared-public-
# network topologies, so the rest of the install can run with a known
# public IP. Only runs when INSTALL_TOPOLOGY=cloud, CLOUD_PROVIDER=openstack,
# PRECREATE_LB=1, AND LB_PUBLIC_IP isn't already pinned. Skips silently
# everywhere else (incl. AWS / GCP / Azure managed K8s). Sequenced AFTER
# 01 (so the openstack CLI is available) but BEFORE 01b (which reads
# LB_PUBLIC_IP into cloud.conf) and 02b (which reads INTERNAL_DOMAIN into
# cert SANs). Writes back to config/management.env if it creates one.
echo ""
echo "--- Step 00a: Pre-create LB (Nectar / OpenStack opt-in) ---"
confirm "Run step 00a? (y/s to skip) "
if [[ ! $REPLY =~ ^[Ss]$ ]]; then
    bash "${SCRIPT_DIR}/scripts/00a-precreate-lb.sh"
    # Re-source management.env in case 00a wrote new values back.
    # shellcheck disable=SC1090,SC1091
    source "${SCRIPT_DIR}/config/management.env"
fi

# Step 01b: install the cloud-controller-manager so Service type LoadBalancer
# can provision a real LB. Only runs when INSTALL_TOPOLOGY=cloud; skips
# cleanly otherwise. Doesn't apply on EKS/AKS/GKE/Magnum where the CCM is
# already part of the managed control plane.
echo ""
echo "--- Step 01b: Cloud-controller-manager (cloud topology only) ---"
confirm "Run step 01b? (y/s to skip) "
[[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/01b-install-cloud-controller.sh"

echo ""
echo "--- Step 02: cert-manager + k0smotron ---"
confirm "Run step 02? (y/s to skip) "
[[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/02-install-k0smotron.sh"

echo ""
echo "--- Step 02b: Bootstrap self-signed CA ---"
confirm "Run step 02b? (y/s to skip) "
[[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/02b-bootstrap-ca.sh"

echo ""
echo "--- Step 02c: Install nginx-ingress (hostNetwork :443 OR LoadBalancer) ---"
confirm "Run step 02c? (y/s to skip) "
[[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/02c-install-nginx-ingress.sh"

echo ""
echo "--- Step 03: SeaweedFS ---"
confirm "Run step 03? (y/s to skip) "
[[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/03-deploy-seaweedfs.sh"

echo ""
echo "--- Step 04: XNAT upload pod ---"
confirm "Run step 04? (y/s to skip) "
[[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/04-deploy-xnat-upload.sh"

echo ""
echo "--- Step 02d: Observability (Loki + Prom + Grafana + Vector) ---"
echo "  (skipped automatically if ALERT_EMAIL_TO is empty)"
confirm "Run step 02d? (y/s to skip) "
[[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/02d-install-observability.sh"

# ============================================================================
echo ""
echo "========================================"
echo " Phase 2 & 3: Edge Nodes"
echo "========================================"

for entry in "${EDGE_NODES[@]}"; do
    IFS='|' read -r name ip _ _ project _ _ <<< "$entry"
    echo ""
    echo "========================================"
    echo " Edge: ${name} (${ip}) → project: ${project}"
    echo "========================================"

    echo ""
    echo "--- Step 05: Create hosted cluster '${name}' ---"
    confirm "Run step 05 for ${name}? (y/s to skip) "
    [[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/05-setup-edge-cluster.sh" "$entry"

    echo ""
    if [ "${EDGE_JOIN_MODE:-ssh}" = "manual" ]; then
        echo "--- Step 06a: Create local bootstrap bundle for ${name} ---"
        confirm "Run step 06a for ${name}? (y/s to skip) "
        [[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/06a-create-edge-bootstrap-bundle.sh" "$entry"

        if KUBECONFIG="${SCRIPT_DIR}/kubeconfig-${name}" kubectl get nodes --no-headers 2>/dev/null | grep -q " Ready "; then
            echo "Manual edge '${name}' already has a Ready node; continuing with workload deploy."
        else
            echo ""
            echo "Manual join required for '${name}'. Transfer the bundle under secrets/ to the edge,"
            echo "run ./bootstrap-rsl60.sh locally there, then re-run install.sh or steps 07/07b/07c."
            echo "Skipping workload deploy for ${name} until its worker is Ready."
            continue
        fi
    else
        echo "--- Step 06: Install k0s worker on ${ip} ---"
        confirm "Run step 06 for ${name}? (y/s to skip) "
        [[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/06-join-edge-worker.sh" "$entry"
    fi

    echo ""
    echo "--- Step 07: Deploy xnat-ingest on ${name} ---"
    confirm "Run step 07 for ${name}? (y/s to skip) "
    [[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/07-deploy-edge-ingest.sh" "$entry"

    echo ""
    echo "--- Step 07b: Deploy Vector log shipper on ${name} (observability) ---"
    echo "    (skipped automatically if observability stack not installed)"
    confirm "Run step 07b for ${name}? (y/s to skip) "
    [[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/07b-deploy-edge-observability.sh" "$entry"

    echo ""
    echo "--- Step 07c: Deploy Orthanc DICOM receiver + deid hook on ${name} ---"
    confirm "Run step 07c for ${name}? (y/s to skip) "
    [[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/07c-deploy-edge-orthanc.sh" "$entry"
done

# ============================================================================
echo ""
echo "============================================"
echo " Installation Complete!"
echo "============================================"
echo ""
echo " Management cluster:    kubectl get pods -A"
echo ""
echo " ---- Edge-facing endpoints (single TLS port :${INGRESS_PORT}) ----"
echo " SeaweedFS S3:          https://${SEAWEEDFS_HOSTNAME}     (CA: ais-edge-ca.crt)"
echo " k0s API (per cluster): https://${K0S_API_HOSTNAME}       (kubeconfig server URL)"
echo " konnectivity:          https://${KONNECTIVITY_HOSTNAME}   (worker tunnel back)"
echo ""
echo " ---- Admin endpoints (kubectl port-forward) ----"
echo " SeaweedFS S3 admin:    kubectl port-forward -n seaweedfs svc/seaweedfs 8333:8333"
echo " SeaweedFS master UI:   kubectl port-forward -n seaweedfs svc/seaweedfs 9333:9333"
echo " SeaweedFS filer UI:    kubectl port-forward -n seaweedfs svc/seaweedfs 8888:8888"
echo "                        (admin key: ${S3_ADMIN_ACCESS_KEY})"
echo ""
echo " ---- Distribute to edge VMs ----"
echo " ais-edge-ca.crt is at: ${SCRIPT_DIR}/ais-edge-ca.crt"
echo " Copy it to each edge for verifying server certs."
echo ""
for entry in "${EDGE_NODES[@]}"; do
    IFS='|' read -r name ip _ _ _ _ _ <<< "$entry"
    echo " Edge '${name}' (${ip}):"
    echo "   Nodes:   kubectl --kubeconfig kubeconfig-${name} get nodes"
    echo "   Pods:    kubectl --kubeconfig kubeconfig-${name} get pods -n xnat-ingest"
    echo "   Sort:    kubectl --kubeconfig kubeconfig-${name} logs -n xnat-ingest -l component=sort -f"
    echo "   Upload:  kubectl --kubeconfig kubeconfig-${name} logs -n xnat-ingest -l component=s3-uploader -f"
    echo "   Test:    scp file.dcm ${ip}:/data/xnat-ingest/incoming/"
    echo ""
done
echo " XNAT upload (mgmt): kubectl logs -n xnat-upload -l component=upload -f"
echo ""
