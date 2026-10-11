#!/usr/bin/env bash
#
# Tests for the base image's chromium and playwright commands.
# Usage: bash base/browser_test.sh
#
# No container required: CHROMIUM_BINARY and PLAYWRIGHT_CLI name a stub that
# prints what it was given.
set -uo pipefail
cd "$(dirname "$0")"

FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# stub writes the HOME, the browser directory, and the arguments a command
# hands on.
make_stub() {
    local stub="$1/stub"
    printf '#!/usr/bin/env bash\necho "HOME=$HOME"\necho "BROWSERS=${PLAYWRIGHT_BROWSERS_PATH:-}"\nprintf "%%s\\n" "$@"\n' > "$stub"
    chmod 0755 "$stub"
    echo "$stub"
}

# Chromium gets the two flags a container needs, then the caller's arguments
# as given.
test_chromium_flags() {
    local name="chromium: the container flags precede the caller's arguments, and a writable HOME stays"
    local tmp out
    tmp="$(mktemp -d)"
    out="$(HOME="$tmp" CHROMIUM_BINARY="$(make_stub "$tmp")" sh ./chromium --headless about:blank)"
    if [[ "$(sed -n '3,6p' <<<"$out" | tr '\n' ' ')" == "--no-sandbox --disable-dev-shm-usage --headless about:blank " ]] \
        && grep -qx "HOME=${tmp}" <<<"$out"; then
        pass "$name"
    else
        fail "$name (got: $(tr '\n' ' ' <<<"$out"))"
    fi
    rm -rf "$tmp"
}

# A read-only HOME, as a sandbox with a read-only root file system has, must
# not reach Chromium: it exits at start when it cannot write its profile.
test_chromium_read_only_home() {
    local name="chromium: a read-only HOME gives the browser one under TMPDIR"
    local tmp home out
    tmp="$(mktemp -d)"
    home="${tmp}/home"
    mkdir -p "$home" "${tmp}/run"
    chmod 0555 "$home"
    out="$(HOME="$home" TMPDIR="${tmp}/run" CHROMIUM_BINARY="$(make_stub "$tmp")" sh ./chromium about:blank)"
    if grep -qx "HOME=${tmp}/run/chromium-home" <<<"$out" && [[ -d "${tmp}/run/chromium-home" ]]; then
        pass "$name"
    else
        fail "$name (got: $(tr '\n' ' ' <<<"$out"))"
    fi
    chmod 0755 "$home"
    rm -rf "$tmp"
}

# installed makes a browser directory with two browsers in it, as the image's
# is, and prints its path.
make_installed() {
    local dir="$1/installed"
    mkdir -p "${dir}/chromium-1" "${dir}/ffmpeg-1" "${dir}/.links"
    echo "$dir"
}

# A browser directory that can be written is used as it is.
test_playwright_writable() {
    local name="playwright: a writable browser directory is used as it is"
    local tmp installed out
    tmp="$(mktemp -d)"
    installed="$(make_installed "$tmp")"
    out="$(PLAYWRIGHT_INSTALLED_BROWSERS="$installed" PLAYWRIGHT_BROWSERS_PATH="$installed" TMPDIR="${tmp}/run" \
        PLAYWRIGHT_CLI="$(make_stub "$tmp")" sh ./playwright install chromium)"
    if grep -qx "BROWSERS=${installed}" <<<"$out" && [[ ! -e "${tmp}/run" ]] \
        && [[ "$(sed -n '3,4p' <<<"$out" | tr '\n' ' ')" == "install chromium " ]]; then
        pass "$name"
    else
        fail "$name (got: $(tr '\n' ' ' <<<"$out"))"
    fi
    rm -rf "$tmp"
}

# A read-only one would make `playwright install` retry its lock for minutes
# and fail. The command works from a writable directory that links to every
# installed browser, and leaves the record of earlier installs behind.
test_playwright_read_only() {
    local name="playwright: a read-only browser directory is used through links under TMPDIR"
    local tmp installed out linked
    tmp="$(mktemp -d)"
    installed="$(make_installed "$tmp")"
    mkdir -p "${tmp}/run"
    chmod 0555 "$installed"
    out="$(PLAYWRIGHT_INSTALLED_BROWSERS="$installed" PLAYWRIGHT_BROWSERS_PATH="$installed" TMPDIR="${tmp}/run" \
        PLAYWRIGHT_CLI="$(make_stub "$tmp")" sh ./playwright install chromium)"
    linked="${tmp}/run/playwright-browsers"
    if grep -qx "BROWSERS=${linked}" <<<"$out" \
        && [[ "$(readlink "${linked}/chromium-1")" == "${installed}/chromium-1" ]] \
        && [[ "$(readlink "${linked}/ffmpeg-1")" == "${installed}/ffmpeg-1" ]] \
        && [[ ! -e "${linked}/.links" && -w "$linked" ]]; then
        pass "$name"
    else
        fail "$name (got: $(tr '\n' ' ' <<<"$out"); linked: $(ls -A "$linked" 2>&1 | tr '\n' ' '))"
    fi
    chmod 0755 "$installed"
    rm -rf "$tmp"
}

# Someone who points Playwright at a browser directory of their own gets that
# directory, whatever the state of the image's.
test_playwright_other_directory() {
    local name="playwright: another browser directory is left alone"
    local tmp installed out
    tmp="$(mktemp -d)"
    installed="$(make_installed "$tmp")"
    chmod 0555 "$installed"
    out="$(PLAYWRIGHT_INSTALLED_BROWSERS="$installed" PLAYWRIGHT_BROWSERS_PATH="${tmp}/mine" TMPDIR="${tmp}/run" \
        PLAYWRIGHT_CLI="$(make_stub "$tmp")" sh ./playwright --version)"
    if grep -qx "BROWSERS=${tmp}/mine" <<<"$out" && [[ ! -e "${tmp}/run" ]]; then
        pass "$name"
    else
        fail "$name (got: $(tr '\n' ' ' <<<"$out"))"
    fi
    chmod 0755 "$installed"
    rm -rf "$tmp"
}

echo "base browser commands:"
test_chromium_flags
test_chromium_read_only_home
test_playwright_writable
test_playwright_read_only
test_playwright_other_directory

if [[ "$FAILURES" -eq 0 ]]; then
    echo "all passed"
else
    echo "${FAILURES} failure(s)"
    exit 1
fi
