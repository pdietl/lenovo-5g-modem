#!/bin/sh
# Build and install the FCC unlock helper and its ModemManager hook.
set -eu

SDK=/opt/fcc_lenovo/lib/libfiisdk.so.2.2.2
PCI_ID=17cb:0308

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }

if [ ! -f "$SDK" ]; then
    cat >&2 <<EOF
$SDK is missing.

The unlock is performed by Foxconn's SDK, which ships in Lenovo's WWAN unlock
package. Install that first (it also installs the hook this replaces):

    https://github.com/lenovo/lenovo-wwan-unlock

Its own unlock service refuses to run on a US SIM; that is what this replaces.
EOF
    exit 1
fi

if ! lspci -nn 2>/dev/null | grep -qi "$PCI_ID"; then
    echo "warning: no $PCI_ID device found; the hook will simply never fire" >&2
fi

make
make install

# ModemManager only dispatches the hook when it hits the locked modem during
# enable, so restart it rather than waiting for the next boot.
if command -v systemctl >/dev/null && systemctl is-active --quiet ModemManager; then
    echo "restarting ModemManager"
    systemctl restart ModemManager
fi

cat <<EOF

Installed. The unlock is volatile and is redone by
/etc/ModemManager/fcc-unlock.d/$PCI_ID on every modem power-on.

Check with:
    mmcli -m any | grep -E 'state|power state'

'power state: on' means it worked. 'power state: low' plus
"Cannot power-up: sotware radio switch is OFF" in journalctl -u ModemManager
means it did not.
EOF
