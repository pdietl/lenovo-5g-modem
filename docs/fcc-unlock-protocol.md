# Foxconn T99W696 FCC unlock protocol

Recovered from `/opt/fcc_lenovo/lib/libfiisdk.so.2.2.2` (Foxconn's SDK, shipped
by Lenovo) for interoperability, so the unlock can eventually be done with
`qmicli` alone instead of dlopening a vendor blob.

Published SDX62 write-ups do not work on this modem. They use magic `FDE1` on
QMI service `0xE3`; this modem wants magic `FDE2` on service **`0xE4`**. Sending
`0x5571` to `0xE3` returns `MalformedMessage`, and the DMS path used by SDX55
returns `WmsInvalidMessageId`.

## Transport

| | |
| --- | --- |
| QMI service | **`0xE4`** |
| Message ID | `0x5571` (set lock status); `0x5570` reads it |
| Carried over | QMI-over-MBIM on `/dev/wwan0mbim0`, via ModemManager's proxy |

From `QMIFOXAPSetFccLockStatus`, which loads `$0xe4` and `$0x5571` before
calling the SDK's `SendMessage`. The sibling `QMIFOXSetFccLockStatus` uses
service `0xE3` with the same message ID and is *not* the one the unlock path
calls.

## Payload

43 bytes, two TLVs:

```
offset  bytes              meaning
0       01                 TLV type 1
1..2    24 00              length 36, little endian
3..38   <36 ASCII chars>   token: 4-char salt + 32-char lowercase md5 hex
39      02                 TLV type 2
40..41  01 00              length 1
42      30 | 31            0x30 (48) = unlock, 0x31 (49) = lock
```

## Token

```
token = salt + md5_hex(fw_version + apps_version + imei + salt + "FDE2")
```

- `fw_version` — the `firmware-mcfg` version with its **last two** dot-separated
  components removed. `FDE.F0.3.2.0.3.TO.002` becomes `FDE.F0.3.2.0.3`.
- `apps_version` — the `apps` version, e.g. `020`.
- `imei` — 15 digits.
- `salt` — 4 characters drawn from the SDK's own 46-character alphabet,
  `abcdefghijklmnopqrstuvwxyz00112233445566778899` (each digit appears twice,
  hence `rand() % 46`).

Read the versions with:

```sh
qmicli -d /dev/wwan0mbim0 --device-open-proxy --fox-get-firmware-version=firmware-mcfg
qmicli -d /dev/wwan0mbim0 --device-open-proxy --fox-get-firmware-version=apps
qmicli -d /dev/wwan0mbim0 --device-open-proxy --dms-get-ids
```

## The magic value is obfuscated

`FDE2` never appears as a string in the SDK, which is why searching for it finds
nothing. It is built a byte at a time as `"ighU"` and then passed through
`b_char_value()`, which is `c == 0 ? 0 : c - 0x23`:

```
'i' 0x69 - 0x23 = 0x46 'F'
'g' 0x67 - 0x23 = 0x44 'D'
'h' 0x68 - 0x23 = 0x45 'E'
'U' 0x55 - 0x23 = 0x32 '2'
```

## Vendor entry points

Exported from `libfiisdk.so.2.2.2` and usable directly, which is what
`fcc-unlock/foxconn-fcc-unlock.c` does:

| Symbol | Purpose |
| --- | --- |
| `DeviceConnect(const char *dev)` | Opens the MBIM device; returns 0 on success |
| `Fox_Attempt(void)` | Reads lock status and unlocks if locked; returns 1 on success |
| `DeviceDisConnect(void)` | Tears down |
| `QMIFOXAPSetFccLockStatus(void *buf, uint16_t len, void *resp, uint16_t *resplen)` | Raw sender, for the lock direction |
| `Compute_string_md5(const char *in, int len, char *out_hex)` | The SDK's own md5 |

`Fox_Attempt` prints its own progress: `Start to Unlock FCC Lock` then
`Unlocking FCC Lock Completed`, or `You has been unlock Fcc Lock, not need to
unlock` when already unlocked. `FoxApSetFccLockStatus`, the function that builds
the payload, is a local symbol and not reachable via `dlsym`.

ModemManager must be running, because the SDK reaches the modem through its
MBIM proxy.

## Replacing the blob

`qmicli` cannot do this yet: libqmi knows service `0xE3` (`--fox-set-fcc-authentication`)
but has no `0xE4`. Adding a `0xE4` service definition with message `0x5571`
carrying the two TLVs above, plus a `--fox-ap-set-fcc-authentication` option,
would make the vendor blob unnecessary.

Until then, note the tokens are single-use in practice: the salt is random per
attempt so a captured token cannot be replayed usefully, and nothing about the
scheme needs to be kept secret for the unlock to work.
