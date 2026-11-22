#!/usr/bin/bash
# Live test of the watchdog's real recovery path (no DRY_RUN): feeds a synthetic
# 150-trap flood naming the CURRENT kwin_wayland pid, so recover() runs exactly
# as on a real freeze (v2: SIGKILL → wrapper respawn → else terminate-session).
# Results -> test-results/ (synced after every step; survives a hard reboot).
# Run detached: systemd-run --user --unit=kwin-restart-test --collect /usr/bin/bash tests/live-restart-test.sh [delay]
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
DELAY=${1:-30}
OUT="$HERE/test-results/live-restart-$(/usr/bin/date +%Y%m%d-%H%M%S).log"
/usr/bin/mkdir -p "$HERE/test-results"
exec >"$OUT" 2>&1

snap() {
    echo "--- $1 @ $(/usr/bin/date +%T) ---"
    /usr/bin/pgrep -a 'kwin_wayland|plasmashell|Xwayland|sddm-greeter' | /usr/bin/cut -c1-110
    /usr/bin/loginctl list-sessions --no-legend
    /usr/bin/sync -f "$OUT"
}

echo "watchdog v2 live test, delay ${DELAY}s"
/usr/bin/notify-send -a "KWin GPU watchdog" -u critical "KWin restart test in ${DELAY}s" \
    "Save your work. GTK apps (terminals, Firefox) will close. Results: test-results/" 2>/dev/null
/usr/bin/sleep "$DELAY"
snap BEFORE
KPID=$(/usr/bin/pgrep -u "$UID" -x kwin_wayland | /usr/bin/head -1)
echo "target kwin_wayland pid=$KPID"
T=$(/usr/bin/mktemp)
for i in $(/usr/bin/seq 150); do
    echo "nouveau 0000:01:00.0: gr: TRAP ch 3 [007f904000 kwin_wayland[$KPID]]"
done >"$T"
/usr/bin/sync -f "$OUT"
# the watchdog's own output goes through tee so each line hits the file immediately
XDG_STATE_HOME="$HERE/test-results/state" TEST_INPUT="$T" DRY_RUN=0 \
    /usr/bin/bash "$HERE/kwin-gpu-trap-watchdog.sh" 2>&1 | while IFS= read -r l; do
        echo "$(/usr/bin/date +%T) $l"; /usr/bin/sync -f "$OUT"; done
/usr/bin/rm -f "$T"
snap "AFTER watchdog returned"
/usr/bin/sleep 10
snap "AFTER +10s"
echo "--- kwin / session journal since test start ---"
/usr/bin/journalctl --since "-90s" --no-pager -o short-precise \
    | /usr/bin/grep -E 'kwin_wayland|segfault|sddm|systemd-logind|plasma-kwin' \
    | /usr/bin/grep -v -E 'gr: TRAP|GPC0' | /usr/bin/cut -c1-200 | /usr/bin/tail -50
echo DONE
/usr/bin/sync -f "$OUT"
