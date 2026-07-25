# References

What each source actually contributed, since several are close to the problem
without being right about this modem.

## The decisive ones

**[SySS Tech Blog — "Foxconn FCC Unlock"](https://blog.syss.com/posts/foxconn-fcc-unlock/)**
(Jan Wütherich, 2025-09-15). Reverse-engineers the unlock on a Dell DW5932e
(Snapdragon X62) and publishes the whole scheme: the md5 token built from
firmware versions + IMEI + salt + a magic value, the move from the DMS service to
a Foxconn-private QMI service, and a working ModemManager script. **Its specific
constants do not work on the T99W696** — it uses magic `FDE1` on service `0xE3`,
where this modem needs `FDE2` on `0xE4` — but it establishes the shape of the
scheme, which is what made the vendor blob readable. The single most useful
source. Its libqmi work landed as merge request !417, adding
`--fox-set-fcc-authentication`.

**[lenovo/lenovo-wwan-unlock](https://github.com/lenovo/lenovo-wwan-unlock)**
Lenovo's own unlock tooling, and the origin of both the problem and its solution:
the README states plainly that "WWAN enablement is currently blocked for the USA
SIM, as carrier certification for Linux is not being pursued at this time", while
the `libfiisdk` blob it ships is what performs the unlock once the wrapper's
policy check is skipped.

**[Issue #88 — "Plans for Verizon US Unlock?"](https://github.com/lenovo/lenovo-wwan-unlock/issues/88)**
Lenovo's maintainer confirming the US block is deliberate and commercial:
"carrier certification for USA is blocked now mainly due to e-sim support
requirement and lack of business case." This is what turns "my setup is broken"
into "the vendor chose this", and justifies bypassing the check rather than
hunting for a misconfiguration.

## Establishing that the blob was worth reading

**[Issue #98 — ThinkPad P16s Gen 5 / Snapdragon X61](https://github.com/lenovo/lenovo-wwan-unlock/issues/98)**
A user patches `DPR_Fcc_unlock_service`'s machine-ID jump table to add their
unsupported laptop, and gets WWAN working. Proof that the wrapper's gates are
policy rather than technical, and that the SDK underneath is general.

**[Issue #91 — MediaTek T700 on X13 Gen 6](https://github.com/lenovo/lenovo-wwan-unlock/issues/91)**
`strace` output showing `DPR_Fcc_unlock_service` reading `/sys/class/dmi/id/product_family`
and `product_name` before failing, plus the observation that the modem "works
fully under Windows, confirming the hardware is factory FCC-unlocked". Useful
model for how these binaries gate themselves.

**[foxconn-pc/fii_linux](https://github.com/foxconn-pc/fii_linux)**
Foxconn's Linux `FoxFlss` tool for Dell DW5932e/DW5934e. Not usable here — it
checks the platform SKU via `dmidecode` and rejects a Lenovo — but it is the
same SDK family, and the SySS analysis of it is what mapped the protocol.

## Context and cross-checks

**[agentydragon/ducktape](https://github.com/agentydragon/ducktape)**
Someone else's working notes running **Google Fi on a Foxconn modem under Linux**
(DW5934e/SDX72 on NixOS). Independently confirms Fi's APN is `h2g2`, that the
Foxconn QMI service responds on these modems, and documents the MHI/suspend
wedges and runtime-PM hazards worth knowing about. Also a cautionary data point:
their throughput was throttled by an unregistered IMEI, which is a real failure
mode even though it turned out not to be ours.

**[ModemManager — FCC unlock procedure](https://modemmanager.org/docs/modemmanager/fcc-unlock/)**
The contract for `fcc-unlock.d`: vendor scripts go in `${libdir}`, user overrides
in `${sysconfdir}`, and **a script that fails is not retried**. That last point
explains why a failing unlock leaves the modem dead rather than looping.

**[ModemManager `data/dispatcher-fcc-unlock/105b`](https://gitlab.freedesktop.org/mobile-broadband/ModemManager/-/blob/main/data/dispatcher-fcc-unlock/105b)**
The upstream Foxconn SDX55 script. The reference implementation of the v2 token
scheme, including the `sed -e 's/\.[^.]*\.[^.]*$//'` firmware-version trimming
that the SDK also performs.

**[libqmi](https://gitlab.freedesktop.org/mobile-broadband/libqmi)**
Canonical repo (the `linux-mobile-broadband` GitHub org is a read-only mirror).
`data/qmi-service-fox.json` and `src/qmicli/qmicli-nas.c` are where the FOX
service and the NR5G band preference plumbing live.

**[Lenovo — Enabling WWAN on Linux](https://download.lenovo.com/pccbbs/mobiles_pdf/wwan-enablement-on-Linux.pdf)**
Lenovo's official write-up, and a second statement of the USA SIM restriction.

## Read locally, not online

The GNOME Shell indicator work came from the shipped source rather than
documentation — `/usr/lib/gnome-shell/libshell-18.so` contains the JS, which
`gresource extract` will pull out. `ui/status/network.js` gives the exact
`signalToIcon` thresholds and shows that the network indicator binds a *single*
`_primaryIndicator` to the primary connection, which is why a connected modem is
invisible whenever Ethernet is up. `ui/panel.js` shows how indicators are added,
and `ui/extensionSystem.js` shows that extensions are enumerated once at startup
with no directory monitor.

Likewise the unlock protocol itself was recovered from
`/opt/fcc_lenovo/lib/libfiisdk.so.2.2.2` with `objdump`/`nm`; see
[fcc-unlock-protocol.md](fcc-unlock-protocol.md).
