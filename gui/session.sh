#!/usr/bin/env bash
#
# The helpers gui-browser and gui-desktop share. Sourced, not run: it defines
# functions and starts nothing. Both commands draw on a display someone else
# provides, the image's own gui-entrypoint in a plain container or the
# desktop container Cella runs beside the workload, so neither starts an X
# server.

# gui_wait_for_display waits for the X server on DISPLAY to answer, for at
# most GUI_DISPLAY_WAIT seconds (default 120). The desktop beside a workload
# starts with it, so the first seconds of a workload are spent here.
gui_wait_for_display() {
    local name="$1" waited=0 limit="${GUI_DISPLAY_WAIT:-120}"
    until xdpyinfo -display "${DISPLAY:-:0}" >/dev/null 2>&1; do
        if (( waited >= limit * 10 )); then
            echo "${name}: no X display answered on ${DISPLAY:-:0} within ${limit}s; this workload needs a desktop" >&2
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
}

# gui_writable_state points the XDG directories under TMPDIR when HOME is
# read-only, as it is in a sandbox with a read-only root file system. The
# desktop's programs keep their settings and caches there; HOME itself is
# left alone, so a terminal still opens a shell with the image's own home.
gui_writable_state() {
    [[ -w "${HOME}" ]] && return 0
    local base="${TMPDIR:-/tmp}/gui-state"
    export XDG_CONFIG_HOME="${base}/config" XDG_CACHE_HOME="${base}/cache" \
        XDG_DATA_HOME="${base}/data" XDG_STATE_HOME="${base}/state"
    mkdir -p "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}" "${XDG_DATA_HOME}" "${XDG_STATE_HOME}"
}

gui_pids=()

# gui_supervise starts a command in the background and starts it again
# whenever it exits. A command that exits within five seconds of starting
# waits longer before the next start, up to thirty seconds, so one that
# cannot start does not spin.
gui_supervise() {
    local name="$1"
    shift
    (
        trap 'kill "${child}" 2>/dev/null; exit 0' TERM INT
        pause=1
        while :; do
            started=${SECONDS}
            "$@" &
            child=$!
            wait "${child}" || true
            if (( SECONDS - started < 5 )); then
                pause=$((pause * 2 > 30 ? 30 : pause * 2))
            else
                pause=1
            fi
            echo "${name}: exited; starting it again in ${pause}s" >&2
            sleep "${pause}" &
            wait $! || true
        done
    ) &
    gui_pids+=("$!")
}

# gui_run_supervised waits on every supervised command and stops them all on
# TERM or INT, which is how the workload is stopped.
gui_run_supervised() {
    trap 'kill "${gui_pids[@]}" 2>/dev/null; wait; exit 0' TERM INT
    wait
}
