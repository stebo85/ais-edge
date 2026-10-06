#!/usr/bin/env bash
# =============================================================================
# reset-edge-local.sh — undo an edge join, on the edge itself
# =============================================================================
#   sudo bash reset-edge-local.sh        DRY RUN. Lists exactly what would be
#                                        removed and changes NOTHING.
#   sudo bash reset-edge-local.sh -y     Actually do it.
#
# DRY RUN IS THE DEFAULT because this runs on a production clinical box. Read
# the WOULD: lines, satisfy yourself, then re-run with -y. There is no prompt:
# a prompt trains you to answer y, a separate invocation does not.
#
# Removes EXACTLY what scripts/files/edge-join.sh creates, and nothing else:
#
#   edge-join.sh 163-166   /etc/haproxy/certs/{ca.crt,server.pem}
#   edge-join.sh 175-176   /etc/k0s/join-token
#   edge-join.sh 191       k0sworker unit + /var/lib/k0s + /run/k0s
#   edge-join.sh 86-94     the marked /etc/hosts block
#
# plus /var/lib/cni, which kube-router writes at runtime once the worker is up.
#
# FOUR THINGS THAT WOULD OTHERWISE GO WRONG QUIETLY
#   1. MOUNTS UNDER THE DATA DIR. kubelet bind-mounts pod volumes under
#      /var/lib/k0s/kubelet/pods/*; containerd leaves overlay and shm mounts.
#      `rm -rf` across a live bind mount deletes THROUGH it into the source
#      filesystem. Everything is unmounted deepest-first, and the script
#      REFUSES to delete while any mount remains.
#   2. PROCESSES STILL HOLDING FILES. `k0s stop` returns before containerd has
#      exited. We wait, and abort rather than delete underneath it.
#   3. SILENT rm FAILURES. Every removal is re-checked; anything still present
#      is reported and makes the script exit non-zero.
#   4. /etc/hosts. Backed up first, and the line under the marker is matched
#      before deletion so a hand-edited file cannot lose someone else's entry.
#
# NOT REMOVED, DELIBERATELY
#   /usr/local/bin/k0s   a rejoin reuses it; removing it only forces a download
#   microk8s             predates this deployment, not ours to remove
#   /data*               imaging data is untouched; /data/k0s is runtime only
#   Docker / CTP         k0s runs its own containerd on /run/k0s/containerd.sock
#   iptables             never flushed; `k0s reset` removes only k0s's own rules
#
# No reboot, in either mode.
# =============================================================================
set -uo pipefail

DRY=true
case "${1:-}" in
    -y|--yes) DRY=false ;;
    "")       ;;
    *) echo "usage: $0 [-y]    (no flag = dry run)" >&2; exit 1 ;;
esac

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
MARKER="# ais-edge phase2 tls hostnames"
K0S_DIR="${EDGE_K0S_DATA_DIR:-/var/lib/k0s}"
# This script recursively removes runtime state; accept only the shipped paths.
case "$K0S_DIR" in
    /var/lib/k0s|/data/k0s) ;;
    *) echo "ERROR: unsupported EDGE_K0S_DATA_DIR for reset: $K0S_DIR" >&2; exit 1 ;;
esac
RC=0
STAMP="/tmp/edge-reset-$(hostname -s)-$(date +%Y%m%d-%H%M%S)"
$DRY || mkdir -p "$STAMP"

ok()   { echo "  [ OK ] $*"; }
bad()  { echo "  [FAIL] $*" >&2; RC=1; }
note() { echo "         $*"; }
hdr()  { echo; echo "--- $* ---"; }
would() { echo "  WOULD: $*"; }

# act <description> -- <command...>
# In dry-run prints the description; otherwise runs the command.
act() {
    local desc="$1"; shift; [ "$1" = "--" ] && shift
    if $DRY; then would "$desc"; else "$@"; fi
}

# /etc/cni is here because `k0s reset` CREATES it. Observed on cai-lfs3: absent
# before the reset, 8.0K afterwards — the CNI config dir is rewritten during
# shutdown, so a run that removes only /var/lib/cni leaves it behind. microk8s
# keeps its own CNI state under /var/snap/microk8s, so /etc/cni is ours.
PATHS=(/etc/k0s "$K0S_DIR" /run/k0s /var/lib/cni /etc/cni)
HAPROXY_FILES=(/etc/haproxy/certs/ca.crt /etc/haproxy/certs/server.pem)

echo "============================================================"
echo " edge reset — $(hostname -f 2>/dev/null || hostname) — $(date -Is)"
$DRY && echo " MODE: DRY RUN — nothing will be changed. Re-run with -y to apply." \
     || echo " MODE: APPLY   — evidence -> ${STAMP}"
echo "============================================================"

# ---------------------------------------------------------------------------
hdr "1. what is here"
# ---------------------------------------------------------------------------
# `systemctl is-active` PRINTS its answer and ALSO exits non-zero for anything
# that is not active, so a `|| echo absent` fallback appends a second word to
# the first. Take the first line and let it speak for itself.
K0SW=$($SUDO systemctl is-active k0sworker 2>/dev/null | head -1)
echo "  k0sworker : ${K0SW:-absent}"
FOUND=0
for p in "${PATHS[@]}"; do
    [ -e "$p" ] && { echo "  present   : $p ($($SUDO du -sh "$p" 2>/dev/null | cut -f1))"; FOUND=$((FOUND+1)); }
done
for f in "${HAPROXY_FILES[@]}"; do [ -e "$f" ] && { echo "  present   : $f"; FOUND=$((FOUND+1)); }; done
grep -qxF "$MARKER" /etc/hosts 2>/dev/null && { echo "  present   : /etc/hosts marker block"; FOUND=$((FOUND+1)); }
MNT=$($SUDO findmnt -rno TARGET 2>/dev/null | grep -c "^${K0S_DIR}/" || true)
echo "  mounts under ${K0S_DIR}: ${MNT:-0}"
[ "$FOUND" -eq 0 ] && { echo; echo "  Nothing from a previous join is present. Nothing to do."; exit 0; }
echo
echo "  KEEPS     : /usr/local/bin/k0s, microk8s, Docker + CTP, all /data*, iptables DOCKER chains"

if ! $DRY; then
    $SUDO iptables-save > "$STAMP/iptables-before.txt" 2>/dev/null || true
    DOCKER_BEFORE=$(grep -c 'DOCKER' "$STAMP/iptables-before.txt" 2>/dev/null || true)
    DOCKER_CT_BEFORE=$($SUDO docker ps -q 2>/dev/null | wc -l || true)
else
    DOCKER_BEFORE=0; DOCKER_CT_BEFORE=0
fi

# ---------------------------------------------------------------------------
hdr "2. stop k0s, and wait for it to actually exit"
# ---------------------------------------------------------------------------
act "k0s stop; systemctl disable --now k0sworker" -- \
    bash -c "$SUDO k0s stop 2>/dev/null; $SUDO systemctl disable --now k0sworker 2>/dev/null; true"
if ! $DRY; then
    for i in $(seq 1 30); do
        pgrep -f "$K0S_DIR/bin/containerd|k0s worker" >/dev/null 2>&1 || break
        [ "$i" = 1 ] && printf '         waiting for k0s processes to exit'
        printf '.'; sleep 2
    done
    echo
    if pgrep -f "$K0S_DIR/bin/containerd|k0s worker" >/dev/null 2>&1; then
        bad "k0s processes still running after 60s — NOTHING has been removed"
        pgrep -af "$K0S_DIR/bin/containerd|k0s worker" | sed 's/^/         /' >&2
        exit 1
    fi
    ok "no k0s processes running"
else
    would "wait for containerd/kubelet to exit, and ABORT if they do not"
fi

# ---------------------------------------------------------------------------
hdr "3. k0s reset"
# ---------------------------------------------------------------------------
# Reset the same runtime store selected when the worker was joined.
act "k0s reset   (removes k0s's own containerd state and iptables rules)" -- \
    bash -c "$SUDO k0s reset --data-dir '$K0S_DIR' 2>&1 | sed 's/^/         /'; true"

# `k0s reset` deletes the unit FILE but systemd keeps the unit in `failed` state
# in memory — observed on cai-lfs3, where the post-reset check still reported
# `k0sworker: failed`. Cosmetic, but it makes a clean node look broken, and a
# later `systemctl --failed` review flags a service that no longer exists.
act "systemctl reset-failed k0sworker   (clear the remembered failed state)" -- \
    bash -c "$SUDO systemctl reset-failed k0sworker 2>/dev/null; $SUDO systemctl daemon-reload 2>/dev/null; true"

# ---------------------------------------------------------------------------
hdr "4. unmount anything left under ${K0S_DIR}"
# ---------------------------------------------------------------------------
# THE IMPORTANT ONE — see the header. Deepest first, so children go before
# their parents, then refuse to continue if any mount survives.
if $DRY; then
    if [ "${MNT:-0}" -gt 0 ]; then
        would "unmount ${MNT} mount(s) under ${K0S_DIR}, deepest first:"
        $SUDO findmnt -rno TARGET 2>/dev/null | grep "^${K0S_DIR}/" | sed 's/^/           /'
    else
        note "no mounts under ${K0S_DIR} to unmount"
    fi
    would "ABORT before any deletion if any mount still remains"
else
    for _ in 1 2 3; do
        MOUNTS=$($SUDO findmnt -rno TARGET 2>/dev/null | grep "^${K0S_DIR}/" | awk '{print length, $0}' | sort -rn | cut -d' ' -f2- || true)
        [ -z "$MOUNTS" ] && break
        while IFS= read -r m; do
            [ -n "$m" ] || continue
            $SUDO umount "$m" 2>/dev/null || $SUDO umount -l "$m" 2>/dev/null || true
        done <<< "$MOUNTS"
    done
    REMAIN=$($SUDO findmnt -rno TARGET 2>/dev/null | grep -c "^${K0S_DIR}/" || true)
    if [ "${REMAIN:-0}" -eq 0 ]; then
        ok "no mounts remain under ${K0S_DIR}"
    else
        bad "${REMAIN} mount(s) STILL under ${K0S_DIR} — refusing to delete"
        $SUDO findmnt -rno TARGET | grep "^${K0S_DIR}/" | sed 's/^/         /' >&2
        note "deleting across a live mount can destroy the mount SOURCE"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
hdr "5. remove, and verify each removal"
# ---------------------------------------------------------------------------
for p in "${PATHS[@]}"; do
    [ -e "$p" ] || continue
    if $DRY; then would "rm -rf $p   ($($SUDO du -sh "$p" 2>/dev/null | cut -f1))"
    else
        $SUDO rm -rf "$p" 2>/dev/null || true
        [ -e "$p" ] && bad "could not remove $p" || ok "removed $p"
    fi
done

# Two files, never the directory: on a host already running haproxy that
# directory is theirs and only these two files are ours.
for f in "${HAPROXY_FILES[@]}"; do
    [ -e "$f" ] || continue
    if $DRY; then would "rm -f $f"
    else
        $SUDO rm -f "$f" 2>/dev/null || true
        [ -e "$f" ] && bad "could not remove $f" || ok "removed $f"
    fi
done
# rmdir refuses a non-empty directory, so a pre-existing haproxy config is safe
# by construction — these only succeed if we left them empty.
if $DRY; then
    would "rmdir /etc/haproxy/certs and /etc/haproxy  (ONLY if we left them empty)"
else
    $SUDO rmdir /etc/haproxy/certs 2>/dev/null && ok "removed empty /etc/haproxy/certs"
    $SUDO rmdir /etc/haproxy       2>/dev/null && ok "removed empty /etc/haproxy"
fi

# /etc/hosts. `,+1d` deletes the marker AND the line under it, which is correct
# only while that line is still OUR entry. If someone removed the entry by hand
# and left the comment, the same command would eat THEIR next line instead.
if grep -qxF "$MARKER" /etc/hosts 2>/dev/null; then
    NEXT=$(grep -A1 -xF "$MARKER" /etc/hosts | tail -1)
    if printf '%s' "$NEXT" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]' \
       && printf '%s' "$NEXT" | grep -qE 'seaweedfs|konnect|k0s'; then
        if $DRY; then
            would "remove these 2 lines from /etc/hosts:"
            printf '           %s\n           %s\n' "$MARKER" "$NEXT"
        else
            $SUDO cp /etc/hosts "$STAMP/hosts.before"
            $SUDO sed -i "\|^${MARKER}\$|,+1d" /etc/hosts
            grep -qxF "$MARKER" /etc/hosts && bad "marker still in /etc/hosts" \
                || { ok "removed the /etc/hosts block"; note "backup: ${STAMP}/hosts.before"; }
        fi
    else
        if $DRY; then
            would "remove ONLY the orphaned marker comment from /etc/hosts"
            note "the line under it is NOT ours and would be KEPT: ${NEXT}"
        else
            $SUDO cp /etc/hosts "$STAMP/hosts.before"
            $SUDO sed -i "\|^${MARKER}\$|d" /etc/hosts
            ok "removed the orphaned marker comment ONLY"
            note "kept, because it is not ours: ${NEXT}"
        fi
    fi
fi

# ---------------------------------------------------------------------------
hdr "6. kernel network state — what a reboot would have cleared"
# ---------------------------------------------------------------------------
# `k0s reset` removes its iptables rules but NOT the interfaces, routes or
# conntrack entries already in the kernel, which is why it prints "a node reboot
# is recommended". On a box receiving from live scanners a reboot may not be
# available, so remove that state explicitly instead.
#
# ONLY kube-router's own interfaces. Everything else on this host belongs to
# something that must keep working:
#     docker0, br-*     Docker / CTP
#     cni0, flannel.*   microk8s (dormant, but not ours)
#     eth*, bond*, lo   the machine's real networking
# veth pairs are not listed: they are destroyed with the network namespace when
# their container goes, so `k0s reset` has already taken them.
K0S_IFACES=(kube-bridge kube-dummy-if)
for i in "${K0S_IFACES[@]}"; do
    ip link show "$i" >/dev/null 2>&1 || continue
    if $DRY; then would "ip link delete $i   (kube-router interface)"
    else
        $SUDO ip link delete "$i" 2>/dev/null || true
        ip link show "$i" >/dev/null 2>&1 && bad "could not delete interface $i" || ok "deleted interface $i"
    fi
done
[ -z "$(for i in "${K0S_IFACES[@]}"; do ip link show "$i" 2>/dev/null; done)" ] && $DRY \
    && note "no kube-router interfaces present"

# Routes to the pod CIDR normally vanish with the interface; a leftover means
# something re-added it, so report rather than silently delete.
STALE_ROUTES=$(ip -4 route 2>/dev/null | grep -E '10\.244\.|10\.96\.' || true)
if [ -n "$STALE_ROUTES" ]; then
    if $DRY; then
        would "remove stale pod/service CIDR routes:"; printf '%s\n' "$STALE_ROUTES" | sed 's/^/           /'
    else
        while IFS= read -r r; do
            [ -n "$r" ] && $SUDO ip route del $r 2>/dev/null || true
        done <<< "$STALE_ROUTES"
        ip -4 route | grep -qE '10\.244\.|10\.96\.' && bad "stale pod/service routes remain" || ok "removed stale pod/service routes"
    fi
else
    $DRY && note "no routes to 10.244.0.0/16 or 10.96.0.0/12"
fi

# Conntrack entries for the pod and service CIDRs. Harmless once the addresses
# are gone, but they make a fresh install inherit half-open flows to endpoints
# that no longer exist. Scoped to those two CIDRs, so no CTP/Docker flow is
# touched. Skipped silently when conntrack is not installed.
if command -v conntrack >/dev/null 2>&1; then
    if $DRY; then
        CT=$($SUDO conntrack -L 2>/dev/null | grep -cE '10\.244\.|10\.96\.' || true)
        would "flush ${CT:-0} conntrack entries for 10.244.0.0/16 and 10.96.0.0/12 ONLY"
    else
        for cidr in 10.244.0.0/16 10.96.0.0/12; do
            $SUDO conntrack -D -s "$cidr" >/dev/null 2>&1 || true
            $SUDO conntrack -D -d "$cidr" >/dev/null 2>&1 || true
        done
        ok "flushed conntrack for the pod and service CIDRs"
    fi
else
    note "conntrack tool not installed — entries will age out on their own"
fi

# ---------------------------------------------------------------------------
hdr "7. verify"
# ---------------------------------------------------------------------------
if $DRY; then
    note "after applying, this step re-checks every path, confirms k0sworker is"
    note "gone, and compares Docker's container count and iptables DOCKER rules"
    note "against a baseline taken before the change."
    echo
    echo "============================================================"
    echo " DRY RUN — nothing was changed."
    echo " Re-run with -y to apply:   sudo bash $0 -y"
    echo "============================================================"
    exit 0
fi

LEFT=""
for p in "${PATHS[@]}" "${HAPROXY_FILES[@]}"; do [ -e "$p" ] && LEFT="$LEFT $p"; done
[ -z "$LEFT" ] && ok "every join-created path is gone" || bad "still present:$LEFT"
$SUDO systemctl is-active k0sworker >/dev/null 2>&1 && bad "k0sworker still active" || ok "k0sworker gone"

$SUDO iptables-save > "$STAMP/iptables-after.txt" 2>/dev/null || true
DOCKER_AFTER=$(grep -c 'DOCKER' "$STAMP/iptables-after.txt" 2>/dev/null || true)
if [ "${DOCKER_AFTER:-0}" -ge "${DOCKER_BEFORE:-0}" ]; then
    ok "Docker iptables lines intact (${DOCKER_BEFORE} -> ${DOCKER_AFTER})"
else
    bad "Docker iptables lines dropped ${DOCKER_BEFORE} -> ${DOCKER_AFTER}"
    note "restore with: sudo systemctl restart docker   (rebuilds its own chains)"
fi
DA=$($SUDO docker ps -q 2>/dev/null | wc -l || true)
[ "${DA:-0}" -ge "${DOCKER_CT_BEFORE:-0}" ] && ok "docker containers: ${DOCKER_CT_BEFORE} -> ${DA}" \
    || bad "docker containers LOST: ${DOCKER_CT_BEFORE} -> ${DA}"
KUBE=$(grep -ciE 'KUBE|CNI' "$STAMP/iptables-after.txt" 2>/dev/null || true)
[ "${KUBE:-0}" -eq 0 ] && ok "no KUBE/CNI iptables rules remain" || note "${KUBE} KUBE/CNI lines remain — a reboot clears them"
for m in /data /data_local /database; do
    [ -d "$m" ] || continue
    findmnt -n "$m" >/dev/null 2>&1 && ok "$m still mounted" || bad "$m NOT mounted"
done

echo
echo "============================================================"
[ "$RC" -eq 0 ] && echo " reset complete — nothing outside the join was touched" \
                || echo " COMPLETED WITH FAILURES — read the [FAIL] lines above"
echo " evidence: ${STAMP}"
echo "============================================================"
echo " Step 6 removed the kernel network state a reboot would have cleared, so a"
echo " reboot is NOT required before rejoining. What a reboot would still do that"
echo " this cannot: unload kernel modules k0s inserted (br_netfilter, overlay,"
echo " ip_vs*). Those are inert when nothing uses them and are loaded again by the"
echo " next join, so leaving them is safe."
echo " If you do reboot later, confirm first:  sudo findmnt --verify --fstab"
exit "$RC"
