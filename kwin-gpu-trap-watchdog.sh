#!/usr/bin/bash
# kwin-gpu-trap-watchdog — recover a Plasma Wayland session from nouveau
# PGRAPH trap floods in KWin's GPU channel, instead of needing a hard poweroff.
#
# Symptom it targets (MacBookPro11,3, GK107 / nouveau, Plasma 6.8 Wayland):
#   kernel: nouveau 0000:01:00.0: gr: TRAP ch 3 [... kwin_wayland[PID]]
#   kernel: nouveau 0000:01:00.0: gr: GPC0/PROP trap: 00000080 [ZETA_STORAGE_TYPE_MISMATCH] ...
# repeated hundreds of times per second → screen frozen, cursor/panel gone,
# audio + rest of the system still alive.
#
# Recovery (v2, after the 2026-11-21 live test):
#   Stage 1: SIGKILL kwin_wayland. kwin_wayland_wrapper sees a non-zero exit and
#            respawns it through its crash path (up to 10x). Qt/KDE apps
#            reconnect (QT_WAYLAND_RECONNECT=1); GTK apps die.
#   Stage 2: if no kwin_wayland stays up for STABLE seconds within
#            RECOVER_TIMEOUT, end the session (loginctl terminate-session) →
#            SDDM login screen with a fresh compositor. Apps are lost, but no
#            hard poweroff.
#   v1 used SIGHUP → wrapper.restart(). Do NOT go back to that: restart()
#   disconnects the wrapper's crash-respawn handler and never reconnects it,
#   and on this box the replacement kwin segfaulted 0.4 s after start
#   (libkwin.so 6.8.3, legacy-modeset on nouveau) → no compositor, hard reboot.
#
# Tunables (env, or ~/.config/kwin-gpu-trap-watchdog.conf):
#   THRESH           traps inside WINDOW seconds that count as a flood  (150)
#   WINDOW           seconds                                             (5)
#   STABLE           seconds a respawned kwin must survive               (10)
#   RECOVER_TIMEOUT  give stage 1 this long before stage 2               (30)
#   SKIP_RESPAWN=1   go straight to stage 2 (session end)                (0)
#   MAX_PER_HOUR     max recoveries per rolling hour, then only log      (4)
#   DRY_RUN=1        detect + log, never signal anything
#   TEST_INPUT       read trap lines from this file instead of journalctl

set -u
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/kwin-gpu-trap-watchdog.conf"
[[ -r $CONF ]] && . "$CONF"

THRESH=${THRESH:-150}
WINDOW=${WINDOW:-5}
STABLE=${STABLE:-10}
RECOVER_TIMEOUT=${RECOVER_TIMEOUT:-30}
SKIP_RESPAWN=${SKIP_RESPAWN:-0}
MAX_PER_HOUR=${MAX_PER_HOUR:-4}
DRY_RUN=${DRY_RUN:-0}
TEST_INPUT=${TEST_INPUT:-}

PATTERN='gr: TRAP ch [0-9]+ \[[0-9a-f]+ kwin_wayland\[[0-9]+\]\]'
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/kwin-gpu-trap-watchdog"
/usr/bin/mkdir -p "$STATE_DIR"
HISTORY="$STATE_DIR/recoveries.log"

log()  { echo "$*"; }
hist() { echo "$(/usr/bin/date '+%F %T') $*" >> "$HISTORY"; }

declare -a recent=()   # epoch seconds of recent recoveries

recovery_allowed() {
    local now=$EPOCHSECONDS keep=() t
    for t in "${recent[@]}"; do (( now - t < 3600 )) && keep+=("$t"); done
    recent=("${keep[@]}")
    (( ${#recent[@]} < MAX_PER_HOUR ))
}

# graphical (wayland) session of this user on seat0
graphical_session() {
    /usr/bin/loginctl list-sessions --no-legend 2>/dev/null \
        | /usr/bin/awk -v u="$UID" '$2==u && $4=="seat0" {print $1; exit}'
}

my_kwin_pid() {
    /usr/bin/pgrep -u "$UID" -x kwin_wayland | /usr/bin/head -1
}

# stage 1 success = a kwin_wayland other than $1 alive continuously for STABLE s
wait_for_stable_kwin() {
    local bad=$1 deadline=$(( EPOCHSECONDS + RECOVER_TIMEOUT )) cur since=0 last=
    while (( EPOCHSECONDS < deadline )); do
        cur=$(my_kwin_pid)
        if [[ -n $cur && $cur != "$bad" ]]; then
            if [[ $cur != "$last" ]]; then last=$cur; since=$EPOCHSECONDS; fi
            if (( EPOCHSECONDS - since >= STABLE )); then echo "$cur"; return 0; fi
        else
            last=
        fi
        /usr/bin/sleep 1
    done
    return 1
}

end_session() {
    local sid
    sid=$(graphical_session)
    if [[ -z $sid ]]; then
        log "stage 2: could not find graphical session — nothing more I can do"
        hist "stage 2 FAILED: no session found"
        return
    fi
    log "stage 2: terminating session $sid -> SDDM login screen"
    hist "stage 2: loginctl terminate-session $sid"
    /usr/bin/loginctl terminate-session "$sid"
}

notify_later() {
    ( /usr/bin/sleep 8
      /usr/bin/notify-send -a "KWin GPU watchdog" -i dialog-warning \
          "Compositor restarted" \
          "A nouveau GPU trap flood froze KWin; it was killed and respawned. ($1 traps in ${WINDOW}s)" \
          2>/dev/null ) &
}

recover() {
    local bad_pid=$1 count=$2 msg newpid
    msg="flood: $count traps/${WINDOW}s from kwin_wayland[$bad_pid] uptime=$(/usr/bin/cut -d. -f1 /proc/uptime)s session=$(graphical_session)"
    log "$msg"

    if [[ $DRY_RUN == 1 ]]; then
        log "DRY_RUN: would SIGKILL $bad_pid, wait ≤${RECOVER_TIMEOUT}s for a stable respawn, else terminate-session $(graphical_session)"
        hist "$msg [dry-run]"
        return
    fi
    if ! recovery_allowed; then
        log "already recovered ${#recent[@]}x in the last hour (MAX_PER_HOUR=$MAX_PER_HOUR) — ending session instead of another respawn"
        hist "$msg [rate limit]"
        end_session
        return
    fi
    if [[ "$(/usr/bin/cat /proc/$bad_pid/comm 2>/dev/null)" != kwin_wayland ]] \
       || [[ "$(/usr/bin/stat -c %u /proc/$bad_pid 2>/dev/null)" != "$UID" ]]; then
        log "pid $bad_pid is no longer our kwin_wayland — nothing to do"
        return
    fi
    recent+=("$EPOCHSECONDS")

    if [[ $SKIP_RESPAWN == 1 ]]; then
        hist "$msg [SKIP_RESPAWN]"
        end_session
        return
    fi

    log "stage 1: SIGKILL kwin_wayland[$bad_pid] (wrapper crash-path respawn)"
    hist "$msg [stage 1: SIGKILL]"
    /usr/bin/kill -KILL "$bad_pid"
    if newpid=$(wait_for_stable_kwin "$bad_pid"); then
        log "stage 1 OK: kwin_wayland[$newpid] stable for ${STABLE}s"
        hist "stage 1 OK: new kwin_wayland[$newpid]"
        notify_later "$count"
    else
        log "stage 1 failed: no stable kwin_wayland within ${RECOVER_TIMEOUT}s"
        hist "stage 1 failed (no stable kwin in ${RECOVER_TIMEOUT}s)"
        end_session
    fi
}

source_lines() {
    if [[ -n $TEST_INPUT ]]; then
        /usr/bin/grep -E "$PATTERN" "$TEST_INPUT"
    else
        exec /usr/bin/journalctl -k -f -n0 -o cat --grep="$PATTERN"
    fi
}

log "kwin-gpu-trap-watchdog v2: THRESH=$THRESH WINDOW=${WINDOW}s STABLE=${STABLE}s RECOVER_TIMEOUT=${RECOVER_TIMEOUT}s SKIP_RESPAWN=$SKIP_RESPAWN MAX_PER_HOUR=$MAX_PER_HOUR DRY_RUN=$DRY_RUN"

count=0
win_start=0
last_pid=
handled_pid=   # act at most once per kwin_wayland pid
while IFS= read -r line; do
    [[ $line =~ kwin_wayland\[([0-9]+)\] ]] || continue
    pid=${BASH_REMATCH[1]}
    [[ $pid == "$handled_pid" ]] && continue
    now=$EPOCHSECONDS
    if [[ $pid != "$last_pid" ]] || (( now - win_start >= WINDOW )); then
        count=0; win_start=$now; last_pid=$pid
    fi
    (( ++count ))
    if (( count == THRESH )); then
        handled_pid=$pid
        recover "$pid" "$count"
    fi
done < <(source_lines)
