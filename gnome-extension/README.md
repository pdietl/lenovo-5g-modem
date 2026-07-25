# Cellular Technology Indicator

A GNOME Shell indicator showing cellular signal strength and the active access
technology beside the network icon.

It exists because the built-in indicator does neither:

- **It shows no access technology at all.** `ui/status/network.js` uses only the
  static `NM.DeviceModemCapabilities` bits to pick an icon; there is no code path
  that reads the live technology, and no 5G branch anywhere. So there is no way
  to tell LTE from 5G, let alone 5G standalone from EN-DC — a distinction that
  matters here, since it is the difference between a 10 MHz LTE anchor and a
  100 MHz NR carrier.
- **It hides the modem whenever another link is up.** The indicator binds a
  single `_primaryIndicator` to NetworkManager's *primary* connection, so with
  Ethernet or Wi-Fi connected the cellular icon is not drawn anywhere.

This reads ModemManager directly over D-Bus, so it is independent of which
connection NetworkManager considers primary. It stands down when the built-in
icon is already showing cellular, so the two never appear twice.

Labels: `2G`, `G`, `E`, `3G`, `H`, `H+`, `LTE`, `5G` (EN-DC), `5G SA`
(standalone). Signal thresholds and icon names are taken from the shell's own
`signalToIcon`, so this indicator and the built-in one never disagree.

## Install

```sh
cp -r cellular-tech@pdietl.local ~/.local/share/gnome-shell/extensions/
gnome-extensions enable cellular-tech@pdietl.local
```

If `gnome-extensions enable` reports the extension does not exist, the shell has
not enumerated it yet. Extensions are collected once at shell startup and the
directories are not monitored, so a newly created one is invisible until the next
login. Enable it via gsettings instead and log out:

```sh
gsettings set org.gnome.shell enabled-extensions \
    "$(gsettings get org.gnome.shell enabled-extensions \
        | sed "s/]$/, 'cellular-tech@pdietl.local']/;s/^@as \[\]$/['cellular-tech@pdietl.local']/")"
```

On Wayland the shell cannot be restarted in place, so this needs a log out and
back in rather than `Alt+F2 r`.

Three settings gate user extensions entirely; all must be permissive:

```sh
gsettings get org.gnome.shell allow-extension-installation   # true
gsettings get org.gnome.shell disable-user-extensions        # false
```

`metadata.json` declares `shell-version: ["50"]`. Update it for other GNOME
releases, or set `disable-extension-version-validation` to true.
