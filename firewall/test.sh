#!/bin/sh
# Prove the loaded cellular firewall without a cellular link. A network
# namespace reaches this host through a veth named like a cellular interface
# and through an ordinary one, so the ordinary path shows the probe itself
# works. Run as root; everything it creates is removed on exit.
set -eu

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
nft list table inet wwan_firewall >/dev/null 2>&1 ||
    { echo "the wwan_firewall table is not loaded (run install.sh)" >&2; exit 1; }

NS=wwan-fw-test
PORT=47123
WORK="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked by the trap below
cleanup() {
    while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$WORK/pids" 2>/dev/null || true
    ip link del wwantest0 2>/dev/null || true
    ip link del lantest0 2>/dev/null || true
    ip netns del "$NS" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

cat > "$WORK/listen.py" <<'PY'
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], int(sys.argv[2])))
s.listen()
while True:
    s.accept()[0].close()
PY

ip netns add "$NS"
# IPv6 off in the namespace before its links exist, so no neighbor discovery or
# multicast listener report reaches the drop rule: its counter then moves for
# the probes alone.
ip netns exec "$NS" sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
ip link add wwantest0 type veth peer name cell0 netns "$NS"
ip link add lantest0 type veth peer name lan0 netns "$NS"
for dev in wwantest0 lantest0; do
    nmcli device set "$dev" managed no 2>/dev/null || true
done
ip addr add 192.0.2.1/30 dev wwantest0
ip addr add 198.51.100.1/30 dev lantest0
ip -n "$NS" addr add 192.0.2.2/30 dev cell0
ip -n "$NS" addr add 198.51.100.2/30 dev lan0
# Like the modem's own wwan0, which is point-to-point with no multicast, so
# avahi announces nothing here whose looped-back copies the drop rule would
# count.
for dev in wwantest0 lantest0; do ip link set "$dev" multicast off up; done
for dev in lo cell0 lan0; do ip -n "$NS" link set "$dev" up; done

python3 "$WORK/listen.py" 0.0.0.0 "$PORT" & echo $! >> "$WORK/pids"
ip netns exec "$NS" python3 "$WORK/listen.py" 192.0.2.2 "$PORT" & echo $! >> "$WORK/pids"
sleep 1

dropped() {
    nft list chain inet wwan_firewall input |
        sed -n "s/.*counter packets \([0-9]*\).*unsolicited inbound.*/\1/p"
}

[ -n "$(dropped)" ] ||
    { echo "the wwan_firewall table has no drop rule (run install.sh)" >&2; exit 1; }

failed=0
check() {  # $1 = expected outcome (open|closed), $2 = what, then the probe
    want=$1 what=$2
    shift 2
    if "$@" >/dev/null 2>&1; then got=open; else got=closed; fi
    if [ "$got" = "$want" ]; then
        echo "PASS  $what: $got"
    else
        echo "FAIL  $what: $got, expected $want"
        failed=1
    fi
}

counted() {  # $1 = expected change of the drop counter (none|some), $2 = what
    now=$(dropped)
    if { [ "$1" = none ] && [ "$now" -eq "$last" ]; } ||
        { [ "$1" = some ] && [ "$now" -gt "$last" ]; }; then
        echo "PASS  drop counter after $2: $last -> $now"
    else
        echo "FAIL  drop counter after $2: $last -> $now, expected $1"
        failed=1
    fi
    last=$now
}

last=$(dropped)
check open "inbound on an ordinary link (control)" \
    ip netns exec "$NS" nc -z -w 3 198.51.100.1 "$PORT"
check open "outbound on the cellular link" \
    nc -z -w 3 192.0.2.2 "$PORT"
counted none "the traffic it allows"
check closed "inbound on the cellular link" \
    ip netns exec "$NS" nc -z -w 3 192.0.2.1 "$PORT"
counted some "the inbound probe"
exit "$failed"
