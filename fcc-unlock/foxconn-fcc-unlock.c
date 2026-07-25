/*
 * foxconn-fcc-unlock — FCC-unlock the Foxconn T99W696 (Qualcomm SDX62, PCI 17cb:0308)
 *
 * Lenovo ships the unlock capability in /opt/fcc_lenovo:
 *   DPR_Fcc_unlock_service  — thin wrapper, refuses to run when it sees a US SIM
 *                             ("This is a US SIM card." -> "FCC unlock failed").
 *                             Lenovo confirmed this is a business decision, not a
 *                             technical one: they did not pursue US carrier
 *                             certification for Linux.
 *                             (lenovo/lenovo-wwan-unlock issue #88)
 *   lib/libfiisdk.so.2.2.2  — the actual Foxconn SDK that performs the unlock.
 *                             Contains no SIM/country logic whatsoever.
 *
 * This program calls the SDK entry point that the Lenovo wrapper itself uses
 * (Fox_Attempt), so the unlock is performed by unmodified vendor code:
 *
 *   Fox_Attempt()
 *     -> FoxApGetFccLockStatus()          QMI service 0xE4, msg 0x5570
 *     -> FoxApSetFccLockStatus(0)         QMI service 0xE4, msg 0x5571
 *          TLV 0x01 = 36-byte token: 4-char salt + md5hex(
 *                       mcfg_version_minus_last_two_components
 *                       + apps_version + IMEI + salt + "FDE2")
 *          TLV 0x02 = 1 byte, 48
 *     -> CheckOperatingMode()
 *
 * Requires ModemManager to be running (the SDK reaches the modem through it).
 * The unlock is volatile: it must be redone every time the modem powers on.
 *
 * Build: cc -O2 -o foxconn-fcc-unlock foxconn-fcc-unlock.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

#define SDK "/opt/fcc_lenovo/lib/libfiisdk.so.2.2.2"

int main(int argc, char **argv)
{
    const char *dev = "/dev/wwan0mbim0";
    void *h;
    int (*device_connect)(const char *);
    int (*fox_attempt)(void);
    int (*device_disconnect)(void);
    int rc, ok;

    /* ModemManager passes: <script> <dbus-path> <port> [<port>...].
     * Pick the MBIM port if we were called that way; otherwise accept a
     * bare device path, or fall back to the default. */
    for (int i = 1; i < argc; i++) {
        if (!strncmp(argv[i], "/dev/", 5)) {
            dev = argv[i];
        } else if (strcasestr(argv[i], "mbim")) {
            static char buf[64];
            snprintf(buf, sizeof buf, "/dev/%s", argv[i]);
            dev = buf;
        }
    }

    h = dlopen(SDK, RTLD_NOW);
    if (!h) {
        fprintf(stderr, "foxconn-fcc-unlock: dlopen %s: %s\n", SDK, dlerror());
        return 1;
    }

    device_connect    = dlsym(h, "DeviceConnect");
    fox_attempt       = dlsym(h, "Fox_Attempt");
    device_disconnect = dlsym(h, "DeviceDisConnect");
    if (!device_connect || !fox_attempt || !device_disconnect) {
        fprintf(stderr, "foxconn-fcc-unlock: missing SDK symbol: %s\n", dlerror());
        return 1;
    }

    rc = device_connect(dev);
    if (rc != 0) {
        fprintf(stderr, "foxconn-fcc-unlock: DeviceConnect(%s) failed: %d "
                        "(is ModemManager running?)\n", dev, rc);
        return 2;
    }

    ok = fox_attempt();
    device_disconnect();

    if (!ok) {
        fprintf(stderr, "foxconn-fcc-unlock: FCC unlock failed\n");
        return 3;
    }
    printf("foxconn-fcc-unlock: FCC unlock succeeded on %s\n", dev);
    return 0;
}
