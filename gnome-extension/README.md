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
connection NetworkManager considers primary.

When cellular *is* primary the shell draws its own cellular icon, so this one
hides its bars to avoid showing two. The technology label always stays: it is
wanted most exactly when cellular is the connection in use, and the shell never
renders it.

The indicator sits immediately after the network indicator so that signal bars
always precede the technology, whichever set of bars is being shown:

| Primary connection | Panel reads |
| --- | --- |
| Ethernet or Wi-Fi | shell's wired/Wi-Fi icon, then `[bars] 5G SA` from here |
| Cellular | the shell's own bars, then `5G SA` from here |

Labels: `2G`, `G`, `E`, `3G`, `H`, `H+`, `LTE`, `5G` (EN-DC), `5G SA`
(standalone). Signal thresholds and icon names are taken from the shell's own
`signalToIcon`, so this indicator and the built-in one never disagree.

## Install

```sh
./install.sh
```

Run it as yourself, not root: it installs under `$XDG_DATA_HOME` (or
`~/.local/share`) and enables the extension for your session.

**A first install needs a log out and back in.** `gnome-extensions enable` can
only act on extensions the shell already knows about, and the shell enumerates
them once at startup with no directory monitor — so a newly created extension is
invisible until the next login. `install.sh` writes the `enabled-extensions`
setting directly in that case, preserving any extensions already listed.

A log out is also needed after *editing* the code. The shell imports
`extension.js` by URI with no cache-busting, and GJS caches ES modules for the
life of the session, so disabling and re-enabling re-runs the old code. On
Wayland the shell cannot be restarted in place either, so `Alt+F2 r` is not an
option.

Three settings gate user extensions entirely; all must be permissive:

```sh
gsettings get org.gnome.shell allow-extension-installation   # true
gsettings get org.gnome.shell disable-user-extensions        # false
```

`metadata.json` declares `shell-version: ["50"]`. Update it for other GNOME
releases, or set `disable-extension-version-validation` to true.
