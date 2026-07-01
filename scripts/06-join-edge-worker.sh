#!/usr/bin/env bash
# =============================================================================
# Step 06: Install k0s worker on edge VM and join the hosted cluster
#          Usage: ./06-join-edge-worker.sh <edge-entry>
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <edge-entry>"
    exit 1
fi

parse_edge_entry "$1"

EDGE_K0S_DATA_DIR="${EDGE_K0S_DATA_DIR:-/data/k0s}"

echo "=== 06: Installing k0s worker on ${NODE_IP} for ${CLUSTER_NAME} ==="
echo "k0s worker data dir: ${EDGE_K0S_DATA_DIR}"

# Test SSH
ssh ${SSH_KEY_OPT} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${EDGE_SSH}" "hostname" || {
    echo "ERROR: Cannot SSH to ${EDGE_SSH}"; exit 1;
}

# On-prem topology: ensure /etc/hosts on the edge VM resolves the TLS
# hostnames to the management node. Idempotent — the marker comment is what
# we grep for to avoid duplicate entries on re-runs.
#
# Cloud topology: skipped — edges resolve via real public DNS (nip.io for
# dev, a registered domain for prod). The hostAliases block in pod manifests
# is similarly stripped by render_with_topology.
if [ "${INSTALL_TOPOLOGY:-onprem}" = "onprem" ]; then
    HOSTS_LINE="${MGMT_NODE_IP} ${SEAWEEDFS_HOSTNAME} ${K0S_API_HOSTNAME} ${KONNECTIVITY_HOSTNAME}"
    HOSTS_MARKER="# ais-edge phase2 tls hostnames"
    echo "Ensuring /etc/hosts on edge has the TLS hostnames..."
    ssh ${SSH_KEY_OPT} "${EDGE_SSH}" \
        "grep -qF '${HOSTS_MARKER}' /etc/hosts || \
         echo -e '${HOSTS_MARKER}\n${HOSTS_LINE}' | sudo tee -a /etc/hosts >/dev/null"
    ssh ${SSH_KEY_OPT} "${EDGE_SSH}" "grep -A1 '${HOSTS_MARKER}' /etc/hosts | tail -2"
else
    echo "Cloud topology — skipping /etc/hosts edit. Edge resolves SNI hostnames"
    echo "  (${SEAWEEDFS_HOSTNAME} / ${K0S_API_HOSTNAME} / ${KONNECTIVITY_HOSTNAME})"
    echo "  via real public DNS pointing at LB_PUBLIC_IP=${LB_PUBLIC_IP:-<unset>}."
fi

# Phase 2: pre-stage certs for the k0smotron-haproxy DaemonSet that runs on
# the worker. With spec.ingress, k0smotron pushes a haproxy DS (hostNetwork)
# that exposes 127.0.0.1:7443 as a local TLS endpoint forwarding to the
# nginx-ingress on the management node. It expects:
#   /etc/haproxy/certs/server.pem  — frontend cert+key the haproxy serves
#       to in-cluster clients (kube-router, etc). It MUST be signed by the
#       cluster's internal k0s CA so workload pods trust it via their
#       projected serviceaccount ca.crt — without this, every pod that
#       calls the kubernetes Service hits "x509: certificate signed by
#       unknown authority".
#   /etc/haproxy/certs/ca.crt      — CA cert haproxy uses to verify the
#       upstream k0s API (the same internal k0s CA).
HAPROXY_CA=$(mktemp /tmp/k0s-ca-XXXXXX.crt)
HAPROXY_CAKEY=$(mktemp /tmp/k0s-cakey-XXXXXX.key)
HAPROXY_KEY=$(mktemp /tmp/haproxy-srv-XXXXXX.key)
HAPROXY_CSR=$(mktemp /tmp/haproxy-srv-XXXXXX.csr)
HAPROXY_CRT=$(mktemp /tmp/haproxy-srv-XXXXXX.crt)
HAPROXY_PEM=$(mktemp /tmp/haproxy-srv-XXXXXX.pem)
HAPROXY_CONF=$(mktemp /tmp/haproxy-srv-XXXXXX.cnf)
cleanup_haproxy_tmp() {
    rm -f "$HAPROXY_CA" "$HAPROXY_CAKEY" "$HAPROXY_KEY" "$HAPROXY_CSR" \
          "$HAPROXY_CRT" "$HAPROXY_PEM" "$HAPROXY_CONF"
}
trap cleanup_haproxy_tmp EXIT

# Extract the k0s internal CA cert + key from the management cluster.
# Secret name is "<clusterName>-ca" in the cluster's namespace, with keys
# tls.crt / tls.key. (k0smotron generates this CA per Cluster CR.)
kubectl get secret -n "${CLUSTER_NAME}" "${CLUSTER_NAME}-ca" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > "$HAPROXY_CA"
kubectl get secret -n "${CLUSTER_NAME}" "${CLUSTER_NAME}-ca" \
    -o jsonpath='{.data.tls\.key}' | base64 -d > "$HAPROXY_CAKEY"

# Generate a server cert signed by the cluster CA. SANs cover everything
# that might TLS-dial the local haproxy from inside the child cluster.
cat > "$HAPROXY_CONF" <<EOF
[req]
distinguished_name=req
req_extensions=v3_req
[v3_req]
subjectAltName=@alt
[alt]
DNS.1=localhost
DNS.2=kubernetes
DNS.3=kubernetes.default
DNS.4=kubernetes.default.svc
DNS.5=kubernetes.default.svc.cluster.local
IP.1=127.0.0.1
IP.2=10.96.0.1
IP.3=${NODE_IP}
EOF
openssl genrsa -out "$HAPROXY_KEY" 2048 2>/dev/null
openssl req -new -key "$HAPROXY_KEY" -subj "/CN=k0smotron-haproxy" \
    -out "$HAPROXY_CSR" -config "$HAPROXY_CONF" 2>/dev/null
openssl x509 -req -in "$HAPROXY_CSR" -CA "$HAPROXY_CA" -CAkey "$HAPROXY_CAKEY" \
    -CAcreateserial -out "$HAPROXY_CRT" -days 3650 \
    -extensions v3_req -extfile "$HAPROXY_CONF" 2>/dev/null
cat "$HAPROXY_CRT" "$HAPROXY_KEY" > "$HAPROXY_PEM"

# Push to edge (hostPath /etc/haproxy/certs/, root:root, 0644 — haproxy
# container runs as non-root and must read these).
echo "Staging k0smotron-haproxy certs on edge (signed by cluster CA)..."
ssh ${SSH_KEY_OPT} "${EDGE_SSH}" "sudo mkdir -p /etc/haproxy/certs && sudo chmod 0755 /etc/haproxy/certs"
scp -q ${SSH_KEY_OPT} "$HAPROXY_CA"  "${EDGE_SSH}:/tmp/k0s-ca.crt"
scp -q ${SSH_KEY_OPT} "$HAPROXY_PEM" "${EDGE_SSH}:/tmp/haproxy-server.pem"
ssh ${SSH_KEY_OPT} "${EDGE_SSH}" \
    "sudo install -m 0644 /tmp/k0s-ca.crt /etc/haproxy/certs/ca.crt && \
     sudo install -m 0644 /tmp/haproxy-server.pem /etc/haproxy/certs/server.pem && \
     sudo rm -f /tmp/k0s-ca.crt /tmp/haproxy-server.pem"

# Copy join token
scp ${SSH_KEY_OPT} "${REPO_DIR}/join-token-${CLUSTER_NAME}" "${EDGE_SSH}:/tmp/join-token"

# Install and start worker
ssh ${SSH_KEY_OPT} "${EDGE_SSH}" "EDGE_K0S_DATA_DIR='${EDGE_K0S_DATA_DIR}' bash -s" <<'WORKER_SCRIPT'
set -euo pipefail
command -v k0s &>/dev/null || { curl -sSLf https://get.k0s.sh | sudo sh; }
echo "k0s: $(k0s version)"
if ! sudo systemctl is-active k0sworker &>/dev/null; then
    sudo mkdir -p /etc/k0s "$EDGE_K0S_DATA_DIR"
    sudo cp /tmp/join-token /etc/k0s/join-token
    sudo chmod 600 /etc/k0s/join-token
    rm -f /tmp/join-token
    K0S_INSTALL_FORCE_ARGS=()
    if sudo systemctl cat k0sworker >/dev/null 2>&1; then
        K0S_INSTALL_FORCE_ARGS=(--force)
    fi
    sudo k0s install worker "${K0S_INSTALL_FORCE_ARGS[@]}" \
        --data-dir "$EDGE_K0S_DATA_DIR" \
        --kubelet-root-dir "$EDGE_K0S_DATA_DIR/kubelet" \
        --token-file /etc/k0s/join-token
    sudo systemctl reset-failed k0sworker 2>/dev/null || true
    sudo k0s start
fi
RETRIES=18
for i in $(seq 1 $RETRIES); do
    sudo systemctl is-active k0sworker &>/dev/null && pgrep -f kubelet &>/dev/null && {
        echo "Worker running (kubelet active)"; break; }
    [ $i -eq $RETRIES ] && echo "WARNING: kubelet not yet detected — may still be downloading"
    echo "  Waiting... ($i/$RETRIES)"; sleep 10
done
WORKER_SCRIPT

# Verify node joined
echo "Verifying node joined..."
RETRIES=18
for i in $(seq 1 $RETRIES); do
    NODES=$(KUBECONFIG="$EDGE_KC" kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || true)
    [ "$NODES" -ge 1 ] && { echo "Node joined and Ready!"; break; }
    [ $i -eq $RETRIES ] && { echo "ERROR: Node not Ready"; exit 1; }
    echo "  Waiting... ($i/$RETRIES)"
    sleep 10
done
KUBECONFIG="$EDGE_KC" kubectl get nodes -o wide

# (xnat-ingest image is now pulled from ghcr.io by kubelet directly;
# no ctr-import dance — see config/management.env: XNAT_INGEST_IMAGE.)

# On-prem topology: patch CoreDNS in the child cluster so the
# konnectivity-agent (and any other in-pod client) can resolve the
# management TLS hostnames. Without this, konnectivity-agent fails:
# "lookup konnect.aisedge.local on 10.96.0.10:53: no such host" — because
# pods use cluster CoreDNS, which doesn't consult the host's /etc/hosts.
#
# Cloud topology: skipped — every hostname resolves via real public DNS
# (CoreDNS's default `forward . /etc/resolv.conf` block handles it through
# the worker's normal resolver).
if [ "${INSTALL_TOPOLOGY:-onprem}" = "onprem" ]; then
    COREDNS_TMP=$(mktemp /tmp/coredns-corefile-XXXXXX)
    trap "rm -f $COREDNS_TMP" EXIT
    cat > "$COREDNS_TMP" <<EOF
.:53 {
    errors
    health
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
      pods insecure
      ttl 30
      fallthrough in-addr.arpa ip6.arpa
    }
    hosts {
        ${MGMT_NODE_IP} ${SEAWEEDFS_HOSTNAME} ${K0S_API_HOSTNAME} ${KONNECTIVITY_HOSTNAME}
        fallthrough
    }
    prometheus :9153
    forward . /etc/resolv.conf
    cache 30
    loop
    reload
    loadbalance
}
EOF
    echo "Patching child cluster CoreDNS Corefile with mgmt-side hostnames..."
    KUBECONFIG="$EDGE_KC" kubectl create configmap coredns \
        --from-file=Corefile="$COREDNS_TMP" \
        --namespace kube-system \
        --dry-run=client -o yaml \
        | KUBECONFIG="$EDGE_KC" kubectl apply -f -
else
    echo "Cloud topology — leaving child cluster CoreDNS at chart defaults."
    echo "  In-pod resolution of ${SEAWEEDFS_HOSTNAME} etc. uses the standard"
    echo "  upstream chain (CoreDNS forward → kubelet's /etc/resolv.conf → public DNS)."
fi

# Bounce coredns + konnectivity-agent so the new resolution path takes
# effect immediately (CoreDNS reload plugin should handle it, but
# restarting is more deterministic for installer logs).
KUBECONFIG="$EDGE_KC" kubectl rollout restart deployment/coredns -n kube-system 2>/dev/null || true
KUBECONFIG="$EDGE_KC" kubectl rollout restart daemonset/konnectivity-agent -n kube-system 2>/dev/null || true

echo "=== 06: Complete for ${CLUSTER_NAME} ==="
