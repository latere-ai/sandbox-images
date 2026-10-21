#!/usr/bin/env bash
#
# Tests for the browser policy the gui image installs.
# Usage: bash gui/chromium-policy_test.sh
#
# No container required: the policy file and the Dockerfile line that
# installs it are read as they are committed.
set -uo pipefail
cd "$(dirname "$0")"

FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# The policy turns off the bars Chrome for Testing and an unsupported flag
# put over each window. A key Chromium does not know, or a file that is not
# JSON, is ignored without an error, so the bars would come back unseen.
test_policy_turns_off_warnings() {
    local name="chromium-policy.json: CommandLineFlagSecurityWarningsEnabled is false"
    local got
    if got="$(jq '.CommandLineFlagSecurityWarningsEnabled' chromium-policy.json 2>&1)" && [[ "$got" == "false" ]]; then
        pass "$name"
    else
        fail "$name (got: $got)"
    fi
}

# Chrome for Testing reads managed policies from its own directory, not from
# Chromium's /etc/chromium or Chrome's /etc/opt/chrome, so a policy anywhere
# else is never read.
test_policy_installed_where_read() {
    local name="Dockerfile: the policy is installed where Chrome for Testing reads managed policies"
    if grep -Eq '^COPY (--chmod=0644 )?chromium-policy\.json /etc/opt/chrome_for_testing/policies/managed/[^/]+\.json$' Dockerfile; then
        pass "$name"
    else
        fail "$name"
    fi
}

echo "chromium-policy:"
test_policy_turns_off_warnings
test_policy_installed_where_read

if [[ "$FAILURES" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "all passed"
