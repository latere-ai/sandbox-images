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
    out="$(env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy HOME="$home" TMPDIR="${tmp}/run" CHROMIUM="$(make_stub "$tmp")" bash ./chromium-launch about:blank)"
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
    out="$(env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy HOME="$tmp" CHROMIUM="$(make_stub "$tmp")" bash ./chromium-launch)"
    if grep -qx "HOME=${tmp}" <<<"$out" && grep -qx -- "--user-data-dir=${tmp}/.chromium" <<<"$out"; then
        pass "$name"
    else
        fail "$name (got: $(tr '\n' ' ' <<<"$out"))"
    fi
    rm -rf "$tmp"
}

# A proxy whose URL carries the credential, as Cella's egress gateway is
# handed to a sandbox, must reach Chromium as the address alone, with an
# extension that holds the decoded credential in files only this user reads.
# Chromium ignores a credential in the URL and asks a person for one.
test_proxy_credential() {
    local name="chromium-launch: a proxy credential reaches Chromium through an extension, not the command line"
    local tmp out ext mode
    tmp="$(mktemp -d)"
    out="$(env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY HOME="$tmp" TMPDIR="$tmp" \
        https_proxy='http://sandbox:s3cr%2Ft@gw.example:3128' no_proxy='127.0.0.1,localhost' \
        CHROMIUM="$(make_stub "$tmp")" bash ./chromium-launch about:blank)"
    ext="${tmp}/chromium-proxy-sign-in"
    mode="$(stat -f '%Lp' "$ext" 2>/dev/null || stat -c '%a' "$ext")"
    if grep -qx -- "--proxy-server=http://gw.example:3128" <<<"$out" \
        && grep -qx -- "--load-extension=${ext}" <<<"$out" \
        && grep -qx -- "--proxy-bypass-list=127.0.0.1;localhost" <<<"$out" \
        && ! grep -q 's3cr' <<<"$out" \
        && grep -qF '"password": "s3cr/t"' "${ext}/background.js" \
        && grep -qF '"host": "gw.example", "port": 3128' "${ext}/background.js" \
        && grep -qF '"webRequestAuthProvider"' "${ext}/manifest.json" \
        && [[ "$mode" == "700" ]]; then
        pass "$name"
    else
        fail "$name (mode ${mode}; got: $(tr '\n' ' ' <<<"$out"))"
    fi
    rm -rf "$tmp"
}

# A proxy with no credential is passed as the address, with no extension, and
# a sandbox with no proxy at all gets neither flag. Both skip the first-run
# screens, which ask a person to sign in to Chromium.
test_proxy_without_credential() {
    local name="chromium-launch: no credential, no extension; no proxy, no proxy flags"
    local tmp with without
    tmp="$(mktemp -d)"
    with="$(env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u no_proxy -u NO_PROXY HOME="$tmp" TMPDIR="$tmp" \
        https_proxy='http://gw.example:3128' CHROMIUM="$(make_stub "$tmp")" bash ./chromium-launch)"
    without="$(env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy HOME="$tmp" TMPDIR="$tmp" \
        CHROMIUM="$(make_stub "$tmp")" bash ./chromium-launch)"
    if grep -qx -- "--proxy-server=http://gw.example:3128" <<<"$with" \
        && ! grep -q -- "--load-extension" <<<"$with" \
        && [[ ! -e "${tmp}/chromium-proxy-sign-in" ]] \
        && ! grep -q -- "--proxy-server" <<<"$without" \
        && grep -qx -- "--no-first-run" <<<"$without"; then
        pass "$name"
    else
        fail "$name (with: $(tr '\n' ' ' <<<"$with"); without: $(tr '\n' ' ' <<<"$without"))"
    fi
    rm -rf "$tmp"
}

echo "chromium-launch:"
test_read_only_home
test_writable_home
test_proxy_credential
test_proxy_without_credential

if [[ "$FAILURES" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "all passed"
