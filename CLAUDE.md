# Working context

Machine: ThinkPad T16 Gen 5 (`21WXCTO1WW`), Ubuntu 26.04, kernel 7.0, GNOME 50.1.
Modem: Foxconn T99W696 (Qualcomm SDX62), PCI `17cb:0308`, MBIM over PCIe/MHI at
`/dev/wwan0mbim0`. Carrier: Google Fi, APN `h2g2`.

Read [docs/FINDINGS.md](docs/FINDINGS.md) before proposing any change to how the
modem is configured. Most things that look misconfigured here are not.

## Settled questions — do not re-investigate

- **Why the radio will not power up out of the box.** Lenovo's
  `DPR_Fcc_unlock_service` refuses on a US SIM, by design. Solved by
  `fcc-unlock/`, which calls the vendor SDK directly.
- **Why the modem runs EN-DC instead of 5G SA on the data-only eSIM.** The
  network rejects the SA registration; the subscription is not provisioned for
  it. A voice+data SIM registers SA on the same modem in the same place. Nothing
  local to fix. Mode preference, acquisition order, EN-DC config and SA band
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

Expect `state: connected`, `power state: on`, and `204`. Cellular sits at
route-metric 1050, so bind to `wwan0` explicitly whenever another link is up.

## Open items

- Suspend/resume with the modem active is untested on BIOS 0.1.06, whose
  changelog claims a fix for "the linux system will hung sometimes when into
  S3 (Environment: 5G WWAN + Linux System)".
- The `qmicli` patch in `patches/` is not upstream. Submitting it needs a
  gitlab.freedesktop.org fork, which needs a one-time project-limit request in
  the `freedesktop/freedesktop` issue tracker; new accounts there cannot create
  projects. A gitlab.com fork cannot be used — merge requests do not cross GitLab
  instances, and the CI config resolves `freedesktop/ci-templates` only on the
  freedesktop instance.
- Replacing the vendor blob with pure `qmicli` needs a QMI service `0xE4`
  definition in libqmi; see docs/fcc-unlock-protocol.md.
