# Findings

Measurements are snapshots from a single location (Austin, TX area, T-Mobile
n41 coverage) taken 2026-07-25 unless noted. Treat the numbers as evidence for
the conclusions, not as specifications.

## The modem is FCC-locked and Lenovo will not unlock it on a US SIM

Symptom, repeating indefinitely:

```
DPR_Fcc_unlock_service: This is a US SIM card.
DPR_Fcc_unlock_service: FCC unlock failed
ModemManager: Cannot power-up: sotware radio switch is OFF
ModemManager: couldn't enable interface: 'Invalid transition'
```

`/usr/lib/x86_64-linux-gnu/ModemManager/fcc-unlock.d/17cb:0308`, installed by
Lenovo, calls `/opt/fcc_lenovo/DPR_Fcc_unlock_service`. That binary reads the
SIM's country and refuses to proceed on a US SIM. Its strings include
`Available SIM is of USA, Exiting FCC unlock !` and `Verizon SIM is detetected,
Hence FCC unlock will not be executed`.

Lenovo's position, from `lenovo/lenovo-wwan-unlock` issue #88: "carrier
certification for USA is blocked now mainly due to e-sim support requirement and
lack of business case." Not a hardware limitation — the same modem works on
Windows, which proves the hardware is certified and functional.

**The refusal lives only in the wrapper.** Counting matches for
`US SIM|USA|Verizon`:

| Binary | Matches |
| --- | --- |
| `DPR_Fcc_unlock_service` | 19 |
| `lib/libmbimtools.so` | 5 |
| `lib/libfiisdk.so.2.2.2` | **0** |

`libfiisdk.so.2.2.2` is the Foxconn SDK that performs the actual unlock and
contains no SIM or country logic at all. `fcc-unlock/` calls `Fox_Attempt()` in
that SDK — the same entry point the Lenovo wrapper uses — so the unlock is
performed by unmodified vendor code with only the policy gate bypassed.

## A data-only Fi eSIM cannot register 5G SA

The modem was running EN-DC (LTE anchor + 5G secondary), not standalone 5G.
Everything on the modem was already configured correctly:

- Mode preference: `umts, lte, 5gnr`
- Acquisition order preference: `5gnr, lte, umts`
- EN-DC config: `Enabled: true`, `Immediate SCG Release: false`
- NR5G SA band preference includes n41
- Active carrier config: `T-mobile` rev `0xA010502`, the only US T-Mobile config
  of the 25 on the modem

Forcing `5gnr`-only mode with the SA band preference pinned to n41 (which needs
the `qmicli` patch in `patches/`) removes every way for the modem to avoid SA.
It then camps on the correct cell and still cannot register:

```
Active Band Class: 'nr5g-41'   ARFCN 501390 (2506.95 MHz)
PLMN: '310026'  ->  MCC 310 / MNC 260 = T-Mobile
RSRP: -94.7 dBm
registration: idle
network rejection operator name: Google Fi
```

So EN-DC is not a misconfiguration, it is the fallback after SA is refused.

**Swapping the SIM proves the cause is the subscription.** Same laptop, same
modem, same location, same Fi account, same n41 band — only the subscription
differs:

| | data-only eSIM | voice+data nano SIM |
| --- | --- | --- |
| Radio interfaces | `lte, 5gnr` (EN-DC) | `5gnr` only (**SA**) |
| Serving carrier | LTE B66 @ 10 MHz + n41 | n41 @ **100 MHz** (`5gnr-100`) |
| RSRP / SNR | -98 dBm / 12.4 dB | -100 dBm / 13.0 dB |
| Throughput, 8 streams | 217 Mbps | **352 Mbps** |
| Latency | 42 ms | 33 ms |
| Bearer | dual-stack IPv4 + IPv6 | IPv6-only + 464XLAT (`192.0.0.2`) |

1.6x the throughput at marginally *worse* signal. The mechanism is visible in
the band data: SA gives one 100 MHz NR carrier, where EN-DC was anchored on a
10 MHz LTE carrier. The data-only line is evidently not provisioned for 5GS/N1
mode. To get SA on this machine, use a voice+data line.

A Pixel 9 Pro XL on the voice+data SIM registers `NR_SA` on n41 in the same
place, which is what first suggested the subscription rather than the hardware.

Google Fi support confirmed the conclusion (2026-08-05): data-only SIMs
"operate on a profile that is provisioned exclusively for NSA (Non-Standalone)
mode via EN-DC" and "do not currently carry SA core network registration
rights". The rejection is intended behavior, not a provisioning fault worth
escalating.

## Signal is not the limiting factor

Comparing the laptop on EN-DC against the phone on SA:

| | Laptop (EN-DC) | Phone (SA) |
| --- | --- | --- |
| RSRP | LTE -98 / NR -95 dBm | NR (SSB) -101 dBm |
| RSRQ | -11 / -12 dB | -11 dB |
| SNR / SINR | 12.4 / 9.0 dB | 10 dB |

The laptop reads *better* RSRP than the phone with identical RSRQ. The lid
antennas and the T99W696 are not the weak link. Note these are not strictly
comparable — different cells, different reference signals (LTE CRS vs NR SSB) —
so read it as "both are in the same -95..-101 range".

The phone's `csiRsrp`/`csiRsrq` report floor values (-140 / -20) because CSI-RS
is not being measured; `ssRsrp`/`ssRsrq` are the valid figures.

## Suspend can leave cellular blocked from autoconnect

NetworkManager (1.54.3) tears the modem down for sleep with the deactivation
reason `user-requested`, where Wi-Fi and Ethernet get `sleeping`:

```
device (enp195s0f0): state change: activated -> deactivating (reason 'sleeping', ...)
device (wwan0mbim0): state change: activated -> disconnected (reason 'user-requested', ...)
```

A user-requested disconnect is the same reason the Mobile quick-settings tile
produces, and that reason class is what blocks a profile from autoconnecting.
After some suspends the block is still standing on resume: the modem
re-enumerates and registers, and the profile then sits disconnected
indefinitely, because nothing on the resume path clears the block or retries.
Clicking Mobile connects immediately; after the next suspend the profile was
blocked again.

Not every suspend arms it. Cycles where the connection had last been activated
by NetworkManager's own policy autoconnected by themselves ~18 s after resume,
and a plain `nmcli connection down`/`up` before sleeping did not arm it
either; the standing block followed activations made from the quick settings
menu. The discriminating experiment on a blocked profile: a no-op
`nmcli connection modify` — profile updates reset autoconnect blocks — made
policy activate it within milliseconds, where toggling the device's
autoconnect flag did nothing.

`resume-reconnect/` works around it without needing the exact arming
conditions: after every resume it waits out the modem re-probe and
re-activates any autoconnect-enabled cellular profile still down; when
NetworkManager autoconnects by itself, it sees that and exits without acting.

Separately, the Mobile tile is absent for ~20 s after every resume: suspend
kills the in-flight MBIM transactions, so ModemManager declares the modem gone
and re-probes it from scratch, under a new index. Resume to connected measured
18–21 s. Twenty s2idle suspend cycles on BIOS 1.06 (R38ET26W), from seconds to
40 minutes with the modem active, produced no hang.

## ModemManager never exits if a modem is probed while it is shutting down

Stopping the daemon with a modem connected hangs it until systemd's stop
timeout expires and kills it, so every reboot is delayed by that whole timeout.
`systemctl stop ModemManager` reproduces it every time; no reboot needed.

Disabling the connected modem kills the in-flight MBIM transactions, so the
port stops being controllable and a fresh modem is probed mid-teardown — the
same re-probe suspend causes, above:

```
<msg> [modem0] state changed (connected -> disabling)
<msg> [modem0] port 'wwan0mbim0' no longer controllable, reprobing
<wrn> [/dev/wwan0mbim0] MBIM error: Device must be open to send commands
<msg> [device ...] creating modem with plugin 'foxconn' and '4' ports
<wrn> shutdown failed: timeout waiting for sleep preparation to complete
```

`main()` bounds that teardown with a one-shot `MMSleepContext`, but its wait
loop re-checks `mm_base_manager_num_modems()` after the timeout has fired and
cleaned up its own source. The modem probed during shutdown holds that count
above zero, so the loop re-enters `g_main_loop_run()` with nothing left that
can ever quit it. The `disabling modems took too long` warning immediately
past the loop is unreachable for the same reason, though it is exactly the
path the timeout was written to take.

`patches/` carries the fix — latch the expiry and test it in the loop
condition. A daemon built with it exits by itself in ~21 s and prints that
warning. `shutdown-hang/` ships a 10 s cap on the stop timeout instead, which
is both simpler and faster: by the time the cap expires the daemon has already
abandoned its teardown, and the modem is reset by the reboot anyway. Running
the patched daemon would mean shadowing a package-managed binary that needs
rebuilding against every libmbim and libqmi update.

Nothing here is specific to this modem — any modem that re-probes during
teardown should reach the same loop.

## A 4G-configured T16 Gen 5 has two WWAN antennas; the 5G kit is a separate FRU

Lenovo's maintenance manual for this chassis (SG10856, "ThinkPad T14 Gen 7,
T16 Gen 5, P14s Gen 7 AMD") documents four WWAN antenna positions — main,
auxiliary, MIMO1, MIMO2 — "for selected models", with separate 4G and 5G
illustrations for both the antenna and the card procedures, and the self-repair
catalog for machine types 21WX/21WY lists "4G wireless WAN antennas" and "5G
wireless WAN antennas" as distinct items. On the Gen 3 chassis iFixit's teardown
counts two cables for LTE and four for 5G; the Gen 5 keeps that split. A laptop
ordered with the Snapdragon X12 4G option therefore carries two antennas, not
four.

Lenovo's parts lookup against this machine's serial (a 5G build) returns the
antenna kit as **FRU 5A30Z88318, "ANTENNA ACCY KITS NT060 WW5G ANT"**
(commodity ANTENNA). The 14-inch sibling, 5A30Z88317 "NT040 WWAN 5G", is the
T14 Gen 7 / P14s Gen 7 kit and does not fit. Replacing the antennas means
removing the base cover, battery and speaker assembly; the kit is held by two
M2.0 × 3.5 mm screws and the cables connect to the module by color label (on
the Gen 3 chassis: orange main, blue auxiliary, white/gray MIMO1, black/gray
MIMO2 — confirm against the module's own labels). The 4G card is M.2 3042 on a
bracket in a 3052 slot; a 5G card (this T99W696, or a Quectel RM520N-GL) is
3052 and uses the 5G bracket.

What two cables cost an RM520N-GL, from Quectel's RM520N hardware design
(antenna interface table): ANT0 carries the low/mid-band primary path and n41
TX0/PRX; ANT1 the mid/ultra-high-band RX MIMO; ANT2 the n77/n78 TX0/PRX and
n41 TX1/DRX MIMO; ANT3 the low-band diversity, n41 DRX and n77 DRX MIMO. With
only ANT0 and ANT3 populated, LTE, n71 and n41 run at two layers (no 4×4
MIMO) and n77/n78 have no primary path at all.

As of 2026-10-06 the US configurator offered the T16 Gen 5 (AMD and Intel)
only with "No Wireless WAN" or the X12 4G modem, while PSREF of the same date
still listed the X61 5G and a "5G antenna ready" option — a storefront
decision, not a platform one. The only US-orderable 5G ThinkPads were the P14s
Gen 7 AMD and one X1 2-in-1 Gen 11 bundle, both with the X61, i.e. this same
T99W696. Lenovo's "Enabling WWAN on Linux" table marks every 2024–2026 module,
including the Quectel RM520N-GL on the T16 Gen 4 / T14 Gen 6, "Not available
for USA SIM", so a Lenovo-branded RM520N-GL is no better off on Linux than the
T99W696. A retail RM520N-GL carries no FCC lock; whether the BIOS whitelist
accepts one is untested.

## Measurement traps

Both of these produced confidently wrong conclusions before being caught.

**A single stream to a distant server measures the path, not the link.** A lone
HTTP/1.0 stream against `speedtest.tele2.net` read ~3 Mbps and looked exactly
like a carrier throttle. That server is 164 ms away versus 42 ms locally; the
result is bandwidth-delay-product limited. Eight parallel streams to a nearby
server on the same link gave 217 Mbps. Always use parallel streams to a near
server, and state which server a number came from.

**qmicli's legacy EARFCN field is 16-bit and wraps.** `nas-get-cell-location-info`
reported `EUTRA Absolute RF Channel Number: '951' (E-UTRA band 2: 1900 PCS)`
while `nas-get-rf-band-info` reported `eutran-66` channel `66487`. 66487 - 65536
= 951: the legacy field overflowed and qmicli mislabelled the band from the
truncated value. The extended field is authoritative.

## Incidental notes

The BIOS changelog for this machine (0.1.06) includes "Fix the linux system will
hung sometimes when into S3 (Environment: 5G WWAN + Linux System)" and "Fix the
eSIM erase procedure will be triggered unexpectedly when executes the Wipe BIOS
Data". Both are worth having before relying on suspend or touching BIOS data
recovery with a provisioned eSIM.

`fwupd` enumerates the modem as `T99W696` but offers no firmware for it, so the
old carrier config cannot be refreshed that way.
