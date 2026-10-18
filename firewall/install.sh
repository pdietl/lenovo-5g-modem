#!/bin/sh
# Install the cellular firewall: unsolicited inbound traffic on the cellular
# link is dropped, and every other interface is left alone.
set -eu

SRC="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }

nft -c -f "$SRC/wwan-firewall.nft"
install -m 644 "$SRC/wwan-firewall.nft" /etc/wwan-firewall.nft
install -m 644 "$SRC/wwan-firewall.service" /etc/systemd/system/wwan-firewall.service
systemctl daemon-reload
systemctl enable wwan-firewall.service
# restart, not start, so a re-run applies an edited ruleset.
systemctl restart wwan-firewall.service

cat <<'EOT'
Installed and loaded. Check with:
    sudo nft list table inet wwan_firewall
    sudo ./test.sh

The drop counters count what the firewall has turned away.
EOT
