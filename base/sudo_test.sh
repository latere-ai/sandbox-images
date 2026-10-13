#!/usr/bin/env bash
#
# Tests for the base image's sudo command.
# Usage: bash base/sudo_test.sh
#
# No container required: SUDO_BINARY names a stub for the system's sudo that
# prints what it was given, SUDO_PROC_STATUS a file that sets the
# no-new-privileges flag or not, and a dpkg-query stub on PATH answers from
# a list of packages.
set -uo pipefail
cd "$(dirname "$0")"

FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The system's sudo, as a stub that prints one argument per line and fails,
# as sudo does under the flag.
printf '#!/usr/bin/env bash\necho "system sudo:"\nprintf "%%s\\n" "$@"\nexit 1\n' > "${TMP}/system-sudo"
chmod 0755 "${TMP}/system-sudo"

printf 'Name:\tsh\nNoNewPrivs:\t1\nSeccomp:\t2\n' > "${TMP}/flag-set"
printf 'Name:\tsh\nNoNewPrivs:\t0\nSeccomp:\t2\n' > "${TMP}/flag-unset"

# Installed packages: name, status, and what the package provides.
# libasound2t64 provides libasound2, the name Ubuntu 22.04 used.
cat > "${TMP}/packages" <<'EOF'
libnss3 installed
libasound2t64 installed libasound2 (= 1.2.11-1ubuntu0.3)
xvfb installed
fonts-wqy-zenhei installed
libasound2 not-installed
EOF

# dpkg-query -W -f=<format> [package]: the status of one package, or the
# status and provides of every package.
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${3:-}" ]]; then
    status=$(awk -v p="$3" '$1 == p { print $2 }' "$PACKAGES")
    [[ -n "$status" ]] || { echo "dpkg-query: no packages found matching $3" >&2; exit 1; }
    printf '%s' "$status"
else
    awk '{ status = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); print status " " $0 }' "$PACKAGES"
fi
EOF
chmod 0755 "${TMP}/bin/dpkg-query"

# run <status file> <argument...>: the sudo script with the stubs; its
# output and errors go to $out, its exit code to $code.
run() {
    local status="$1"; shift
    out="$(PATH="${TMP}/bin:${PATH}" PACKAGES="${TMP}/packages" SUDO_BINARY="${TMP}/system-sudo" \
        SUDO_PROC_STATUS="${TMP}/${status}" sh ./sudo "$@" 2>&1)"
    code=$?
}

# The request `playwright install --with-deps` makes, with the packages given.
playwright_request() {
    printf -- '--\nsh\n-c\napt-get update&& apt-get install -y --no-install-recommends %s\n' "$*"
}

# Without the flag, sudo works, so even a request with nothing to install
# goes to it, word for word.
test_flag_unset() {
    local name="without the no-new-privileges flag, the system's sudo gets every request as given"
    run flag-unset -- sh -c "apt-get update&& apt-get install -y --no-install-recommends libnss3 xvfb"
    if [[ "$code" -eq 1 && "$out" == "system sudo:"$'\n'"$(playwright_request libnss3 xvfb)" ]]; then
        pass "$name"
    else
        fail "$name (exit $code, got: $out)"
    fi
}

# Under the flag, Playwright's request succeeds when every package is
# installed, a name another package provides included, and nothing runs.
test_playwright_installed() {
    local name="under the flag, playwright's install of installed packages succeeds with nothing run"
    run flag-set -- sh -c "apt-get update&& apt-get install -y --no-install-recommends libnss3 libasound2 xvfb fonts-wqy-zenhei"
    if [[ "$code" -eq 0 && "$out" != *"system sudo:"* && "$out" == *"nothing was run"* ]]; then
        pass "$name"
    else
        fail "$name (exit $code, got: $out)"
    fi
}

# A package that is not installed cannot be installed under the flag: the
# system's sudo gets the request as given and says why it cannot run, and
# the missing package is named first.
test_playwright_missing() {
    local name="under the flag, an install with a missing package goes to the system's sudo, which is told which"
    run flag-set -- sh -c "apt-get update&& apt-get install -y --no-install-recommends libnss3 fonts-tlwg-loma-otf libgtk-3-0t64"
    if [[ "$code" -eq 1 \
        && "$out" == "sudo: not installed in this image: fonts-tlwg-loma-otf libgtk-3-0t64"$'\n'"system sudo:"$'\n'"$(playwright_request libnss3 fonts-tlwg-loma-otf libgtk-3-0t64)" ]]; then
        pass "$name"
    else
        fail "$name (exit $code, got: $out)"
    fi
}

# Other ways to ask for an install of installed packages.
test_other_installs() {
    local request
    while IFS='|' read -r -a request; do
        run flag-set "${request[@]}"
        if [[ "$code" -eq 0 && "$out" != *"system sudo:"* ]]; then
            pass "under the flag, nothing to do: sudo ${request[*]}"
        else
            fail "under the flag, sudo ${request[*]} (exit $code, got: $out)"
        fi
    done <<'EOF'
apt-get|install|-y|libnss3
apt|install|libnss3|xvfb
DEBIAN_FRONTEND=noninteractive|apt-get|install|-y|libnss3
-E|apt-get|-qq|install|--yes|libnss3
-n|--|bash|-c|apt-get update && apt-get install -y libnss3
sh|-c|DEBIAN_FRONTEND=noninteractive apt-get install -y libnss3
EOF
}

# Anything else goes to the system's sudo as given: another command, a
# script that is more than apt commands, an update alone, an install that
# pins a version or a release or reinstalls, and a script whose words a
# shell would expand.
test_other_requests() {
    local request
    while IFS='|' read -r -a request; do
        run flag-set "${request[@]}"
        if [[ "$code" -eq 1 && "$out" == "system sudo:"$'\n'"$(printf '%s\n' "${request[@]}")" ]]; then
            pass "under the flag, to the system's sudo: sudo ${request[*]}"
        else
            fail "under the flag, sudo ${request[*]} did not reach the system's sudo as given (exit $code, got: $out)"
        fi
    done <<'EOF'
whoami
-u|root|apt-get|install|libnss3
--|sh|-c|rm -rf /tmp/cache
sh|-c|apt-get install -y libnss3; rm -rf /tmp/cache
sh|-c|apt-get install -y libnss3 && rm -rf /tmp/cache
sh|-c|apt-get install -y libnss3 & rm -rf /tmp/cache
sh|-c|apt-get install -y $(cat packages.txt)
sh|-c|apt-get install -y libnss3&&
sh|-c|apt-get update
apt-get|update
apt-get|install|-y|libnss3=2:3.98-1build1
apt-get|install|-y|libnss3/noble
apt-get|install|--reinstall|libnss3
apt-get|install|-o|Dpkg::Options::=--force-confnew|libnss3
apt-get|remove|libnss3
apt-get|install|-y|lib*
pip|install|requests
EOF
}

echo "base sudo command:"
test_flag_unset
test_playwright_installed
test_playwright_missing
test_other_installs
test_other_requests

if [[ "$FAILURES" -eq 0 ]]; then
    echo "all passed"
else
    echo "${FAILURES} failure(s)"
    exit 1
fi
