#!/bin/sh
# Install the cellular technology indicator for the invoking user.
set -eu

UUID=cellular-tech@lenovo-5g-modem.local
SRC="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$UUID"
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/$UUID"

[ "$(id -u)" != 0 ] || {
    echo "run as your own user; this installs into your home directory" >&2
    exit 1
}
[ -d "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

mkdir -p "$DEST"
cp "$SRC/extension.js" "$SRC/metadata.json" "$SRC/stylesheet.css" "$DEST/"
echo "installed to $DEST"

# gnome-extensions(1) can only enable what the shell already knows about, and
# the shell enumerates extensions once at startup without monitoring the
# directories. On a first install it has therefore never seen this one, so fall
# back to writing the setting directly.
if gnome-extensions info "$UUID" >/dev/null 2>&1; then
    gnome-extensions enable "$UUID"
    echo "enabled"
else
    current=$(gsettings get org.gnome.shell enabled-extensions)
    case "$current" in
    *"'$UUID'"*)
        ;;
    "@as []"|"[]")
        gsettings set org.gnome.shell enabled-extensions "['$UUID']"
        ;;
    *)
        gsettings set org.gnome.shell enabled-extensions "${current%]}, '$UUID']"
        ;;
    esac
    echo "enabled for the next session; log out and back in to load it"
fi

for key in allow-extension-installation disable-user-extensions; do
    printf '  %s: %s\n' "$key" "$(gsettings get org.gnome.shell "$key")"
done
echo "  (allow-extension-installation must be true, disable-user-extensions false)"
