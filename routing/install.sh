#!/bin/sh
# Install the cellular-as-fallback routing policy: cellular stays connected
# but carries traffic only when nothing else can. docs/diagnostics.md explains
# the metric choices.
set -eu

CONF=90-ipv6-oif-source-only.conf
SRC="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }

install -m 644 "$SRC/$CONF" /etc/sysctl.d/
/usr/lib/systemd/systemd-sysctl "/etc/sysctl.d/$CONF"
echo "installed and applied /etc/sysctl.d/$CONF"

# IPv4 1050 loses to Ethernet and Wi-Fi but still beats a link whose failed
# connectivity check penalised it by +20000, so a captive portal or dead
# uplink fails over to cellular by itself. IPv6 30000 loses even to those:
# a v4-only Wi-Fi must not pull the machine's IPv6 -- most dual-stack
# traffic -- onto metered cellular.
profiles=$(nmcli -g NAME,TYPE connection show | awk -F: '$2 == "gsm" { print $1 }')
if [ -z "$profiles" ]; then
    echo "no GSM profile yet; create it (see README) and re-run to set its metrics" >&2
    exit 1
fi
printf '%s\n' "$profiles" | while IFS= read -r name; do
    nmcli connection modify "$name" \
        connection.autoconnect yes \
        connection.metered yes \
        ipv4.route-metric 1050 \
        ipv6.route-metric 30000
    echo "set fallback metrics on '$name'"
    # Metrics only take effect on activation.
    if nmcli -g NAME connection show --active | grep -qxF "$name"; then
        echo "re-activating '$name' to apply them"
        nmcli connection up "$name" >/dev/null ||
            echo "warning: could not re-activate '$name'" >&2
    fi
done

cat <<'EOF'

Check with:
    ip route show default; ip -6 route show default

wwan0 must sit at metric 1050 (IPv4) and 30000 (IPv6).
EOF
