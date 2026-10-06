#!/usr/bin/env bash
# =============================================================================
# AIS Edge installer
# =============================================================================
#   ./install.sh <site>          interactive, step by step
#   ./install.sh -y <site>       non-interactive
#
#   e.g.  ./install.sh stream-2-ab-dev
#
# ONE SOURCE OF TRUTH: sites/<site>/values.yaml
#
# That file is read by this script AND passed to both Helm releases, so a fact
# is stated once. It replaces config/management.env + config/edge-nodes.env,
# which were a second, parallel configuration the charts could not see. With
# two files the same fact was typed twice — the edge's name, the management
# node's IP, the hostnames, the staging bucket — and every one of those
# mismatches failed SILENTLY: the edge retries an endpoint that will never
# answer, preserves its local copy (correctly), and the management side, which
# watches for arrivals rather than absences, reports nothing wrong.
#
# WHAT THIS SCRIPT STILL DOES ITSELF, AND WHY IT IS NOT ALL HELM
#
# Helm needs an API server, a cluster and CRDs. These steps create them:
#
#   1  k0s, kubectl, helm, local-path-provisioner        no cluster yet
#   2  cert-manager CRDs + the k0smotron operator        no CRDs yet
#   3  site Secrets                                      before the workloads
#   4  helm: the management chart                        <- everything else
#   5  per edge: child kubeconfig + join token           token must not be
#                                                        re-minted on upgrade
#   6  per edge: join the worker over SSH                no API server on the
#                                                        edge until this runs
#   7  helm: the edge chart                              <- everything else
#
# Steps 4 and 7 replace what used to be scripts 02b/02c/02d/03/04/07/07b/07c.
#
# There is no `--set` anywhere below. A flag needed to make an install work is
# a value that belongs in the site file, and an install nobody can reproduce
# from the file alone is not reproducible.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prerequisite versions. PINNED, and pinned HERE rather than fetched from
# /latest/ and /stable/ URLs as the previous installer did — a rebuild months
# apart got whatever upstream had published that morning, which is the whole
# reason the charts pin their dependencies.
CERT_MANAGER_VERSION="v1.20.3"
K0SMOTRON_VERSION="v2.0.3"

INTERACTIVE=true
SITE=""
for arg in "$@"; do
    case "$arg" in
        -y|--yes) INTERACTIVE=false ;;
        -*) echo "unknown flag: $arg" >&2; exit 1 ;;
        *)  SITE="$arg" ;;
    esac
done

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[install] $*"; }

confirm() {
    $INTERACTIVE || { echo "$1 y (auto)"; REPLY=y; return 0; }
    REPLY=""
    read -rp "$1 " || REPLY=y
}

step() {   # step <label>; returns 1 if the operator chose to skip
    echo
    echo "--- $1 ---"
    confirm "Run this step? (y/s to skip)"
    [[ "$REPLY" =~ ^[Ss]$ ]] && { info "skipped"; return 1; }
    return 0
}

# --- locate the site ---------------------------------------------------------
[ -n "$SITE" ] || die "usage: $0 [-y] <site>    (a directory under sites/)"
SITE_DIR="${SCRIPT_DIR}/sites/${SITE}"
VALUES="${SITE_DIR}/values.yaml"
SECRETS="${SITE_DIR}/secrets.enc.yaml"
[ -d "$SITE_DIR" ] || die "no such site: sites/${SITE}"
[ -f "$VALUES" ]   || die "missing ${VALUES}"

for t in kubectl helm python3; do
    command -v "$t" >/dev/null 2>&1 || MISSING="${MISSING:-} $t"
done

# --- read the site file ------------------------------------------------------
# Every value this script needs comes from here. `cfg` prints one field; it
# fails loudly rather than returning an empty string, because an empty value
# silently produces a broken /etc/hosts entry or an unreachable endpoint.
cfg() { # cfg <dotted.path> [default]
    python3 - "$VALUES" "$1" "${2-__REQUIRED__}" <<'PY'
import sys, yaml
path_file, dotted, default = sys.argv[1], sys.argv[2], sys.argv[3]
cur = yaml.safe_load(open(path_file)) or {}
for part in dotted.split('.'):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        cur = None
        break
if cur is None or cur == '':
    if default == '__REQUIRED__':
        sys.stderr.write(f"ERROR: {dotted} is not set in {path_file}\n")
        sys.exit(1)
    cur = default
print(cur)
PY
}

edges_json() {
    python3 -c "
import sys,yaml,json
print(json.dumps((yaml.safe_load(open('$VALUES')) or {}).get('edges') or []))"
}

MGMT_NS="ais-mgmt"
MGMT_RELEASE="mgmt"

# Exported for EVERY script this file calls, not just the per-edge ones.
# scripts/00-common.sh is sourced by all of them and would otherwise load
# config/*.env over the top of the values read below — which is exactly the
# second source of truth this installer exists to remove. Set before step 1,
# because step 1 sources it too.
export AIS_CONFIG_FROM_SITE=1
MGMT_NODE_IP="$(cfg domain.mgmtNodeIP)"
INTERNAL_DOMAIN="$(cfg domain.internal)"
INGRESS_PORT="$(cfg ingressPort 443)"
INSTALL_TOPOLOGY="$(cfg topology onprem)"
INSTALL_MODE="$(cfg installMode fresh)"
# Exported here, not at first use: scripts/00-common.sh asserts MGMT_NODE_IP is
# present as soon as it is sourced, and step 1 sources it.
# The published management hostnames, derived exactly as the charts derive
# them (hostnames.<x>, else <x>.<domain.internal>) so the /etc/hosts entries
# scripts/05 and 06 write on the management node and on each edge name the
# same hosts the charts issue certificates for. A mismatch here does not error:
# the pod gets NXDOMAIN, the uploader treats it as an unreachable endpoint and
# keeps the local copy, and the management side sees only an absence it is not
# watching for.
SEAWEEDFS_HOSTNAME="$(cfg hostnames.seaweedfs "seaweedfs.${INTERNAL_DOMAIN}")"
GRAFANA_HOSTNAME="$(cfg hostnames.grafana "grafana.${INTERNAL_DOMAIN}")"
LOKI_HOSTNAME="$(cfg hostnames.loki "loki.${INTERNAL_DOMAIN}")"

# On-node pod log rotation, applied by script 06 at worker-join time. Read from
# the site file so the kubelet bound and dataPolicy.telemetry agree; the kubelet
# has no time-based retention, so these are size x count rather than a duration.
KUBELET_LOG_MAX_SIZE="$(cfg dataPolicy.telemetry.podLogFiles.maxSize 10Mi)"
KUBELET_LOG_MAX_FILES="$(cfg dataPolicy.telemetry.podLogFiles.maxFiles 5)"
export KUBELET_LOG_MAX_SIZE KUBELET_LOG_MAX_FILES

# Where the heavy state goes. Blank (the default) keeps k0s and the PVCs on the
# root filesystem, which is right for a single-disk host.
#
# Set it to a mounted data volume when the root disk is small — the typical
# Nectar VM is 30G root plus a 500G volume, and the container image store alone
# does not fit in 30G. Both consumers below take a native path setting, so this
# needs no bind mounts and leaves /etc/fstab alone. An earlier deployment did
# use fstab binds for this; deleting /data then left the mounts dangling and the
# node failed its next boot into an emergency shell. See docs/storage.md.
# EMPTY IS THE DEFAULT AND IS VALID — it means "keep k0s and the PVCs on the root
# filesystem", which is right for a single-disk host. `cfg <path>` with no second
# argument means REQUIRED and exits 1, so omitting the default here made an
# optional key mandatory and killed the install on every site that did not set
# it. Caught on the first cloud install.
DATA_ROOT="$(cfg storage.dataRoot "")"
export DATA_ROOT

# ONE k0s VERSION FOR THE WHOLE DEPLOYMENT.
#
# The charts already pin what the hosted control planes are built from
# (k0smotron.k0sVersion), and edge-clusters.yaml calls that "one value, both
# ends". This makes it true of the MANAGEMENT node's own k0s as well, which was
# still installed with a bare `curl get.k0s.sh | sh` — i.e. whatever upstream
# published that day.
#
# The same class of bug that crash-looped an edge worker: nothing in the repo
# chose the version, so two installs a fortnight apart differ while the operator
# is told they are identical. Falls back to the chart default when a site does
# not override it, and to unpinned only if the chart value is somehow absent.
# Empty is valid and falls through to the chart default below. `cfg <path>` with
# no second argument means REQUIRED — the same trap that made storage.dataRoot
# mandatory. I wrote this one.
K0S_VERSION="$(cfg k0smotron.k0sVersion "")"
if [ -z "$K0S_VERSION" ] && [ -f "${SCRIPT_DIR}/charts/mgmt/values.yaml" ]; then
    K0S_VERSION="$(python3 -c "
import yaml,sys
v=yaml.safe_load(open('${SCRIPT_DIR}/charts/mgmt/values.yaml')) or {}
print((v.get('k0smotron') or {}).get('k0sVersion',''))" 2>/dev/null || true)"
fi
export K0S_VERSION
[ -n "$K0S_VERSION" ] && echo "  k0s (this node + hosted control planes): ${K0S_VERSION}"

export MGMT_NODE_IP INTERNAL_DOMAIN INGRESS_PORT INSTALL_TOPOLOGY INSTALL_MODE
export SEAWEEDFS_HOSTNAME GRAFANA_HOSTNAME LOKI_HOSTNAME

# Fail here rather than 200 lines into a step. `set -u` in scripts/05 and 06
# turns a missing value into "SEAWEEDFS_HOSTNAME: unbound variable" partway
# through an edge build, after the control plane is already up — so the run
# half-succeeds and has to be repeated. Checking the whole set up front costs
# nothing and names the missing key.
for _req in MGMT_NODE_IP INTERNAL_DOMAIN INGRESS_PORT INSTALL_TOPOLOGY \
            SEAWEEDFS_HOSTNAME GRAFANA_HOSTNAME LOKI_HOSTNAME; do
    [ -n "${!_req:-}" ] || die "${_req} could not be resolved from sites/${SITE}/values.yaml"
done
unset _req
EDGES="$(edges_json)"
EDGE_COUNT="$(python3 -c "import json;print(len(json.loads('''$EDGES''')))")"

[ "$EDGE_COUNT" -gt 0 ] || info "no edges defined — management plane only"

# --- preflight ---------------------------------------------------------------
echo "============================================"
echo " AIS Edge install"
echo "============================================"
echo "  site            : ${SITE}"
echo "  values          : sites/${SITE}/values.yaml"
echo "  mgmt node       : ${MGMT_NODE_IP}"
echo "  internal domain : ${INTERNAL_DOMAIN}"
echo "  edges           : ${EDGE_COUNT}"
python3 -c "
import json
for e in json.loads('''$EDGES'''):
    print(f\"                    - {e['name']}  {e.get('nodeIP','(no nodeIP)')}\")"
echo
echo "  cert-manager    : ${CERT_MANAGER_VERSION}   (pinned)"
echo "  k0smotron       : ${K0SMOTRON_VERSION}   (pinned)"
echo "============================================"

[ -n "${MISSING:-}" ] && die "missing required tools:${MISSING}"

# Secrets must be encrypted and must not still hold the shipped placeholders.
# The charts never see a credential value, so this is the only place a
# placeholder can be caught before it becomes a live credential.
if [ -f "$SECRETS" ]; then
    grep -q '^sops:' "$SECRETS" || die "sites/${SITE}/secrets.enc.yaml is NOT encrypted. Run: scripts/site-secrets.sh encrypt ${SITE}"
    # The line above already established the file is ENCRYPTED, so every value
    # in it is ciphertext and a `grep REPLACE_` over the file can only ever
    # match the templates' own COMMENTS — which every correctly-filled site
    # still carries, including one that reads "fill in every REPLACE_". So this
    # refused to install a complete, correct site, and no amount of filling
    # placeholders in could satisfy it. Decrypt to a pipe (never to disk) and
    # check the VALUES, which is what the check was always meant to mean.
    if command -v sops >/dev/null 2>&1; then
        UNFILLED="$(sops --config "${SCRIPT_DIR}/.sops.yaml" -d "$SECRETS" 2>/dev/null \
                    | grep -nE '^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*REPLACE_' || true)"
        [ -n "$UNFILLED" ] && die "sites/${SITE}/secrets.enc.yaml still has unfilled placeholder VALUES:
${UNFILLED}
       Fix with: scripts/site-secrets.sh edit ${SITE}"

        # Two more classes the REPLACE_ check cannot see, each of which
        # otherwise costs a full install to discover. See the script's
        # docstring for what they are and how they present.
        SECRET_CHECK="$(sops --config "${SCRIPT_DIR}/.sops.yaml" -d "$SECRETS" 2>/dev/null \
            | python3 "${SCRIPT_DIR}/scripts/check-site-secrets.py" "$VALUES" 2>/dev/null || true)"
        if [ -n "$(printf '%s' "$SECRET_CHECK" | tr -d '[:space:]')" ]; then
            die "sites/${SITE}: the secrets do not match the site file:
${SECRET_CHECK}
       Fix with: scripts/site-secrets.sh edit ${SITE}"
        fi
    fi
else
    info "WARNING: no sites/${SITE}/secrets.enc.yaml — the charts reference Secrets by name and will not start without them"
fi

confirm "Proceed? (y/N)"
[[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# =============================================================================
# 1. Management k0s cluster
# =============================================================================
if step "1/7  k0s management cluster (k0s, kubectl, helm, local-path)"; then
    bash "${SCRIPT_DIR}/scripts/01-install-k0s.sh"
fi

# =============================================================================
# 2. Prerequisites Helm cannot install for itself
# =============================================================================
# cert-manager ships its CRDs as chart TEMPLATES, not in crds/. Helm validates
# every manifest in a release against the API server BEFORE applying any of it,
# so a release that installs the cert-manager subchart AND creates Certificate
# / ClusterIssuer objects can never work in one pass: the CRDs do not exist at
# validation time. kube-prometheus-stack does not have this problem because it
# does ship CRDs in crds/, which Helm applies first — so this is specifically a
# cert-manager property, not a general one.
#
# The k0smotron OPERATOR is not a subchart at all. The chart renders Cluster
# objects; without the operator and its CRDs those are inert.
if step "2/7  prerequisites: cert-manager CRDs + k0smotron operator (pinned)"; then
    # cert-manager is installed IN FULL here, before the management chart, and
    # is deliberately NOT a subchart of it.
    #
    # The dependency is circular otherwise, and the loop is not obvious:
    #   the management chart renders `Cluster` (k0smotron.io/v1beta1) objects
    #   -> the k0smotron CRDs declare a CONVERSION webhook for that version
    #   -> the webhook is served by the k0smotron operator
    #   -> the operator will not start until cert-manager issues its serving
    #      certificate
    #   -> cert-manager would be installed by the management chart.
    #
    # So installing the chart with certManager.enabled=true fails at the point
    # it applies the first Cluster object, with:
    #   conversion webhook for k0smotron.io/v1beta1, Kind=Cluster failed:
    #   dial tcp ...:443: connect: connection refused
    # which reads as a networking problem rather than an ordering one.
    #
    # This is why charts/mgmt defaults certManager.enabled to FALSE. Keep it
    # false in the site file; this step is what satisfies it.
    #
    # Installed from the tarball vendored in charts/mgmt/charts/, so the
    # version is the same one the chart pins and the install needs no network.
    # Adopt any cert-manager CRDs that already exist. Helm refuses to take
    # ownership of an object that lacks its metadata:
    #   CustomResourceDefinition "challenges.acme.cert-manager.io" exists and
    #   cannot be imported into the current release: invalid ownership metadata
    # which happens on any cluster where cert-manager was previously installed
    # with `kubectl apply` — including a re-run of this installer after a
    # partial failure.
    #
    # Stamping the metadata is the documented adoption path and is idempotent.
    # DELETING the CRDs instead would take every Certificate, Issuer and
    # CertificateRequest with them, including the CA that signs the fleet, so
    # it is not an option on anything but a genuinely empty cluster.
    if kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
        info "adopting pre-existing cert-manager CRDs into the Helm release"
        for _crd in $(kubectl get crd -o name 2>/dev/null | grep 'cert-manager\.io$'); do
            kubectl label "$_crd" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null
            kubectl annotate "$_crd" \
                meta.helm.sh/release-name=cert-manager \
                meta.helm.sh/release-namespace=cert-manager --overwrite >/dev/null
        done
    fi

    info "cert-manager ${CERT_MANAGER_VERSION} (prerequisite, not a subchart)"
    helm upgrade --install cert-manager \
        "${SCRIPT_DIR}/charts/mgmt/charts/cert-manager-${CERT_MANAGER_VERSION}.tgz" \
        --namespace cert-manager --create-namespace \
        --set crds.enabled=true \
        --wait --timeout 5m

    info "waiting for cert-manager to be able to issue"
    kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
    kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s

    # control-plane-components.yaml ONLY, not the combined bundle the previous
    # installer pulled from docs.k0smotron.io/stable/install.yaml.
    #
    # That URL is unpinned — a rebuild months later got whatever was published
    # that morning — and it bundles three providers. This deployment uses one:
    # the chart creates `Cluster` (k0smotron.io) objects and scripts/05 creates
    # `JoinTokenRequest`, and both CRDs plus their controller live here.
    #
    # The other two are CAPI machine provisioning — bootstrap-components
    # (K0sWorkerConfig) and infrastructure-components (RemoteMachine) — for
    # letting CAPI build and join workers for you. Workers here are joined over
    # SSH with a token by scripts/06, because an edge is a physical box in a
    # hospital that CAPI cannot provision. Installing them anyway means two more
    # controllers watching CRDs nothing creates, on a node that is already the
    # memory constraint for how many sites a management plane can carry.
    #
    # If a site ever does adopt CAPI-provisioned workers, add the other two
    # files here — they are the same release and the same version.
    info "k0smotron control-plane provider ${K0SMOTRON_VERSION}"
    kubectl apply --server-side --force-conflicts \
        -f "https://github.com/k0sproject/k0smotron/releases/download/${K0SMOTRON_VERSION}/control-plane-components.yaml"

    # DELIBERATELY NOT WAITING HERE. The operator mounts
    # k0smotron-webhook-server-cert-control-plane, which one of its own
    # cert-manager Certificates issues — so it cannot start until the
    # cert-manager CONTROLLER is running, and that arrives with the management
    # chart in step 4. Waiting here waits for something a later step creates.
    #
    # Applying the manifest now is still correct and necessary: step 4 renders
    # `Cluster` objects, and Helm validates every manifest against the API
    # server before applying any of it, so those CRDs must already exist.
    # Only the readiness check moves — to just after step 4, where it is a HARD
    # failure. An unready operator means the Cluster objects are inert: they
    # apply cleanly, nothing reconciles them, and the edge simply never gets a
    # control plane while every command so far reported success.
    # cert-manager is running now, so the operator's serving certificate can be
    # issued and this is a legitimate wait. HARD failure: without the operator
    # the Cluster objects cannot even be ADMITTED (the conversion webhook
    # refuses the connection), and if they somehow were, nothing would
    # reconcile them and no edge would ever get a control plane.
    info "waiting for the k0smotron control-plane operator"
    if ! kubectl -n k0smotron rollout status deploy/k0smotron-controller-manager-control-plane --timeout=300s; then
        kubectl -n k0smotron get pods 2>/dev/null || true
        kubectl -n k0smotron describe pod -l control-plane=controller-manager 2>/dev/null | sed -n '/Events:/,$p' | tail -12 || true
        die "the k0smotron operator did not become ready; the management chart cannot create Cluster objects without its conversion webhook"
    fi
    info "k0smotron operator ready"
fi

# =============================================================================
# CLOUD PRE-FLIGHT: is this cluster actually able to get a load balancer?
# =============================================================================
# Provisioning cloud infrastructure is the OPERATOR'S job, not this installer's.
# It is cloud-specific, it needs credentials this installer should not hold, and
# on managed Kubernetes (EKS/AKS/GKE) it is already done for you. That boundary
# is deliberate — see docs/clouds/README.md.
#
# But "not our job" must not mean "fails silently an hour later". Without a cloud
# controller, a type: LoadBalancer Service sits at <pending> forever: no error,
# no event worth reading, the ingress pod Running and healthy, and every fleet
# hostname resolving to nothing. The first symptom is an edge that will not join,
# at the far end of the link.
#
# So: check, and if it is missing, STOP HERE and say exactly what is needed and
# where it is written down. Cheaper than discovering it after the charts are
# applied and an edge has been half-joined.
#
# The check is deliberately generic. Every cloud's implementation is a different
# binary, but they all name themselves *cloud-controller-manager*, so this works
# on OpenStack, AWS, Azure and GCP without this installer knowing which it is.
if [ "${INSTALL_TOPOLOGY:-onprem}" = "cloud" ] && [ "${SKIP_CLOUD_PREFLIGHT:-0}" != "1" ]; then
    info "cloud pre-flight: checking the operator-provided edge path"

    # What shape did the site ask for? The answer decides what has to be true.
    svc_type="$(python3 - "$VALUES" <<'PY'
import sys, yaml
v = yaml.safe_load(open(sys.argv[1])) or {}
c = ((v.get("ingress-nginx") or {}).get("controller") or {})
print(((c.get("service") or {}).get("type")) or "NodePort")
PY
)"

    # --- NodePort: the default, and the shape this deployment recommends ------
    # The operator builds the load balancer themselves and forwards to a node
    # port. Nothing in the cluster talks to the cloud API, so there is no
    # controller to check for and no credential living in kube-system.
    #
    # What CAN be verified here is that the name the edges will resolve already
    # points somewhere, and that it does not point straight at the management
    # node -- which would mean there is no load balancer in front at all.
    if [ "$svc_type" = "NodePort" ]; then
        resolved="$(getent hosts "$INTERNAL_DOMAIN" 2>/dev/null | awk '{print $1; exit}')"
        if [ -z "$resolved" ]; then
            echo >&2
            echo "[install] ERROR: topology=cloud, but ${INTERNAL_DOMAIN} does not resolve." >&2
            echo >&2
            echo "  Edges resolve this name to find the management cluster. Provisioning" >&2
            echo "  the load balancer and its DNS is the operator's job -- this installer" >&2
            echo "  holds no cloud credentials and will not create infrastructure." >&2
            echo >&2
            echo "  Create the load balancer, point ${INTERNAL_DOMAIN} at its address," >&2
            echo "  then re-run. Step by step:" >&2
            echo "    docs/clouds/README.md            what is yours to provide, and why" >&2
            echo "    docs/clouds/openstack-nectar.md  OpenStack / Nectar" >&2
            echo "    docs/clouds/{aws,azure,gcp}.md   per-cloud equivalents" >&2
            echo >&2
            echo "  To proceed anyway: SKIP_CLOUD_PREFLIGHT=1" >&2
            exit 1
        fi
        if [ "$resolved" = "$MGMT_NODE_IP" ]; then
            echo >&2
            echo "[install] ERROR: ${INTERNAL_DOMAIN} resolves to ${resolved}, which is the" >&2
            echo "          management node itself -- there is no load balancer in front." >&2
            echo >&2
            echo "  That works until the management node is replaced or scaled, at which" >&2
            echo "  point every edge loses the cluster and has to be re-pointed by hand." >&2
            echo "  Point the name at the load balancer's address instead." >&2
            echo >&2
            echo "  If this is deliberate for a single-node trial: SKIP_CLOUD_PREFLIGHT=1" >&2
            exit 1
        fi
        info "cloud pre-flight: ${INTERNAL_DOMAIN} -> ${resolved} (operator-provided)"
        info "cloud pre-flight: your load balancer must forward 443 to this node's ingress NodePort"

    # --- LoadBalancer: supported, but it needs something to answer the request -
    # `type: LoadBalancer` is only a REQUEST. Without a controller watching for
    # it, the Service sits at <pending> for ever: the ingress pod reports 1/1
    # Running, no external address is ever assigned, and the failure surfaces
    # much later as an edge that cannot join.
    else
        ccm="$(kubectl get pods -A -o name 2>/dev/null | grep -c 'cloud-controller-manager' || true)"
        if [ "${ccm:-0}" -eq 0 ]; then
            echo >&2
            echo "[install] ERROR: ingress-nginx service.type=${svc_type}, but nothing in this" >&2
            echo "          cluster can turn that request into a real load balancer." >&2
            echo >&2
            echo "  The Service would sit at <pending> for ever and no edge could join." >&2
            echo >&2
            echo "  Either (recommended here) provision the load balancer yourself and use" >&2
            echo "  a node port, by setting this in your SITE file:" >&2
            echo >&2
            echo "    ingress-nginx:" >&2
            echo "      controller:" >&2
            echo "        service:" >&2
            echo "          type: NodePort" >&2
            echo >&2
            echo "  or install a cloud controller manager for your cloud out of band." >&2
            echo "  See docs/clouds/README.md for the trade-off." >&2
            exit 1
        fi
        info "cloud pre-flight: cloud controller present (${ccm} pod(s))"

        # Only meaningful when a controller is actually running: a node left
        # carrying this taint means the controller has not adopted it, and
        # nothing will schedule there.
        tainted="$(kubectl get nodes -o jsonpath='{range .items[*]}{.spec.taints[?(@.key=="node.cloudprovider.kubernetes.io/uninitialized")].key}{"\n"}{end}' 2>/dev/null | grep -c . || true)"
        if [ "${tainted:-0}" -gt 0 ]; then
            echo >&2
            echo "[install] ERROR: ${tainted} node(s) still carry" >&2
            echo "          node.cloudprovider.kubernetes.io/uninitialized." >&2
            echo >&2
            echo "  The cloud controller is running but has not adopted them, so workloads" >&2
            echo "  will not schedule. Usually its credentials are wrong for this project," >&2
            echo "  or its configured region does not match where these nodes actually are." >&2
            echo "    kubectl -n kube-system logs -l component=cloud-controller-manager --tail=50" >&2
            exit 1
        fi
    fi
fi

# =============================================================================
# 3. Site Secrets
# =============================================================================
# BEFORE the charts, always. A workload that starts without the Secret it
# mounts sits in CreateContainerConfigError, and the charts deliberately do not
# create the namespaces that hold operator-supplied credentials so that this
# ordering is always possible. site-secrets.sh creates any namespace its
# Secrets name.
if [ -f "$SECRETS" ] && step "3/7  site Secrets (SOPS -> cluster, plaintext never on disk)"; then
    if $INTERACTIVE; then
        bash "${SCRIPT_DIR}/scripts/site-secrets.sh" apply "$SITE"
    else
        SITE_SECRETS_ASSUME_YES=1 bash "${SCRIPT_DIR}/scripts/site-secrets.sh" apply "$SITE"
    fi
fi

# =============================================================================
# 4. Management chart
# =============================================================================
if step "4/7  helm: management chart (SeaweedFS, uploader, observability, CA, ingress, control planes)"; then
    helm upgrade --install "$MGMT_RELEASE" "${SCRIPT_DIR}/charts/mgmt" \
        --namespace "$MGMT_NS" --create-namespace \
        -f "$VALUES" \
        --timeout 15m
    info "management chart deployed"
    if [ "$(cfg xnatUpload.tokenRefresh.enabled false)" = "True" ]; then
        refresh_job="xnat-token-refresh-$(date -u +%s)"
        kubectl -n "$(cfg xnatUpload.namespace xnat-upload)" create job "$refresh_job" \
            --from="cronjob/${MGMT_RELEASE}-xnat-token-refresh"
        kubectl -n "$(cfg xnatUpload.namespace xnat-upload)" wait \
            --for=condition=complete "job/$refresh_job" --timeout=300s
    fi

fi

# =============================================================================
# Management-node /etc/hosts: the operator-facing hostnames
# =============================================================================
# Grafana and Loki are published by Ingress under hostnames.grafana /
# hostnames.loki, and ingress-nginx runs with hostNetwork on :80/:443 — so the
# only thing standing between an operator and https://<grafana host>/ is a name
# that resolves. install.sh already derives, exports and validates both names,
# but nothing ever wrote them anywhere: scripts/05 writes only the phase-2 TLS
# names it needs for the child API. The result was a healthy Grafana that no
# browser on the management node could reach, and the ONLY evidence left of the
# writer that used to do this is scripts/uninstall.sh, which still cleans up an
# "# ais-edge observability hostnames" marker nothing creates any more.
#
# REWRITTEN, not skipped-if-present, for the same reason as the edge block: a
# marker-keyed guard makes a stale or truncated entry permanent, and these names
# change whenever hostnames.* does.
if [ "${INSTALL_TOPOLOGY:-onprem}" = "onprem" ]; then
    OBS_MARKER="# ais-edge observability hostnames"
    OBS_LINE="${MGMT_NODE_IP} ${GRAFANA_HOSTNAME} ${LOKI_HOSTNAME}"
    info "management /etc/hosts: ${GRAFANA_HOSTNAME}, ${LOKI_HOSTNAME} -> ${MGMT_NODE_IP}"
    sudo sed -i "\|^${OBS_MARKER}\$|,+1d" /etc/hosts 2>/dev/null || true
    printf '%s\n%s\n' "$OBS_MARKER" "$OBS_LINE" | sudo tee -a /etc/hosts >/dev/null
fi

# =============================================================================
# 5-7. Per edge
# =============================================================================
for i in $(seq 0 $((EDGE_COUNT - 1))); do
    [ "$EDGE_COUNT" -eq 0 ] && break
    eval "$(python3 - "$i" <<PY
import json, shlex, sys
e = json.loads('''$EDGES''')[int(sys.argv[1])]
def emit(k, v): print(f"{k}={shlex.quote(str(v))}")
emit("EDGE_NAME", e["name"])
emit("EDGE_NODE_IP", e.get("nodeIP", ""))
emit("EDGE_SSH_USER", e.get("sshUser", ""))
emit("EDGE_SSH_KEY", e.get("sshKey", ""))
emit("EDGE_API_HOST", e.get("apiHost", ""))
emit("EDGE_KONN_HOST", e.get("konnectivityHost", ""))
# How the worker gets joined. Absent means ssh, so every site file written
# before this existed keeps its behaviour exactly.
emit("EDGE_JOIN", e.get("join", "ssh"))
emit("EDGE_JOIN_TTL", e.get("joinTokenTTL", ""))
emit("EDGE_K0S_DATA_DIR", e.get("workerDataDir", "/var/lib/k0s"))
PY
)"

    echo
    echo "========================================"
    echo " Edge: ${EDGE_NAME}  (${EDGE_NODE_IP:-no nodeIP})"
    echo "========================================"

    EDGE_VALUES="${SCRIPT_DIR}/sites/${EDGE_NAME}/values.yaml"

    # scripts/05 and 06 predate the charts and read their configuration from
    # the environment. Rather than rewrite two scripts that do genuinely
    # non-declarative work correctly, the values are exported here FROM THE
    # SAME SITE FILE — so there is still one source of truth, and no second
    # config file that could disagree about which host `edge-dev` is.
    export EDGE_K0S_DATA_DIR
    export CLUSTER_NAME="$EDGE_NAME"
    export NODE_IP="$EDGE_NODE_IP"
    export SSH_USER="$EDGE_SSH_USER"
    export SSH_KEY="$EDGE_SSH_KEY"
    # THESE FALLBACKS MUST MATCH charts/mgmt/values.yaml k0smotron.hostnames.*
    # exactly. The chart is the authority: it renders the Ingress and the
    # certificate SANs. This script only writes the /etc/hosts entries that let
    # the edge RESOLVE those names. When they disagreed — the chart generating
    # `konnectivity-<edge>` while this generated `konnect-<edge>` — /etc/hosts
    # pointed at a name nothing served, and the worker failed to join with
    # "no such host" against public DNS, which reads as a site DNS fault.
    # scripts/ci/runtime-templates.sh asserts the two stay equal.
    export K0S_API_HOSTNAME="${EDGE_API_HOST:-k0s-${EDGE_NAME}.${INTERNAL_DOMAIN}}"
    export KONNECTIVITY_HOSTNAME="${EDGE_KONN_HOST:-konnectivity-${EDGE_NAME}.${INTERNAL_DOMAIN}}"
    # The Cluster object belongs to charts/mgmt now; 05 must not re-apply it.
    export CLUSTER_CR_MANAGED_BY_HELM=1

    if step "5/7  ${EDGE_NAME}: child kubeconfig + join token"; then
        # JOIN_TOKEN_TTL BELONGS HERE, because step 05 is where the token is
        # actually minted (scripts/05-setup-edge-cluster.sh:128 reads it, :139
        # writes it as the Secret's `expiry`).
        #
        # It used to be passed only to 06b on the bundle arm below, so
        # edges[].joinTokenTTL reached the bundle BUILDER but never the MINTER,
        # and every token was the 2h default no matter what the site asked for.
        # Documented as a working knob in README and TOUR §4.1 — and advised
        # there precisely for the bundle case, where a token has to survive being
        # carried to a hospital by hand. That is the one case it silently failed.
        JOIN_TOKEN_TTL="${EDGE_JOIN_TTL:-${JOIN_TOKEN_TTL:-2h}}" \
            bash "${SCRIPT_DIR}/scripts/05-setup-edge-cluster.sh" "$EDGE_NAME"
    fi

    # HOW THE WORKER IS JOINED.
    #
    #   ssh     (default) this node pushes the join to the edge. Needs an
    #           inbound path from here to the edge on 22.
    #   bundle  no inbound path exists — a hospital behind a whitelisted-IP
    #           allowlist, a VPN, or GlobalProtect. Emit a self-contained script
    #           the operator carries to the edge and runs there, then wait for
    #           the node to appear.
    #
    # Only the BOOTSTRAP differs. Once joined, both are identical: the edge
    # dials out (konnectivity, kubelet -> hosted control plane) and nothing ever
    # connects into the site.
    case "${EDGE_JOIN:-ssh}" in
        ssh|bundle) ;;
        *) die "edges[].join for ${EDGE_NAME} is '${EDGE_JOIN}' — must be 'ssh' or 'bundle'" ;;
    esac

    if [ "${EDGE_JOIN:-ssh}" = "bundle" ]; then
        if step "6/7  ${EDGE_NAME}: bootstrap bundle (no ssh to this edge)"; then
            [ -n "$EDGE_NODE_IP" ] || die "edges[].nodeIP is required for ${EDGE_NAME} (the bundle refuses to run on the wrong machine)"
            JOIN_TOKEN_TTL="${EDGE_JOIN_TTL:-${JOIN_TOKEN_TTL:-2h}}" \
                bash "${SCRIPT_DIR}/scripts/06b-make-bootstrap.sh" "$EDGE_NAME"
            # Wait rather than fail: the operator has to physically get the
            # bundle to the site. Long default, and 06c prints what it is
            # waiting for so an unattended run does not look hung.
            WAIT_MINUTES="${BUNDLE_WAIT_MINUTES:-30}" \
                bash "${SCRIPT_DIR}/scripts/06c-post-join.sh" "$EDGE_NAME"
        fi
    else
        if step "6/7  ${EDGE_NAME}: join the k0s worker over SSH"; then
            [ -n "$EDGE_NODE_IP" ] || die "edges[].nodeIP is required to join ${EDGE_NAME}"
            [ -n "$EDGE_SSH_USER" ] || die "edges[].sshUser is required to join ${EDGE_NAME}
       (or set join: bundle on this edge if there is no ssh path to it)"
            bash "${SCRIPT_DIR}/scripts/06-join-edge-worker.sh" "$EDGE_NAME"
        fi
    fi

    if step "7/7  ${EDGE_NAME}: helm: edge chart (Orthanc, de-id, pipeline, uploader, Vector)"; then
        [ -f "$EDGE_VALUES" ] || die "missing sites/${EDGE_NAME}/values.yaml — the edge's own AET map, de-identification profile and storage paths live there"
        EDGE_KC="${SCRIPT_DIR}/kubeconfig-${EDGE_NAME}"
        [ -f "$EDGE_KC" ] || die "missing ${EDGE_KC} (step 5 produces it)"

        # The edge's OWN Secrets, into the CHILD cluster, before the chart.
        # install.sh applied the management site's Secrets in step 3; these are
        # a different file against a different cluster, and forgetting them
        # leaves every edge pod in CreateContainerConfigError with the chart
        # reporting a successful install.
        EDGE_SECRETS="${SCRIPT_DIR}/sites/${EDGE_NAME}/secrets.enc.yaml"
        if [ -f "$EDGE_SECRETS" ]; then
            info "${EDGE_NAME}: applying edge Secrets to the child cluster"
            KUBECONFIG="$EDGE_KC" SITE_SECRETS_ASSUME_YES=1 \
                bash "${SCRIPT_DIR}/scripts/site-secrets.sh" apply "$EDGE_NAME"
        else
            info "${EDGE_NAME}: no sites/${EDGE_NAME}/secrets.enc.yaml — pods that mount Secrets will not start"
        fi

        # BOTH files. The management one supplies the shared facts — domain,
        # hostnames, node IP, bucket prefix, data policy — which the edge chart
        # derives its endpoints, staging bucket and hostAliases from. The edge
        # one carries only what is local to this site. That is what stops the
        # same fact being written in two places.
        helm --kubeconfig "$EDGE_KC" upgrade --install edge "${SCRIPT_DIR}/charts/edge" \
            --namespace "$(cfg namespace xnat-ingest)" \
            -f "$VALUES" \
            -f "$EDGE_VALUES" \
            --timeout 10m
        info "${EDGE_NAME}: edge chart deployed"

        # Run cert-sync NOW rather than waiting for its schedule.
        #
        # cert-sync is a CronJob (23 */6 * * *) that copies the CA bundle and
        # this edge's Loki push CLIENT CERTIFICATE into the child cluster. On a
        # fresh install that means the edge sits WITHOUT them for up to six
        # hours — and neither is optional: the s3-uploader mounts ca-bundle and
        # Vector mounts the client certificate, so neither pod can start at
        # all. The install would report success and the site would do nothing
        # until the small hours.
        #
        # `create job --from=cronjob` runs exactly the CronJob's own pod spec,
        # so this cannot drift from what the schedule does later.
        CS_JOB="mgmt-cert-sync-${EDGE_NAME}"
        if kubectl -n "$MGMT_NS" get cronjob "$CS_JOB" >/dev/null 2>&1; then
            info "${EDGE_NAME}: seeding ca-bundle + Loki push client cert via cert-sync"
            kubectl -n "$MGMT_NS" delete job "${CS_JOB}-init" --ignore-not-found >/dev/null 2>&1
            kubectl -n "$MGMT_NS" create job "${CS_JOB}-init" --from="cronjob/${CS_JOB}" >/dev/null 2>&1 || true
            kubectl -n "$MGMT_NS" wait --for=condition=complete "job/${CS_JOB}-init" --timeout=180s >/dev/null 2>&1 \
                && info "${EDGE_NAME}: cert-sync completed" \
                || warn_cs=1
            if [ "${warn_cs:-0}" = "1" ]; then
                echo "[install] WARNING: cert-sync did not complete. The edge will lack ca-bundle" >&2
                echo "          and its Loki push client certificate, and its pods will not start. Logs:" >&2
                kubectl -n "$MGMT_NS" logs "job/${CS_JOB}-init" --tail=20 2>&1 | sed 's/^/          /' >&2
                unset warn_cs
            fi
        fi
    fi
done

echo
echo "============================================"
echo " Done"
echo "============================================"
echo "  helm list -A"
echo "  kubectl get pods -A"
for i in $(seq 0 $((EDGE_COUNT - 1))); do
    [ "$EDGE_COUNT" -eq 0 ] && break
    n="$(python3 -c "import json,sys;print(json.loads('''$EDGES''')[$i]['name'])")"
    echo "  kubectl --kubeconfig kubeconfig-${n} get pods -A"
done
echo
echo "  Data retention is OFF on a fresh install (dataPolicy.enabled: false,"
echo "  dryRun: true). Nothing is expired or reclaimed until you turn it on."
echo "  Watch a week of dryRun decisions in the logs before you do."
