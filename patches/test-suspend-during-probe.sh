#!/bin/bash
# Reproduce, without suspending, the race the ModemManager patches here fix:
# run a ModemManager binary on a private bus beside a mocked logind, send it
# PrepareForSleep(true) while the modem is still initializing, and
# PrepareForSleep(false) once sleep preparation has timed out. The modem must
# come back, and the daemon must log no GLib criticals.
#
# usage: sudo ./test-suspend-during-probe.sh <ModemManager> <new dir> [race|settled]
#
# "settled" checks the normal case instead: sleep only once the modem has
# finished initializing, so the cleanup completes before the resume and the
# rescan must run at once rather than be deferred.
#
# Stop the system ModemManager first (cellular drops) and start it again
# afterwards. Exit 0 = pass, 1 = fail, 2 = the run did not exercise its case
# and proves nothing, 3 = harness failure.

MM=$1
OUT=$2
MODE=${3:-race}
case $MODE in race|settled) ;; *) echo "mode must be race or settled" >&2; exit 3 ;; esac

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 3; }
[ -x "$MM" ] || { echo "not executable: $MM" >&2; exit 3; }
systemctl is-active --quiet ModemManager.service &&
    { echo "system ModemManager is running; stop it first" >&2; exit 3; }
mkdir "$OUT" || { echo "output dir must be new: $OUT" >&2; exit 3; }

LOG=$OUT/mm.log
PIDS=()
# Stop in reverse start order: ModemManager before the bus it is on, or its
# shutdown trips over the bus vanishing underneath it.
cleanup() {
    local i p
    for (( i = ${#PIDS[@]} - 1; i >= 0; i-- )); do
        p=${PIDS[i]}
        kill "$p" 2>/dev/null || continue
        timeout 15 tail --pid="$p" -f /dev/null
        kill -9 "$p" 2>/dev/null
    done
}
trap cleanup EXIT

BUSNAME=mm-suspend-during-probe-$$
cat > "$OUT/bus.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>system</type>
  <listen>unix:abstract=$BUSNAME</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow user="*"/>
    <allow own="*"/>
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
  </policy>
</busconfig>
EOF

dbus-daemon --config-file="$OUT/bus.conf" --nofork --nopidfile \
    > "$OUT/bus.log" 2>&1 &
PIDS+=($!)
export DBUS_SYSTEM_BUS_ADDRESS=unix:abstract=$BUSNAME
bus_up() {
    gdbus call --system -d org.freedesktop.DBus -o /org/freedesktop/DBus \
        -m org.freedesktop.DBus.GetId > /dev/null 2>&1
}
for _ in 1 2 3 4 5 6 7 8 9 10; do
    bus_up && break
    sleep 0.5
done
bus_up || { echo "private bus did not start" >&2; cat "$OUT/bus.log" >&2; exit 3; }

python3 -I -m dbusmock --system --template logind \
    > "$OUT/logind.log" 2>&1 &
PIDS+=($!)
gdbus wait --system --timeout 10 org.freedesktop.login1 ||
    { echo "mock logind did not appear" >&2; exit 3; }

# Wait for a regex to appear in the log after byte offset $1, up to $2 s.
wait_log() {
    timeout "$2" tail -c "+$(( $1 + 1 ))" -F "$LOG" 2>/dev/null |
        grep -m1 -E "$3"
}
emit_sleep() {
    gdbus call --system -d org.freedesktop.login1 \
        -o /org/freedesktop/login1 \
        -m org.freedesktop.DBus.Mock.EmitSignal \
        org.freedesktop.login1.Manager PrepareForSleep b "[<$1>]" \
        > /dev/null
}

: > "$LOG"
"$MM" --test-low-power-suspend-resume --log-level=DEBUG --log-timestamps \
    --log-file="$LOG" > "$OUT/stderr.log" 2>&1 &
PIDS+=($!)

if [ "$MODE" = settled ]; then
    wait_log 0 90 'state changed \(unknown -> disabled\)' > /dev/null ||
        { echo "modem never finished initializing" >&2; exit 3; }
    echo "modem initialized; sending PrepareForSleep(true)"
else
    wait_log 0 90 'MBIM device is QMI capable' > /dev/null ||
        { echo "modem setup never started" >&2; exit 3; }
    echo "setup started; sending PrepareForSleep(true)"
fi
emit_sleep true || { echo "emit failed" >&2; exit 3; }

wait_log 0 15 'ready to sleep; dropping inhibitor' > /dev/null ||
    { echo "sleep preparation never finished" >&2; exit 3; }

RESUME_AT=$(stat -c %s "$LOG")
echo "sleep context released; sending PrepareForSleep(false)"
emit_sleep false || { echo "emit failed" >&2; exit 3; }

if [ "$MODE" = settled ]; then
    if grep -q 'sleep context failed' "$LOG"; then
        echo "RESULT: sleep preparation timed out; a settled run proves nothing"
        exit 2
    fi
# The race only exists if the device removal lands after the resume.
elif ! wait_log "$RESUME_AT" 60 'removing modem[0-9]' > /dev/null; then
    echo "RESULT: race not exercised (no device removal after resume)"
    exit 2
fi
[ "$MODE" = race ] && echo "device removal landed after resume: race exercised"

if ! wait_log "$RESUME_AT" 60 'creating modem with plugin' > /dev/null; then
    echo "RESULT: no modem probed within 60 s of the resume"
    mmcli -L | tee "$OUT/mmcli-L.txt"
    exit 1
fi
# The old modem logs its own "unknown -> disabled" after the resume, so only
# look past the point where the new one was created.
CREATED_AT=$(stat -c %s "$LOG")
wait_log "$CREATED_AT" 60 'state changed \(unknown -> disabled\)' > /dev/null
mmcli -L | tee "$OUT/mmcli-L.txt"
if [ "$MODE" = settled ] &&
    tail -c "+$(( RESUME_AT + 1 ))" "$LOG" | grep -q 'deferring .* device scan'; then
    echo "RESULT: scan deferred although the cleanup had completed"
    exit 1
fi
if grep -q CRITICAL "$OUT/stderr.log"; then
    echo "RESULT: GLib criticals on stderr"
    grep CRITICAL "$OUT/stderr.log"
    exit 1
fi
if grep -q '/Modem/' "$OUT/mmcli-L.txt"; then
    echo "RESULT: modem back after resume"
    exit 0
fi
echo "RESULT: modem probed but not exported"
exit 1
