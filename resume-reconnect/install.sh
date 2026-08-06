#!/bin/sh
# Install the resume reconnect workaround: cellular re-activates after
# suspend despite NetworkManager blocking its autoconnect.
set -eu

SRC="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }

install -D -m 755 "$SRC/wwan-resume-reconnect" /usr/local/sbin/wwan-resume-reconnect
install -D -m 644 "$SRC/wwan-resume-reconnect.service" \
    /etc/systemd/system/wwan-resume-reconnect.service
systemctl daemon-reload
systemctl enable wwan-resume-reconnect.service

cat <<'EOF'
Installed. After every resume, cellular profiles with autoconnect enabled are
re-activated once the modem is usable again. To keep cellular off across
suspends, use the persistent switches ('nmcli radio wwan off' or
autoconnect=no); the Mobile quick-settings tile only holds until the next
resume.

Check a resume with:
    journalctl -b -u wwan-resume-reconnect.service
EOF
