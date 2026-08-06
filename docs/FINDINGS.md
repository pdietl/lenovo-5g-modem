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
