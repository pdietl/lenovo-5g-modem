#!/bin/sh
# Install the ModemManager shutdown bound: the daemon can fail to exit when it
# is stopped while a modem is probing, and systemd then waits out its full stop
# timeout on every reboot. patches/ carries the fix for the daemon itself.
set -eu

CONF=10-shutdown-hang.conf
DROPIN=/etc/systemd/system/ModemManager.service.d
UNIT=/usr/lib/systemd/system/ModemManager.service
SRC="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }

# The drop-in restates ExecStart, so a moved binary would silently break start.
[ -x /usr/sbin/ModemManager ] ||
    { echo "/usr/sbin/ModemManager missing; fix the ExecStart in $CONF" >&2; exit 1; }

install -D -m 644 "$SRC/$CONF" "$DROPIN/$CONF"
systemctl daemon-reload
echo "installed $DROPIN/$CONF"

# A flag edited straight into the packaged unit is overridden by the drop-in and
# lost on upgrade; say so rather than leaving two places to look.
want=$(awk '$2 == "usr/lib/systemd/system/ModemManager.service" { print $1 }' \
    /var/lib/dpkg/info/modemmanager.md5sums 2>/dev/null || true)
got=$(md5sum "$UNIT" 2>/dev/null | cut -d' ' -f1 || true)
if [ -n "$want" ] && [ -n "$got" ] && [ "$want" != "$got" ]; then
    cat >&2 <<EOF
note: $UNIT differs from the packaged copy. This drop-in overrides it, so that
      edit has no effect now. Restore the packaged file with:
          apt-get install --reinstall modemmanager
EOF
fi

cat <<'EOF'

Check with:
    systemctl show ModemManager.service -p TimeoutStopUSec -p ExecStart

Expect TimeoutStopUSec=10s and the --test-low-power-suspend-resume flag.

Time a stop to confirm the bound holds (cellular drops for ~20s while the
modem re-probes, so have another link up):
    time systemctl stop ModemManager && systemctl start ModemManager
EOF
