# Working context

Machine: ThinkPad T16 Gen 5 (`21WXCTO1WW`), Ubuntu 26.04, kernel 7.0, GNOME 50.1.
Modem: Foxconn T99W696 (Qualcomm SDX62), PCI `17cb:0308`, MBIM over PCIe/MHI at
`/dev/wwan0mbim0`. Carrier: T-Mobile, a business line with a static public IPv4
(`firewall/` drops unsolicited inbound on it), APN `fast.t-mobile.com`. The
Google Fi findings below were measured on a Fi eSIM.

Read [docs/FINDINGS.md](docs/FINDINGS.md) before proposing any change to how the
modem is configured. Most things that look misconfigured here are not.

## Settled questions — do not re-investigate

- **Why the radio will not power up out of the box.** Lenovo's
  `DPR_Fcc_unlock_service` refuses on a US SIM, by design. Solved by
  `fcc-unlock/`, which calls the vendor SDK directly.
- **Why the modem runs EN-DC instead of 5G SA on the data-only eSIM.** The
  network rejects the SA registration; the subscription is not provisioned for
  it. A voice+data SIM registers SA on the same modem in the same place, and
  Google Fi support has confirmed data-only profiles carry no SA registration
  rights, by design. Nothing local to fix. Mode preference, acquisition order, EN-DC config and SA band
  preferences are all already correct — checking them again will waste time.
- **Whether signal or antennas are the limit.** They are not; this modem reads
  better RSRP than a Pixel 9 Pro XL sitting beside it.

## Traps

- **Never benchmark this link with a single stream to a distant server.** It
  reads a few Mbps and looks exactly like a carrier throttle. Use parallel
  streams to a nearby server. See docs/diagnostics.md.
- **Band numbers from `nas-get-cell-location-info` are wrong.** Its EARFCN field
  is 16-bit and wraps; use `nas-get-rf-band-info`.
- **`--nas-set-system-selection-preference` token order sets the acquisition
  order.** Stock order here is `5gnr, lte, umts`. Restoring with a different
  order silently deprioritises 5G. Always read it back.
- **The modem index changes constantly** (power cycle, SIM slot switch, resume).
  Use `mmcli -m any`, never a hardcoded index.
- **NetworkManager pins a GSM profile to the first ICCID it activates on.** After
  a SIM slot switch the profile refuses the new SIM. Keep `gsm.sim-id` empty.
- **Do not `ninja install` a locally built libqmi.** It shadows the system libqmi
  that ModemManager links against. Run `qmicli` from the build tree with
  `LD_LIBRARY_PATH`.
- **After a resume the modem takes ~20 s to re-enumerate, and the profile can
  come back autoconnect-blocked.** `resume-reconnect/` re-activates it; check
  `journalctl -b -u wwan-resume-reconnect.service` before debugging anything
  else.
- **`no cellular device appeared` from that unit means the modem is gone, not
  blocked.** A suspend landed during modem setup (a lid-closed boot does it),
  and an unpatched ModemManager running `--test-low-power-suspend-resume` (the
  `shutdown-hang/` drop-in sets it) never re-probes it. Re-probe with the
  `udevadm trigger` in docs/diagnostics.md; `mmcli --scan-modems` fails after
  any suspend on the archive's 1.25.95.

## Cold boot signature

The modem boots FCC-locked every time, so this in `journalctl -b -u ModemManager`
is the *healthy* trace, not a fault:

```
Cannot power-up: sotware radio switch is OFF      <- booted locked
power state updated: on                           <- hook ran, ~2s later
state changed (enabling -> enabled) -> registered -> connected
```

The failure looks the same up to the first line and is then followed by
`couldn't enable interface: 'Invalid transition'`, with the modem staying at
`power state: low`.

## Verify the modem is healthy

```sh
mmcli -m any | grep -E 'state:|power state|access tech|operator name'
curl -s --interface wwan0 -o /dev/null -w '%{http_code}\n' https://www.google.com/generate_204
```

Expect `state: connected`, `power state: on`, and `204`. Cellular stays
connected as a fallback but loses the routing decision to any working link
(route metrics: IPv4 1050, IPv6 30000 — see docs/diagnostics.md), so bind to
`wwan0` explicitly whenever another link is up.

## Open items

- The NetworkManager suspend bug behind `resume-reconnect/` (sleep tears the
  modem down as `user-requested`, which can leave the profile blocked from
  autoconnect) is not reported upstream yet, and the exact conditions that arm
  the block are only partially mapped — see docs/FINDINGS.md.
- The ModemManager patches are deployed only while `dpkg -l modemmanager`
  shows a `+pdietl` version, built by `modemmanager-package/build`. An ordinary
  upgrade to a newer archive version replaces it and drops the fixes; rebuild
  against the new version, or check its changelog carries them. With
  `install-guard.sh` installed, `journalctl -t modemmanager-guard` says so.
- The `qmicli` patch is merged in libqmi main (`7536d3a9`) but not yet in a
  release. qmicli's EARFCN table gains bands 45 to 54 in
  mobile-broadband/libqmi!488, in review. The suspend-during-setup series (patches 0002-0004) is in review as
  mobile-broadband/ModemManager!1528 on gitlab.freedesktop.org, from the
  `pdietl/ModemManager` fork; review changes go in as fixups and a force-push.
  The shutdown-hang patch (0001) is not submitted yet.
- Replacing the vendor blob with pure `qmicli` needs a QMI service `0xE4`
  definition in libqmi; see docs/fcc-unlock-protocol.md.
