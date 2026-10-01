#!/usr/bin/env bash
#
# Tests for chromium-launch's profile location.
# Usage: bash gui/chromium-launch_test.sh
#
# No container required: CHROMIUM names a stub that prints what it was given.
set -uo pipefail
cd "$(dirname "$0")"

FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# stub writes the HOME and the arguments the launcher hands Chromium.
make_stub() {
    local stub="$1/chromium"
    printf '#!/usr/bin/env bash\necho "HOME=$HOME"\nprintf "%%s\\n" "$@"\n' > "$stub"
    chmod 0755 "$stub"
    echo "$stub"
}

# A read-only HOME, as a sandbox with a read-only root file system has, must
# not reach Chromium: it exits at start when it cannot write its profile.
test_read_only_home() {
    local name="chromium-launch: a read-only HOME moves the profile under TMPDIR"
    local tmp home out
    tmp="$(mktemp -d)"
    home="${tmp}/home"
    mkdir -p "$home" "${tmp}/run"
    chmod 0555 "$home"
    out="$(HOME="$home" TMPDIR="${tmp}/run" CHROMIUM="$(make_stub "$tmp")" bash ./chromium-launch about:blank)"
    if grep -qx "HOME=${tmp}/run/chromium-home" <<<"$out" \
        && grep -qx -- "--user-data-dir=${tmp}/run/chromium-home/.chromium" <<<"$out" \
        && [[ -d "${tmp}/run/chromium-home" ]] \
        && grep -qx "about:blank" <<<"$out"; then
        pass "$name"
    else
        fail "$name (got: $(tr '\n' ' ' <<<"$out"))"
    fi
    chmod 0755 "$home"
    rm -rf "$tmp"
}

# A writable HOME keeps the profile where it was, so a sandbox that keeps
# its home keeps its browser profile.
test_writable_home() {
    local name="chromium-launch: a writable HOME keeps the profile there"
    local tmp out
    tmp="$(mktemp -d)"
    out="$(HOME="$tmp" CHROMIUM="$(make_stub "$tmp")" bash ./chromium-launch)"
    if grep -qx "HOME=${tmp}" <<<"$out" && grep -qx -- "--user-data-dir=${tmp}/.chromium" <<<"$out"; then
        pass "$name"
    else
        fail "$name (got: $(tr '\n' ' ' <<<"$out"))"
    fi
    rm -rf "$tmp"
}

echo "chromium-launch:"
test_read_only_home
test_writable_home

if [[ "$FAILURES" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "all passed"
