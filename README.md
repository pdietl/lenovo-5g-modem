# lenovo-5g-modem

Getting the Foxconn T99W696 5G modem in a ThinkPad T16 Gen 5 working on Linux,
and understanding what it does once it works.

Hardware: Foxconn T99W696 (Qualcomm SDX62), PCI `17cb:0308`, MBIM over PCIe/MHI.
Carrier: Google Fi. Verified on Ubuntu 26.04, kernel 7.0, ModemManager 1.25.95.

## The two things that matter

**1. The modem is FCC-locked, and Lenovo's unlock tool deliberately refuses to
unlock it on a US SIM.** The radio never powers up, so the modem is invisible to
the network. Lenovo state this is a business decision — they did not pursue US
carrier certification for Linux — not a hardware limitation. Windows is
unaffected because its driver has no such check. `fcc-unlock/` replaces the
policy check while keeping Lenovo's own unlock code.

**2. A Google Fi data-only eSIM cannot register 5G standalone; a voice+data line
can.** With a data-only eSIM the modem is limited to EN-DC (an LTE anchor with a
5G secondary carrier). Swap in a voice+data SIM and the same modem, in the same
place, registers 5G SA on a 100 MHz carrier and roughly doubles its throughput.
There is nothing to fix locally for this. See [docs/FINDINGS.md](docs/FINDINGS.md).

## Contents

| Path | What it is |
| --- | --- |
| [`fcc-unlock/`](fcc-unlock/) | FCC unlock tool, ModemManager hook, and installer. **Required** for the modem to work at all. |
| [`gnome-extension/`](gnome-extension/) | GNOME Shell indicator showing cellular signal and access technology (`LTE` / `5G` / `5G SA`), which the built-in indicator does not. |
| [`patches/`](patches/) | `qmicli` patch adding NR5G SA/NSA band preference setters. Needed to pin the modem to a single 5G band. |
| [`routing/`](routing/) | Fallback routing policy and installer: cellular stays connected but loses to any working link, per address family. |
| [`docs/FINDINGS.md`](docs/FINDINGS.md) | Why the modem behaves as it does, with the measurements behind each claim. |
| [`docs/fcc-unlock-protocol.md`](docs/fcc-unlock-protocol.md) | The unlock protocol, for replacing the vendor blob with pure `qmicli`. |
| [`docs/diagnostics.md`](docs/diagnostics.md) | Command cookbook, and the measurement traps worth avoiding. |
| [`docs/references.md`](docs/references.md) | The sources that led to the solution, and what each one contributed. |

## Quick start

```sh
cd fcc-unlock && sudo ./install.sh
```

That builds the unlock helper, installs it, and installs the ModemManager hook
that runs it whenever the modem powers on. The unlock is volatile and must be
redone on every modem power-on, which is what the hook is for.

Then create a connection. Google Fi's APN is `h2g2`:

```sh
nmcli connection add type gsm ifname '*' con-name 'Google Fi' gsm.apn h2g2
```

`ifname '*'` and leaving `gsm.sim-id` unset matter: NetworkManager otherwise pins
the profile to the ICCID it first activated on and then silently refuses the
other SIM after a slot switch.

Then apply the routing policy, which keeps cellular connected as a fallback
that only carries traffic when nothing else works:

```sh
cd routing && sudo ./install.sh
```

## Status

Working: FCC unlock at boot and across modem power cycles, LTE and 5G data,
IPv4 and IPv6, 5G SA on a voice+data SIM.

Not solved, and not solvable here: 5G SA on a data-only eSIM. The network
rejects the registration, and Google Fi support confirms data-only profiles
are provisioned NSA-only, with no 5GS/N1 registration rights, by design.
