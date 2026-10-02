#!/usr/bin/env bash
#
# Tests for gui-browser and gui-desktop, the workload commands that start
# something on the display.
# Usage: bash gui/session_test.sh
#
# No container required: stubs stand in for the display probe, the browser
# launcher and the taskbar, and record how they were started.
set -uo pipefail
cd "$(dirname "$0")"

FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# stubs writes the three programs the commands start into $1/bin. The
# browser stub exits at once, as a browser a person closed does; the taskbar
# stub keeps running. display says whether the display answers.
stubs() {
    local dir="$1" display="$2"
    mkdir -p "${dir}/bin"
    printf '#!/usr/bin/env bash\nexit %s\n' "$display" > "${dir}/bin/xdpyinfo"
    printf '#!/usr/bin/env bash\necho "$*" >> "%s/browser.log"\n' "$dir" > "${dir}/bin/chromium-launch"
    printf '#!/usr/bin/env bash\necho "$*" >> "%s/taskbar.log"\nexec sleep 300\n' "$dir" > "${dir}/bin/tint2"
    chmod 0755 "${dir}/bin/"*
}

# run starts a command in this shell, with the stubs first on PATH and a
# writable HOME, and leaves its pid in RUN_PID so the test can wait on it.
run() {
    local dir="$1"
    shift
    PATH="${dir}/bin:${PATH}" HOME="$dir" GUI_SESSION=./session.sh "$@" >"${dir}/stdout" 2>"${dir}/stderr" &
    RUN_PID=$!
}

# stopped waits up to three seconds for a process to end.
stopped() {
    local pid="$1"
    for _ in $(seq 1 30); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
    done
    return 1
}

# A browser a person closes is opened again at the same address, and the
# workload stopping (TERM) ends the command and everything it started.
test_browser_restarts_and_stops() {
    local name="gui-browser: a closed browser is opened again, and TERM stops it"
    local tmp pid starts
    tmp="$(mktemp -d)"
    stubs "$tmp" 0
    run "$tmp" bash ./gui-browser https://example.com
    pid=$RUN_PID
    sleep 3.5
    starts="$(grep -c -x -- '--start-maximized https://example.com' "${tmp}/browser.log" 2>/dev/null || echo 0)"
    kill -TERM "$pid"
    if (( starts >= 2 )) && stopped "$pid" && ! pgrep -f "${tmp}/bin" >/dev/null; then
        pass "$name"
    else
        fail "$name (${starts} starts; $(tr '\n' ' ' < "${tmp}/stderr"))"
        kill -KILL "$pid" 2>/dev/null
    fi
    rm -rf "$tmp"
}

# With no display, which is a workload created without a desktop, the
# command ends and says why, rather than waiting forever.
test_no_display() {
    local name="gui-browser: no display ends the command with the reason"
    local tmp pid
    tmp="$(mktemp -d)"
    stubs "$tmp" 1
    GUI_DISPLAY_WAIT=1 run "$tmp" bash ./gui-browser
    pid=$RUN_PID
    local code=0
    stopped "$pid" && { wait "$pid" || code=$?; }
    if (( code == 1 )) && grep -q 'this workload needs a desktop' "${tmp}/stderr" \
        && [[ ! -e "${tmp}/browser.log" ]]; then
        pass "$name"
    else
        fail "$name (exit ${code}; $(tr '\n' ' ' < "${tmp}/stderr"))"
        kill -KILL "$pid" 2>/dev/null
    fi
    rm -rf "$tmp"
}

# The desktop starts the taskbar from its own configuration, by path, and a
# maximized browser at the given address.
test_desktop_starts_taskbar_and_browser() {
    local name="gui-desktop: the taskbar starts from its configuration, beside a browser"
    local tmp pid
    tmp="$(mktemp -d)"
    stubs "$tmp" 0
    GUI_TINT2RC=/etc/xdg/tint2/gui-desktop.tint2rc run "$tmp" bash ./gui-desktop https://example.com
    pid=$RUN_PID
    sleep 1
    kill -TERM "$pid"
    if grep -qx -- '-c /etc/xdg/tint2/gui-desktop.tint2rc' "${tmp}/taskbar.log" 2>/dev/null \
        && grep -qx -- '--start-maximized https://example.com' "${tmp}/browser.log" 2>/dev/null \
        && stopped "$pid" && ! pgrep -f "${tmp}/bin" >/dev/null; then
        pass "$name"
    else
        fail "$name ($(tr '\n' ' ' < "${tmp}/stderr"))"
        kill -KILL "$pid" 2>/dev/null
    fi
    rm -rf "$tmp"
}

# A read-only HOME, as a sandbox with a read-only root file system has,
# moves the programs' settings under TMPDIR and leaves HOME as it is.
test_read_only_home_state() {
    local name="session: a read-only HOME points the XDG directories under TMPDIR"
    local tmp out
    tmp="$(mktemp -d)"
    mkdir -p "${tmp}/home" "${tmp}/run"
    chmod 0555 "${tmp}/home"
    out="$(HOME="${tmp}/home" TMPDIR="${tmp}/run" bash -c 'source ./session.sh; gui_writable_state; echo "$HOME $XDG_CONFIG_HOME"')"
    if [[ "$out" == "${tmp}/home ${tmp}/run/gui-state/config" ]] && [[ -d "${tmp}/run/gui-state/config" ]]; then
        pass "$name"
    else
        fail "$name (got: ${out})"
    fi
    chmod 0755 "${tmp}/home"
    rm -rf "$tmp"
}

echo "gui session commands:"
test_browser_restarts_and_stops
test_no_display
test_desktop_starts_taskbar_and_browser
test_read_only_home_state

if [[ "$FAILURES" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "all passed"
