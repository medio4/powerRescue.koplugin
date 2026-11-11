#!/bin/sh
# Power-button rescue watchdog for KOReader on Kobo.
# Reads the power key straight from evdev, so it still works while KOReader's
# main loop is stuck. After a hold of HOLD_SECS it first stops the helper
# processes KOReader starts (apps, audio pipelines). Then it waits up to
# STALE_SECS for
# KOReader to stamp the heartbeat file (main.lua does that on every power
# press/release and on resume). No stamp means KOReader is frozen, so it gets
# killed and koreader.sh restarts it through its crash handler.

DEV="${POWERWATCH_DEV:-/dev/input/event2}"
HOLD_SECS="${POWERWATCH_HOLD:-3}"
STALE_SECS="${POWERWATCH_STALE:-6}"
HEARTBEAT="${POWERWATCH_HEARTBEAT:-/tmp/powerwatch.heartbeat}"
RESCUED="${POWERWATCH_RESCUED:-/tmp/powerwatch.rescued}"
PIDFILE="${POWERWATCH_PIDFILE:-/tmp/powerwatch.pid}"
LOG="${POWERWATCH_LOG:-/tmp/powerwatch.log}"
KEY_POWER=116

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

koreader_running() { pgrep -f 'reader.lua' >/dev/null 2>&1; }

# $1 = press time (epoch seconds). KOReader is alive if it stamped the
# heartbeat for this press or later.
# Programs that are not part of KOReader but are commonly started outside
# /mnt/onboard by its plugins (read-along audio through the system GStreamer).
HELPERS="gst-launch"

# Stop every program started from user storage (/mnt/onboard): apps launched
# from KOReader, plugin helpers (audio, TTS), and their scripts. KOReader
# itself, its SSH server, and this watchdog are kept.
stop_tasks() {
    for p in /proc/[0-9]*; do
        pid=${p#/proc/}
        [ "$pid" = "$$" ] && continue
        cwd=$(readlink "$p/cwd" 2>/dev/null)
        exe=$(readlink "$p/exe" 2>/dev/null)
        case "$cwd$exe" in *"/mnt/onboard"*) ;; *) continue ;; esac
        case "$exe" in */luajit|*/dropbear|*/dbus-monitor) continue ;; esac
        cmd=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)
        case "$cmd" in *koreader.sh*|*powerwatch*|"dd bs 16"*|"od -An"*|"") continue ;; esac
        kill -9 "$pid" 2>/dev/null && log "stopped $pid: $cmd"
    done
    for h in $HELPERS; do
        pkill -9 -f "$h" 2>/dev/null && log "stopped $h"
    done
}

rescue() {
    stop_tasks
    waited=0
    while [ "$waited" -lt "$STALE_SECS" ]; do
        beat=$(cat "$HEARTBEAT" 2>/dev/null)
        if [ -n "$beat" ] && [ "$beat" -ge $(($1 - 1)) ]; then
            log "hold ignored: KOReader is responsive"
            return
        fi
        sleep 1
        waited=$((waited + 1))
    done
    log "KOReader frozen (last heartbeat '${beat}'), restarting it"
    : >"$RESCUED"
    pkill -9 -f 'reader.lua'
}

echo $$ >"$PIDFILE"
log "started on $DEV (hold ${HOLD_SECS}s)"
exec 3<"$DEV" || { log "cannot open $DEV"; exit 1; }

press_sec=""
press_usec=0
# struct input_event on armv7: u32 sec, u32 usec, u16 type, u16 code, s32 value
while ev=$(dd bs=16 count=1 <&3 2>/dev/null | od -An -tu4); do
    [ -n "$ev" ] || break
    set -- $ev
    [ "$3" -eq $((1 + KEY_POWER * 65536)) ] || continue
    case "$4" in
    1)
        press_sec=$1 press_usec=$2
        ;;
    0)
        [ -n "$press_sec" ] || continue
        held_ms=$(( ($1 - press_sec) * 1000 + ($2 - press_usec) / 1000 ))
        pressed_at=$press_sec
        press_sec=""
        if ! koreader_running; then
            log "KOReader not running, exiting"
            break
        fi
        if [ "$held_ms" -ge $((HOLD_SECS * 1000)) ]; then
            log "power held ${held_ms} ms"
            rescue "$pressed_at"
        fi
        ;;
    esac
done
rm -f "$PIDFILE"
