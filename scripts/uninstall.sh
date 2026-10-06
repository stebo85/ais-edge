#!/usr/bin/env bash
# =============================================================================
# Uninstall — return both nodes to a clean slate
# =============================================================================
#   scripts/uninstall.sh <site>                  interactive
#   scripts/uninstall.sh -y <site>               no prompt
#   scripts/uninstall.sh --keep-cluster <site>   remove workloads, keep k0s
#
# Reads sites/<site>/values.yaml — the same single source of truth install.sh
# uses — so it removes what THIS site actually installed rather than a
# hardcoded list that drifts.
#
# WHAT "CLEAN SLATE" MEANS HERE
#
# By default this is a FULL reset: after it runs, both machines look like they
# did before the first install. That includes `k0s reset` on the management
# node and every edge, and deleting /data on both. It exists because a partial
# teardown is worse than none — the failure modes this repo keeps producing are
# leftovers: CRDs without their operator, a namespace Helm cannot adopt because
# it lacks ownership metadata, cert-manager RBAC in kube-system from a release
# that no longer exists, a stale /etc/hosts pointing at an ingress that is gone.
# Each of those makes the NEXT install fail in a way that looks like a bug in
# the charts.
#
# --keep-cluster stops before touching k0s: it removes the releases, the
# namespaces, the CRDs and the data, but leaves both clusters running. Use it
# when you want to reinstall the charts onto the same Kubernetes.
#
# WHAT IS DELIBERATELY NOT REMOVED
#   * ~/.config/sops/age/keys.txt  — the ONLY key that can decrypt every
#     sites/*/secrets.enc.yaml. Deleting it makes those files permanently
#     unreadable, and it is not something a reinstall can regenerate.
#   * sites/<site>/secrets.enc.yaml and values.yaml — your configuration.
#   * The k0s BINARY. install.sh reuses it; removing it only forces a download.
#
# THIS DELETES PATIENT DATA. /data holds the facility backup — the archive of
# record — as well as Orthanc's storage and the S3 staging bucket. On anything
# that is not a scratch machine, copy /data somewhere else first.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ASSUME_YES=false
KEEP_CLUSTER=false
SITE=""
for arg in "$@"; do
    case "$arg" in
        -y|--yes)        ASSUME_YES=true ;;
        --keep-cluster)  KEEP_CLUSTER=true ;;
        -*)              echo "unknown flag: $arg" >&2; exit 1 ;;
        *)               SITE="$arg" ;;
    esac
done

info() { echo "[uninstall] $*"; }
warn() { echo "[uninstall] WARNING: $*" >&2; }

[ -n "$SITE" ] || { echo "usage: $0 [-y] [--keep-cluster] <site>" >&2; exit 1; }
VALUES="${SCRIPT_DIR}/sites/${SITE}/values.yaml"
[ -f "$VALUES" ] || { echo "ERROR: no ${VALUES}" >&2; exit 1; }

# --- read the site file ------------------------------------------------------
# Defaults everywhere: a missing value must not stop a teardown. Uninstall has
# to work on a HALF-BROKEN install, which is exactly when values are missing.
cfg() {
    python3 - "$VALUES" "$1" "${2:-}" <<'PY' 2>/dev/null || true
import sys, yaml
f, dotted, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    cur = yaml.safe_load(open(f)) or {}
except Exception:
    print(default); raise SystemExit
for p in dotted.split('.'):
    cur = cur.get(p) if isinstance(cur, dict) else None
    if cur is None: break
print(cur if cur not in (None, '') else default)
PY
}

EDGES_JSON="$(python3 -c "
import yaml, json
try: print(json.dumps((yaml.safe_load(open('$VALUES')) or {}).get('edges') or []))
except Exception: print('[]')" 2>/dev/null || echo '[]')"
EDGE_COUNT="$(python3 -c "import json;print(len(json.loads('''$EDGES_JSON''')))" 2>/dev/null || echo 0)"
MGMT_NS="$(cfg namespace ais-mgmt)"; MGMT_NS="ais-mgmt"
EDGE_NS="$(cfg namespace xnat-ingest)"
INTERNAL_DOMAIN="$(cfg domain.internal)"
# Must match what install.sh gave `k0s install controller --data-dir`. `k0s
# reset` takes the same flag and defaults it to /var/lib/k0s independently of
# how the node was installed — so on a relocated install a bare `k0s reset`
# cleans a directory that was never used and leaves the real state behind.
DATA_ROOT="$(cfg storage.dataRoot)"
TOPOLOGY="$(cfg topology onprem)"

# --- confirm -----------------------------------------------------------------
echo "============================================"
echo " UNINSTALL — $([ "$KEEP_CLUSTER" = true ] && echo 'workloads only' || echo 'FULL RESET')"
echo "============================================"
echo "  site  : ${SITE}"
echo "  edges : ${EDGE_COUNT}"
python3 -c "
import json
for e in json.loads('''$EDGES_JSON'''):
    print(f\"            - {e['name']}  {e.get('nodeIP','(no nodeIP)')}\")" 2>/dev/null
echo
echo "  This removes:"
echo "    - the mgmt and cert-manager Helm releases, and every edge release"
echo "    - namespaces: ${MGMT_NS}, xnat-upload, cert-manager, k0smotron, each edge's"
echo "    - cert-manager / k0smotron / prometheus-operator CRDs and webhooks"
echo "    - all PersistentVolumes and their host directories"
echo "    - /data on the management node AND on every edge"
echo "      (facility backup, Orthanc storage, S3 staging — PATIENT DATA)"
[ "$KEEP_CLUSTER" = false ] && \
echo "    - k0s itself, on the management node and every edge (k0s reset)"
echo
echo "  It KEEPS: your age key, sites/*/secrets.enc.yaml, values.yaml, the k0s binary."
echo "============================================"
if [ "$ASSUME_YES" != true ]; then
    read -rp "Type the site name to confirm: " -r reply
    [ "$reply" = "$SITE" ] || { echo "Aborted."; exit 0; }
fi

# =============================================================================
# 1. Edges
# =============================================================================
for i in $(seq 0 $((EDGE_COUNT - 1))); do
    [ "$EDGE_COUNT" -eq 0 ] && break
    eval "$(python3 - "$i" <<PY
import json, shlex, sys
e = json.loads('''$EDGES_JSON''')[int(sys.argv[1])]
for k, v in (("EDGE_NAME", e.get("name","")), ("EDGE_NODE_IP", e.get("nodeIP","")),
             ("EDGE_JOIN", e.get("join","ssh")),
             ("EDGE_SSH_USER", e.get("sshUser","")), ("EDGE_SSH_KEY", e.get("sshKey",""))):
    print(f"{k}={shlex.quote(str(v))}")
PY
)"
    echo
    echo "--- edge: ${EDGE_NAME} ---"
    EDGE_KC="${SCRIPT_DIR}/kubeconfig-${EDGE_NAME}"

    # The edge release lives in the CHILD cluster, so it can only be removed
    # while that cluster is still reachable — i.e. before the k0s reset below
    # and before the management cluster's k0smotron control plane goes away.
    if [ -f "$EDGE_KC" ]; then
        helm --kubeconfig "$EDGE_KC" uninstall edge -n "$EDGE_NS" --wait --timeout 3m >/dev/null 2>&1 \
            && info "${EDGE_NAME}: edge release removed" \
            || warn "${EDGE_NAME}: edge release not removed (child cluster may already be gone)"
        kubectl --kubeconfig "$EDGE_KC" delete ns "$EDGE_NS" logging --ignore-not-found --wait=false >/dev/null 2>&1 || true
        kubectl --kubeconfig "$EDGE_KC" delete pv --all --ignore-not-found --wait=false >/dev/null 2>&1 || true
    fi

    # A join: bundle site has no inbound path from here, so the remote half of
    # the teardown cannot run. SAY SO LOUDLY. The old condition simply required
    # sshUser to be non-empty, which a bundle site legitimately leaves out — so
    # this skipped in silence, and "full reset" would have reported success with
    # k0s still running and /data (the facility backup — PATIENT DATA) intact on
    # the edge. A teardown that quietly does half the job is exactly the failure
    # this script's own header warns about.
    if [ "$KEEP_CLUSTER" = false ] && { [ "${EDGE_JOIN:-ssh}" = "bundle" ] || [ -z "$EDGE_SSH_USER" ]; }; then
        warn "${EDGE_NAME}: no SSH path from here (join: ${EDGE_JOIN:-ssh}) — the EDGE HALF IS NOT DONE."
        cat >&2 <<MANUAL
    Run these ON ${EDGE_NAME} (${EDGE_NODE_IP:-its console}) to finish:

        sudo k0s stop
        sudo k0s reset
        sudo rm -rf /var/lib/k0s /etc/k0s /data /etc/haproxy/certs /var/lib/vector
        sudo sed -i '/aisedge\.local/d' /etc/hosts
        sudo reboot        # clears CNI interfaces and iptables state

    /data is the facility backup — the archive of record. Copy it somewhere
    else first if this is not a scratch machine.

MANUAL
    elif [ "$KEEP_CLUSTER" = false ] && [ -n "$EDGE_NODE_IP" ] && [ -n "$EDGE_SSH_USER" ]; then
        SSH_KEY="${EDGE_SSH_KEY/#\~/$HOME}"
        KEY_OPT=""; [ -n "$SSH_KEY" ] && KEY_OPT="-i $SSH_KEY"
        info "${EDGE_NAME}: k0s reset + wipe over SSH"
        # shellcheck disable=SC2029
        ssh -o BatchMode=yes -o ConnectTimeout=10 $KEY_OPT "${EDGE_SSH_USER}@${EDGE_NODE_IP}" '
            sudo k0s stop 2>/dev/null || true
            sudo k0s reset 2>/dev/null || true
            # /etc/k0s holds the join token, which is single-use and now stale.
            sudo rm -rf /var/lib/k0s /etc/k0s /data /etc/haproxy/certs /var/lib/vector
            # The hostAliases block scripts/06 wrote. Left behind it points at
            # an ingress that no longer exists, and the next install appends a
            # second block rather than correcting it.
            sudo sed -i "/aisedge\.local/d" /etc/hosts 2>/dev/null || true
            echo "  reset done; a reboot is recommended to clear CNI state"
        ' 2>&1 | sed 's/^/    /' || warn "${EDGE_NAME}: SSH teardown failed — reset it by hand"
    fi
done

# =============================================================================
# 2. Management workloads
# =============================================================================
echo
echo "--- management cluster ---"
if kubectl version >/dev/null 2>&1; then
    # ---------------------------------------------------------------------
    # CLOUD ONLY: release the load balancer FIRST, and wait for it.
    # ---------------------------------------------------------------------
    # The cloud controller runs inside this cluster. Tear the cluster down with
    # the Service still present and nothing is left to call the cloud API, so
    # the balancer survives — holding its floating IP and consuming quota — and
    # the next install asks for an address that is already spoken for.
    #
    # Octavia will not delete a balancer while a listener or pool is attached,
    # so the manual recovery below has to go in order. Deleting the Service and
    # letting the controller do it is the path that gets that right for free.
    if [ "$TOPOLOGY" = "cloud" ]; then
        lb_svc="$(kubectl get svc -n "$MGMT_NS" -l app.kubernetes.io/name=ingress-nginx \
                  -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].metadata.name}' 2>/dev/null || true)"
        if [ -n "$lb_svc" ]; then
            lb_addr="$(kubectl get svc -n "$MGMT_NS" "$lb_svc" \
                       -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
            info "releasing cloud load balancer ${lb_svc}${lb_addr:+ (${lb_addr})}"
            kubectl delete svc -n "$MGMT_NS" "$lb_svc" --wait=false >/dev/null 2>&1 || true
            # Wait for the controller to actually finish with the cloud, not just
            # for the object to disappear from the API.
            for _ in $(seq 1 60); do
                kubectl get svc -n "$MGMT_NS" "$lb_svc" >/dev/null 2>&1 || break
                sleep 5
            done
            if kubectl get svc -n "$MGMT_NS" "$lb_svc" >/dev/null 2>&1; then
                warn "load balancer ${lb_svc} did not release within 5 minutes"
                echo "         The cloud object may outlive this cluster and keep its address."
                echo "         On OpenStack, delete it IN THIS ORDER once the cluster is gone —"
                echo "         Octavia refuses while a listener or pool is still attached:"
                echo "           openstack loadbalancer pool list     --loadbalancer <lb>"
                echo "           openstack loadbalancer pool delete   <pool>"
                echo "           openstack loadbalancer listener list --loadbalancer <lb>"
                echo "           openstack loadbalancer listener delete <listener>"
                echo "           openstack loadbalancer delete <lb>"
                echo "         Then release the floating IP if it was allocated for this install:"
                echo "           openstack floating ip delete ${lb_addr:-<address>}"
            else
                info "load balancer released"
            fi
        fi
    fi

    # Current layout.
    helm uninstall mgmt -n "$MGMT_NS" --wait --timeout 5m >/dev/null 2>&1 && info "mgmt release removed" || true
    helm uninstall cert-manager -n cert-manager --wait --timeout 3m >/dev/null 2>&1 && info "cert-manager release removed" || true
    # Legacy layout, from before the charts. Harmless if absent, and leaving
    # them behind is what makes a "clean" reinstall inherit somebody else's
    # observability stack.
    for spec in "vector-mgmt|observability" "loki|observability" \
                "kube-prometheus-stack|observability" "ingress-nginx|ingress-nginx"; do
        helm uninstall "${spec%%|*}" -n "${spec##*|}" >/dev/null 2>&1 || true
    done

    info "namespaces"
    NS_LIST="$MGMT_NS xnat-upload cert-manager k0smotron observability seaweedfs ingress-nginx"
    for i in $(seq 0 $((EDGE_COUNT - 1))); do
        [ "$EDGE_COUNT" -eq 0 ] && break
        NS_LIST="$NS_LIST $(python3 -c "import json;print(json.loads('''$EDGES_JSON''')[$i]['name'])" 2>/dev/null)"
    done
    # shellcheck disable=SC2086
    kubectl delete ns $NS_LIST --ignore-not-found --wait=false >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do
        # shellcheck disable=SC2086
        [ "$(kubectl get ns $NS_LIST --no-headers 2>/dev/null | wc -l)" = "0" ] && break
        sleep 5
    done

    # CRDs. These are cluster-scoped, so a namespace delete does not touch
    # them, and a CRD whose operator is gone is the specific leftover that
    # makes the next `helm install` fail with "no matches for kind" or hang on
    # a conversion webhook that nothing serves.
    info "CRDs, webhooks and cluster RBAC"
    CRDS="$(kubectl get crd -o name 2>/dev/null | grep -E 'cert-manager|k0smotron|cluster\.x-k8s|monitoring\.coreos' || true)"
    # shellcheck disable=SC2086
    [ -n "$CRDS" ] && kubectl delete $CRDS --ignore-not-found --timeout=3m >/dev/null 2>&1 || true

    for w in $(kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration -o name 2>/dev/null \
               | grep -E 'cert-manager|k0smotron|ingress-nginx|prometheus' || true); do
        kubectl delete "$w" --ignore-not-found >/dev/null 2>&1 || true
    done

    # Cluster-scoped RBAC, and the Roles these components put in kube-system.
    # Helm refuses to adopt an object it does not own, so a leftover
    # cert-manager Role in kube-system aborts the NEXT install with
    # "invalid ownership metadata" — observed on this cluster.
    for o in $(kubectl get clusterrole,clusterrolebinding -o name 2>/dev/null \
               | grep -E 'cert-manager|k0smotron|capi|prometheus|grafana|loki|vector|ingress-nginx|seaweedfs|mgmt-' || true); do
        kubectl delete "$o" --ignore-not-found >/dev/null 2>&1 || true
    done
    for o in $(kubectl -n kube-system get role,rolebinding -o name 2>/dev/null \
               | grep -E 'cert-manager|ingress-nginx' || true); do
        kubectl -n kube-system delete "$o" --ignore-not-found >/dev/null 2>&1 || true
    done

    info "PersistentVolumes"
    for pv in $(kubectl get pv -o name 2>/dev/null || true); do
        kubectl delete "$pv" --ignore-not-found --wait=false >/dev/null 2>&1 || true
        # A PV whose provisioner is already gone keeps its finalizer forever
        # and the namespace above then never finishes terminating.
        kubectl patch "$pv" -p '{"metadata":{"finalizers":null}}' --type=merge >/dev/null 2>&1 || true
    done
else
    warn "no reachable cluster — skipping in-cluster teardown"
fi

# =============================================================================
# 3. Management host
# =============================================================================
echo
echo "--- management host ---"
info "host directories"
# /opt/local-path-provisioner is where PVC data actually lives. The PV objects
# above are just pointers; without this a reinstall silently reuses old state —
# an old grafana.db with stale datasource UIDs, a half-written Loki index.
sudo rm -rf /data /var/lib/local-path-provisioner /opt/local-path-provisioner 2>/dev/null || true
# BOTH the entries AND the marker comments that guard them. scripts/05 and
# 02d are idempotent via `grep -qF "<marker>" /etc/hosts`, so a teardown that
# deletes the hostname LINE but leaves the marker makes the next install decide
# the entry is already there and skip it. The management node then cannot
# resolve its own child-cluster API, and the failure appears three steps later
# as the worker join timing out — nowhere near the cause. Hit exactly this.
for _m in '# ais-edge phase2 tls hostnames' '# ais-edge observability hostnames'; do
    sudo sed -i "\|${_m}|d" /etc/hosts 2>/dev/null || true
done
sudo sed -i '/aisedge\.local/d' /etc/hosts 2>/dev/null || true
[ -n "$INTERNAL_DOMAIN" ] && sudo sed -i "/${INTERNAL_DOMAIN//./\\.}/d" /etc/hosts 2>/dev/null || true
unset _m

info "generated artefacts"
# Regenerated by install.sh. The join token is single-use, so keeping it is
# actively misleading: it looks valid and cannot work.
rm -f "${SCRIPT_DIR}"/kubeconfig-* "${SCRIPT_DIR}"/join-token-* "${SCRIPT_DIR}"/ais-edge-ca.crt 2>/dev/null || true

if [ "$KEEP_CLUSTER" = false ]; then
    info "k0s reset on this node${DATA_ROOT:+ (data-dir ${DATA_ROOT}/k0s)}"
    sudo k0s stop 2>/dev/null || true
    # shellcheck disable=SC2086
    sudo k0s reset ${DATA_ROOT:+--data-dir "${DATA_ROOT}/k0s"} 2>/dev/null || true
    # Both layouts: /var/lib/k0s is the default location, ${DATA_ROOT}/k0s the
    # relocated one. The /data wipe above already covers the latter, but a site
    # whose dataRoot changed between install and uninstall would otherwise leave
    # the older of the two behind.
    sudo rm -rf /var/lib/k0s /etc/k0s /run/k0s ${DATA_ROOT:+"${DATA_ROOT}/k0s"} 2>/dev/null || true
    rm -f "$HOME/.kube/config" 2>/dev/null || true
fi

# =============================================================================
# 4. Report what is actually left
# =============================================================================
echo
echo "============================================"
echo " Remaining state"
echo "============================================"
for p in /var/lib/k0s /etc/k0s /data /var/lib/local-path-provisioner /opt/local-path-provisioner; do
    printf '  %-34s %s\n' "$p" "$(sudo test -e "$p" && echo 'STILL PRESENT' || echo 'gone')"
done
printf '  %-34s %s\n' "$HOME/.kube/config" "$([ -f "$HOME/.kube/config" ] && echo 'STILL PRESENT' || echo 'gone')"
# grep -c PRINTS 0 and ALSO exits 1 when it matches nothing, so `|| echo 0`
# fires on top of the 0 grep already wrote — the report showed two zeros on
# separate lines. Take grep's own count; only substitute if the file is absent.
hosts_marker_count=$(grep -c 'aisedge' /etc/hosts 2>/dev/null) || true
printf '  %-34s %s\n' "/etc/hosts aisedge entries" "${hosts_marker_count:-0}"
printf '  %-34s %s\n' "kubeconfig-* / join-token-*" "$(ls "${SCRIPT_DIR}"/kubeconfig-* "${SCRIPT_DIR}"/join-token-* 2>/dev/null | wc -l)"
echo
echo "  KEPT (deliberately):"
printf '    %-32s %s\n' "age key" "$([ -f "$HOME/.config/sops/age/keys.txt" ] && echo present || echo 'MISSING — encrypted secrets are unreadable')"
printf '    %-32s %s\n' "sites/${SITE}/" "$(ls "${SCRIPT_DIR}/sites/${SITE}" 2>/dev/null | tr '\n' ' ')"
echo
if [ "$KEEP_CLUSTER" = false ]; then
    echo "  A reboot of this node and every edge is recommended: k0s reset does"
    echo "  not remove CNI interfaces or iptables rules already in the kernel."
    echo
    echo "  Reinstall with:  ./install.sh ${SITE}"
else
    echo "  Clusters left running. Reinstall the charts with: ./install.sh ${SITE}"
fi
