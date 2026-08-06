# Diagnostics cookbook

`DEV=/dev/wwan0mbim0` throughout. `qmicli` needs `--device-open-proxy` so it
shares the MBIM channel with ModemManager instead of fighting it.

## State at a glance

```sh
mmcli -L                       # modem index; it changes on every re-enumeration
mmcli -m any                   # state, power state, access tech, operator, signal
rfkill list                    # hardware/software kill switches
```

`state: registered` with `power state: low` and `Cannot power-up: sotware radio
switch is OFF` in the journal means the FCC unlock did not run or failed.

Note `mmcli -m any` follows re-enumeration; a hardcoded index will not. The modem
gets a new index on every power cycle, SIM slot switch and resume.

## Is it FCC-locked?

```sh
mbimcli -p -d $DEV --query-radio-state          # 'Software radio state: off' => locked
sudo /usr/local/sbin/foxconn-fcc-unlock         # reports the state before acting
```

## Radio detail

```sh
sudo qmicli --device-open-proxy -d $DEV --nas-get-signal-info      # RSRP/RSRQ/SNR per RAT
sudo qmicli --device-open-proxy -d $DEV --nas-get-rf-band-info     # serving band + bandwidth
sudo qmicli --device-open-proxy -d $DEV --nas-get-serving-system   # which RATs are actually serving
sudo qmicli --device-open-proxy -d $DEV --nas-get-cell-location-info
sudo qmicli --device-open-proxy -d $DEV --nas-get-endc-config
sudo qmicli --device-open-proxy -d $DEV --nas-get-system-selection-preference
```

`nas-get-serving-system` is the reliable SA/EN-DC test. `Radio interfaces: '1'`
with `[0]: '5gnr'` is standalone; `lte` present alongside means EN-DC.

**Read band numbers from `nas-get-rf-band-info`, not from
`nas-get-cell-location-info`.** The latter's EARFCN field is 16-bit and wraps, so
qmicli derives the wrong band from it (66487 shows as 951, labelled band 2
instead of band 66).

### NR-ARFCN to frequency

For ARFCN below 600000, `f_MHz = arfcn * 0.005`. So 501390 is 2506.95 MHz and
521310 is 2606.55 MHz — both n41 (2496–2690 MHz).

## Forcing a RAT

```sh
mmcli -m any --set-allowed-modes=5g                       # SA only: no LTE anchor possible
mmcli -m any --set-allowed-modes='3g|4g|5g' --set-preferred-mode=5g
```

With the patch in `patches/`, pin the SA bands so the modem cannot wander onto
another operator's 5G band while searching:

```sh
qmicli --device-open-proxy -d $DEV --nas-set-nr5g-sa-band-preference=n41
qmicli --device-open-proxy -d $DEV --nas-set-system-selection-preference=5gnr
```

Restoring afterwards, this modem's stock values:

```sh
qmicli --device-open-proxy -d $DEV --nas-set-system-selection-preference='5gnr|lte|umts'
qmicli --device-open-proxy -d $DEV \
    --nas-set-nr5g-sa-band-preference=1,2,3,5,7,8,13,14,18,20,25,26,28,29,30,38,40,41,48,66,71,77,78,79
```

**Token order in `--nas-set-system-selection-preference` sets the acquisition
order**, not just the mode bitmask. Restoring with `umts|lte|5gnr` silently
deprioritises 5G; the stock order here is `5gnr, lte, umts`. Verify with
`--nas-get-system-selection-preference` afterwards, every time.

## SIM slots

Slot 1 is the physical tray, slot 2 the eUICC.

```sh
mmcli -m any | grep -A3 'sim slot'
mmcli -m any --set-primary-sim-slot=1
mmcli -i <N>                                  # per-SIM: IMSI, ICCID, EID
```

A slot switch power-cycles the modem, so the FCC unlock hook runs again and the
modem re-enumerates with a new index.

NetworkManager pins a GSM profile to the ICCID it first activated on. After a
slot switch the profile then refuses the new SIM with "device has differing
sim-id than GSM profile". Clear it so one profile serves both:

```sh
nmcli connection modify 'Google Fi' gsm.sim-id ''
```

## Carrier configs

```sh
sudo qmicli --device-open-proxy -d $DEV --pdc-list-configs=software
```

25 configs are present; only `T-mobile` (`0xA010502`) and `ATT` are US ones, and
`fwupd` offers no modem firmware, so there is nothing newer to activate.

## Throughput, without fooling yourself

Use parallel streams to a nearby server. A single stream to a distant one
measures round-trip time, not the link:

```sh
python3 - <<'EOF'
import time, subprocess, concurrent.futures
URL = "https://speed.cloudflare.com/__down?bytes=50000000"
def one(_):
    r = subprocess.run(["curl", "-s", "--interface", "wwan0", "--max-time", "45",
                        "-o", "/dev/null", "-w", "%{size_download}", URL],
                       capture_output=True, text=True)
    return int(r.stdout or 0)
t0 = time.time()
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
    total = sum(ex.map(one, range(8)))
dt = time.time() - t0
print(f"{total*8/dt/1e6:.1f} Mbps")
EOF
```

Bind explicitly with `curl --interface wwan0` or `ping -I wwan0` to test
cellular while another link is up: the routing policy below keeps it off the
default path whenever anything else works.

## Routing policy: cellular stays up, carries traffic last

The `Google Fi` profile autoconnects and stays connected; route metrics decide
what actually carries traffic. `routing/install.sh` applies everything in this
section.

- **IPv4 metric 1050.** Loses to Ethernet (~100) and Wi-Fi (600). When
  NetworkManager's connectivity check fails on a link it penalises that link's
  default route by +20000, so a captive portal or dead uplink fails over to
  cellular by itself.
- **IPv6 metric 30000.** Loses even to a *penalised* link. A v4-only Wi-Fi
  (RAs but no global prefix) fails the v6 connectivity check, and with cellular
  at the stock 1050 the v6 default then flips to `wwan0` — sending most
  dual-stack traffic over metered cellular while Wi-Fi carries only IPv4.

On a v4-only network the machine therefore has no IPv6 at all: dual-stack
applications drop to IPv4 with no visible stall, but an explicit `curl -6`
times out rather than failing fast.

`/etc/sysctl.d/90-ipv6-oif-source-only.conf` sets
`net.ipv6.conf.*.use_oif_addrs_only=1`, pinning IPv6 source selection to the
outgoing interface. Without it the kernel borrows the cellular interface's
global address as source for the Wi-Fi route, and replies can arrive back over
cellular — an asymmetric path that keeps using metered data invisibly. The
kernel consults only the outgoing interface's own flag (`conf.all` is ignored
for this knob), which is why the file uses a glob: systemd's udev rule
re-applies it to each interface as it appears.

## After suspend

Resume kills the in-flight MBIM transactions, so ModemManager re-probes the
modem from scratch: the Mobile tile disappears for ~20 s and the modem comes
back under a new index. Reconnection is then either NetworkManager's own
autoconnect or, when the profile came out of the suspend autoconnect-blocked
(see FINDINGS), the `wwan-resume-reconnect` unit:

```sh
journalctl -b -u wwan-resume-reconnect.service
```

An 18–21 s gap from `PM: suspend exit` to connected is normal.

## Comparing against an Android phone

```sh
adb shell dumpsys telephony.registry | grep -oE 'mSignalStrength=[^,]*(,m[A-Za-z]*=[^,]*)*'
adb shell dumpsys telephony.registry | grep mServiceState
adb shell getprop gsm.network.type          # e.g. NR_SA
```

`mBands`, `mNrArfcn` and `getRilDataRadioTechnology` in `mServiceState` give the
band and whether it is SA. Check `cmd wifi status` for "Wifi is not connected"
before trusting any throughput number as cellular — Wi-Fi being *enabled* does
not mean it is carrying traffic.
