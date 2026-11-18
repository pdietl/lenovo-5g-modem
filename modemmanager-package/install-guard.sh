#!/bin/sh
# Install the apt guard that warns once an upgrade has replaced the patched
# ModemManager build. Install the build itself with the commands `build` prints.
set -eu

SRC="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }

install -D -m 755 "$SRC/modemmanager-guard" /usr/local/sbin/modemmanager-guard
install -D -m 644 "$SRC/54modemmanager-guard" /etc/apt/apt.conf.d/54modemmanager-guard
echo "installed /usr/local/sbin/modemmanager-guard and its apt hook"

/usr/local/sbin/modemmanager-guard

cat <<'EOF'

Check with:
    journalctl -t modemmanager-guard
EOF
