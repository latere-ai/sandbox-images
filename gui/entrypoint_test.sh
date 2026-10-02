#!/usr/bin/env bash
#
# Tests for the gui entrypoint's VNC password provisioning.
# Usage: bash gui/entrypoint_test.sh
#
# No container required: vncpass.sh is sourced directly.
set -uo pipefail
cd "$(dirname "$0")"

FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# The generated password must reach the operator through the 0600
# passwdfile only. Logging it puts an attach credential into container
# logs, which are collected and readable well outside the container.
test_password_not_logged() {
    local name="vncpass: generated password is not written to stderr"
    local tmp err secret mode
    tmp="$(mktemp -d)"
    err="${tmp}/stderr.txt"

    (
        set -euo pipefail
        # shellcheck source=gui/vncpass.sh
        source ./vncpass.sh
        HOME="$tmp" VNC_PASSWORD= provision_vncpass
    ) 2>"$err"

    if [[ ! -s "${tmp}/.vncpass" ]]; then
        fail "$name (no password file was written)"
        rm -rf "$tmp"
        return
    fi
    secret="$(tr -d '\n' < "${tmp}/.vncpass")"

    mode="$(stat -c '%a' "${tmp}/.vncpass" 2>/dev/null || stat -f '%Lp' "${tmp}/.vncpass")"
    if [[ "$mode" != "600" ]]; then
        fail "vncpass: password file mode is ${mode}, want 600"
    else
        pass "vncpass: password file mode is 600"
    fi

    if grep -qF -- "$secret" "$err"; then
        fail "$name"
        printf "    stderr: %s\n" "$(cat "$err")"
    else
        pass "$name"
    fi
    rm -rf "$tmp"
}

# VncAuth truncates the password to 8 bytes, so 8 characters is the
# hard ceiling; entropy comes from the alphabet, not the length.
test_password_shape() {
    local name="vncpass: generated password is 8 characters"
    local tmp len
    tmp="$(mktemp -d)"
    (
        set -euo pipefail
        source ./vncpass.sh
        HOME="$tmp" VNC_PASSWORD= provision_vncpass
    ) 2>/dev/null
    len="$(tr -d '\n' < "${tmp}/.vncpass" | wc -c | tr -d ' ')"
    if [[ "$len" == "8" ]]; then
        pass "$name"
    else
        fail "$name (got ${len})"
    fi
    rm -rf "$tmp"
}

# An orchestrator-supplied password must be used verbatim, and a file
# that already exists must not be regenerated on restart.
test_supplied_password_wins() {
    local name="vncpass: VNC_PASSWORD is honored and an existing file is kept"
    local tmp
    tmp="$(mktemp -d)"
    (
        set -euo pipefail
        source ./vncpass.sh
        HOME="$tmp" VNC_PASSWORD=supplied provision_vncpass
        HOME="$tmp" VNC_PASSWORD= provision_vncpass
    ) 2>/dev/null
    if [[ "$(cat "${tmp}/.vncpass")" == "supplied" ]]; then
        pass "$name"
    else
        fail "$name (file holds $(cat "${tmp}/.vncpass"))"
    fi
    rm -rf "$tmp"
}

printf "\n\033[1mgui vncpass\033[0m\n"
test_password_not_logged
test_password_shape
test_supplied_password_wins

if [[ "$FAILURES" -gt 0 ]]; then
    printf "\n%d failure(s)\n" "$FAILURES"
    exit 1
fi
printf "\nall tests passed\n"
