/*
 * foxconn-fcc-relock — TEST TOOL. Re-engages the FCC lock on the Foxconn
 * T99W696 so the automatic unlock path can be verified without a cold boot.
 *
 * Reimplements FoxApSetFccLockStatus(1) (a local symbol in the vendor SDK)
 * on top of the SDK's exported QMI transport:
 *
 *   token   = salt(4 random) + md5hex(mcfg_stripped + apps + imei + salt + "FDE2")
 *   payload = 01 24 00 <token:36> 02 01 00 <mode>      (43 bytes)
 *   mode    = 48 -> unlock, 49 -> lock
 *   sent as QMI service 0xE4, message 0x5571 via QMIFOXAPSetFccLockStatus()
 *
 * Not installed; recovery is /usr/local/sbin/foxconn-fcc-unlock.
 *
 * Build: cc -O2 -o foxconn-fcc-relock foxconn-fcc-relock.c -ldl
 * Usage: foxconn-fcc-relock <mcfg-stripped> <apps> <imei> <48|49>
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#define SDK "/opt/fcc_lenovo/lib/libfiisdk.so.2.2.2"
/* the SDK's own salt alphabet: a-z then each digit twice, 46 chars */
#define ALPHABET "abcdefghijklmnopqrstuvwxyz00112233445566778899"

int main(int argc, char **argv)
{
    if (argc != 5) {
        fprintf(stderr, "usage: %s <mcfg-stripped> <apps> <imei> <48|49>\n", argv[0]);
        return 1;
    }
    const char *fw = argv[1], *apps = argv[2], *imei = argv[3];
    int mode = atoi(argv[4]);
    if (mode != 48 && mode != 49) {
        fprintf(stderr, "mode must be 48 (unlock) or 49 (lock)\n");
        return 1;
    }

    void *h = dlopen(SDK, RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }

    int  (*device_connect)(const char *)                        = dlsym(h, "DeviceConnect");
    int  (*device_disconnect)(void)                             = dlsym(h, "DeviceDisConnect");
    void (*md5hex)(const char *, int, char *)                   = dlsym(h, "Compute_string_md5");
    int  (*ap_set)(void *, uint16_t, void *, uint16_t *)        = dlsym(h, "QMIFOXAPSetFccLockStatus");
    if (!device_connect || !device_disconnect || !md5hex || !ap_set) {
        fprintf(stderr, "dlsym: %s\n", dlerror()); return 1;
    }

    char salt[5];
    srand((unsigned)time(NULL));
    for (int i = 0; i < 4; i++)
        salt[i] = ALPHABET[rand() % (int)(sizeof(ALPHABET) - 1)];
    salt[4] = '\0';

    char in[512], hex[64], token[64];
    snprintf(in, sizeof in, "%s%s%s%s%s", fw, apps, imei, salt, "FDE2");
    memset(hex, 0, sizeof hex);
    md5hex(in, (int)strlen(in), hex);
    snprintf(token, sizeof token, "%s%s", salt, hex);
    if (strlen(token) != 36) {
        fprintf(stderr, "unexpected token length %zu (%s)\n", strlen(token), token);
        return 1;
    }

    unsigned char p[43];
    memset(p, 0, sizeof p);
    p[0] = 0x01; p[1] = 36; p[2] = 0x00;      /* TLV 0x01, len 36 */
    memcpy(p + 3, token, 36);
    p[39] = 0x02; p[40] = 0x01; p[41] = 0x00; /* TLV 0x02, len 1  */
    p[42] = (unsigned char)mode;

    int rc = device_connect("/dev/wwan0mbim0");
    if (rc != 0) { fprintf(stderr, "DeviceConnect failed: %d\n", rc); return 2; }

    unsigned char resp[1024];
    uint16_t resplen = 0;
    memset(resp, 0, sizeof resp);
    rc = ap_set(p, (uint16_t)sizeof p, resp, &resplen);
    device_disconnect();

    printf("mode=%d salt=%s token=%s -> rc=%d resplen=%u\n",
           mode, salt, token, rc, resplen);
    return rc == 0 ? 0 : 3;
}
