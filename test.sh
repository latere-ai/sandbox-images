#!/bin/bash
#
# Verify sandbox images are functional.
# Usage: sh test.sh [tag]    (default: latest)
#
set -euo pipefail
cd "$(dirname "$0")"

TAG="${1:-latest}"
RUNTIME="${RUNTIME:-podman}"
REGISTRY="${REGISTRY:-$(yq -r '.registry' catalog.yaml)}"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }
section() { printf "\n\033[1m%s\033[0m\n" "$1"; }

# podman warns on stdout-adjacent stderr when running a non-native
# platform image (the amd64-only gui image on an arm64 host); strip it
# so exact-match assertions see only the command's output.
run_in() {
    local image="$1" out rc; shift
    out=$($RUNTIME run --rm --entrypoint bash "$image" -c "$*" 2>&1); rc=$?
    printf '%s\n' "$out" | grep -v '^WARNING: image platform'
    return $rc
}

run_in_root() {
    local image="$1"; shift
    $RUNTIME run --rm --user root --entrypoint bash "$image" -c "$*" 2>&1
}

# --- Catalog coverage: every cataloged image must exist and run ---
# Pre-pull with an explicit platform: podman refuses to auto-pull a
# non-native image (e.g. the amd64-only gui image on an arm64 host), so
# pick the host platform when the image ships it, else its first one.
section "catalog images @ ${TAG}"
HOST_PLATFORM="linux/$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')"
for name in $(yq -r '.images[].name' catalog.yaml); do
    platform=$(yq -r ".images[] | select(.name==\"$name\") | .platforms | (map(select(. == \"$HOST_PLATFORM\")) + .)[0]" catalog.yaml)
    $RUNTIME pull -q --platform "$platform" "${REGISTRY}/${name}:${TAG}" >/dev/null 2>&1 \
        && run_in "${REGISTRY}/${name}:${TAG}" 'true' >/dev/null 2>&1 \
        && pass "image runnable: $name ($platform)" || fail "image not runnable: $name"
done

# --- Base image ---
section "sandbox-base:${TAG}"
BASE="${REGISTRY}/sandbox-base:${TAG}"

out=$(run_in "$BASE" 'go version') && [[ "$out" == *"go1."* ]] \
    && pass "go: $out" || fail "go not found"

out=$(run_in "$BASE" 'node --version') && [[ "$out" == v* ]] \
    && pass "node: $out" || fail "node not found"

out=$(run_in "$BASE" 'python3 --version') && [[ "$out" == *"Python"* ]] \
    && pass "python3: $out" || fail "python3 not found"

for tool in gopls dlv goimports golangci-lint staticcheck gosec; do
    run_in "$BASE" "which $tool" >/dev/null 2>&1 \
        && pass "go tool: $tool" || fail "go tool missing: $tool"
done

out=$(run_in "$BASE" 'pwd') && [[ "$out" == "/workspace" ]] \
    && pass "workdir: /workspace" || fail "workdir is $out, expected /workspace"

# Prompt must surface CELLA_HOST (the runtime-injected instance name)
# and fall back to the kernel hostname when it is unset, so pooled
# containers show the right name without a hostname change.
# /root is 0700 and the image runs as agent, so this check needs root.
run_in_root "$BASE" 'grep -q CELLA_HOST /etc/skel/.bashrc && grep -q CELLA_HOST /root/.bashrc' >/dev/null 2>&1 \
    && pass "prompt: /etc/skel and /root .bashrc patched" \
    || fail "prompt: rc files missing CELLA_HOST"

out=$(run_in "$BASE" "CELLA_HOST=cella-test-xyz bash -ic 'printf %s \"\${PS1@P}\"' 2>/dev/null") \
    && [[ "$out" == *"cella-test-xyz"* ]] \
    && pass "prompt: uses CELLA_HOST when set" \
    || fail "prompt: CELLA_HOST not honored (got: ${out})"

out=$(run_in "$BASE" "bash -ic 'printf %s \"\${PS1@P}\"' 2>/dev/null") \
    && [[ -n "$out" && "$out" != *"CELLA_HOST"* && "$out" != *':-'* ]] \
    && pass "prompt: falls back to hostname when CELLA_HOST unset" \
    || fail "prompt: fallback broken (got: ${out})"

# The non-root `agent` user is created in the base image; the prompt
# must surface CELLA_HOST for it too (inherited from the patched
# /etc/skel via useradd -m).
out=$(run_in "$BASE" 'whoami') && [[ "$out" == "agent" ]] \
    && pass "user: agent" || fail "user is $out, expected agent"

out=$(run_in "$BASE" 'echo $HOME') && [[ "$out" == "/home/agent" ]] \
    && pass "home: /home/agent" || fail "home is $out"

run_in "$BASE" 'grep -q CELLA_HOST ~/.bashrc' >/dev/null 2>&1 \
    && pass "prompt: agent user inherits CELLA_HOST" \
    || fail "prompt: /home/agent/.bashrc missing CELLA_HOST"

run_in "$BASE" 'test -w /workspace' \
    && pass "workspace writable" || fail "/workspace not writable"

# --- GUI image ---
section "sandbox-gui:${TAG}"
GUI="${REGISTRY}/sandbox-gui:${TAG}"

out=$(run_in "$GUI" 'whoami') && [[ "$out" == "agent" ]] \
    && pass "user: agent" || fail "user is $out, expected agent"

out=$(run_in "$GUI" 'echo $HOME') && [[ "$out" == "/home/agent" ]] \
    && pass "home: /home/agent" || fail "home is $out"

out=$(run_in "$GUI" 'go version') \
    && pass "go (inherited): $out" || fail "go not inherited from base"

for tool in Xvfb x11vnc websockify xdotool convert chromium chromium-launch gui-browser gui-desktop tint2 lxterminal pcmanfm mousepad socat; do
    run_in "$GUI" "which $tool" >/dev/null 2>&1 \
        && pass "gui tool: $tool" || fail "gui tool missing: $tool"
done

out=$(run_in "$GUI" 'printf "%s %s" "$DISPLAY" "$SCREEN_GEOMETRY"') && [[ "$out" == ":0 1280x800x24" ]] \
    && pass "display defaults: $out" || fail "display defaults wrong: $out"

run_in "$GUI" 'test -d /usr/share/novnc && test -f /usr/local/bin/gui-supervisor' >/dev/null 2>&1 \
    && pass "novnc + supervisor installed" || fail "novnc or supervisor missing"

# Read the supervisor once and assert host-side: in-container grep
# segfaults sporadically under qemu emulation (the gui image is
# amd64-only, so arm64 hosts run it emulated).
supervisor=$(run_in "$GUI" 'cat /usr/local/bin/gui-supervisor')

# Regression: the supervisor must not pass mutter flags that mutter
# rejects. --no-cursor was added speculatively and is not a valid mutter
# option; with it, mutter exits 1 immediately, the supervisor restarts it
# once per second, and each restart leaks dbus + X clients on Xvfb until
# the display hits its "Maximum number of clients reached" limit and the
# readiness probe can no longer reach :0.
grep -qF -- "--no-cursor" <<<"$supervisor" \
    && fail "supervisor: mutter --no-cursor is invalid and will restart-loop" \
    || pass "supervisor: no invalid mutter --no-cursor flag"

# Regression: x11vnc 0.9.16's XDAMAGE/XFIXES polling paths deadlock
# against a compositing window manager (mutter). The symptom is x11vnc
# accepts TCP connections on 5900 but never emits the RFB protocol
# greeting, so noVNC stays at "CONNECTING" forever and the desktop tab
# renders an empty black canvas. -noxdamage and -noxfixes route around
# both extensions; pair them so a future cleanup doesn't drop one.
grep -q -- "-noxdamage" <<<"$supervisor" && grep -q -- "-noxfixes" <<<"$supervisor" \
    && pass "supervisor: x11vnc carries -noxdamage and -noxfixes (compositor workarounds)" \
    || fail "supervisor: x11vnc must pass -noxdamage and -noxfixes to survive mutter as the WM"

# --- Harness image ---
section "sandbox-harness:${TAG}"
HARNESS="${REGISTRY}/sandbox-harness:${TAG}"

# The version pins live only in the Dockerfile ARGs; assert the shipped
# CLIs match them so a bump can't silently fail to take effect.
CLAUDE_PIN=$(sed -n 's/^ARG CLAUDE_CODE_VERSION=//p' harness/Dockerfile)
CODEX_PIN=$(sed -n 's/^ARG CODEX_VERSION=//p' harness/Dockerfile)

out=$(run_in "$HARNESS" 'claude --version') && [[ "$out" == *"$CLAUDE_PIN"* ]] \
    && pass "claude: $out" || fail "claude version (want $CLAUDE_PIN, got: $out)"

out=$(run_in "$HARNESS" 'codex --version') && [[ "$out" == *"$CODEX_PIN"* ]] \
    && pass "codex: $out" || fail "codex version (want $CODEX_PIN, got: $out)"

out=$(run_in "$HARNESS" 'whoami') && [[ "$out" == "agent" ]] \
    && pass "user: agent" || fail "user is $out, expected agent"

# CLIs must live outside $HOME so a volume mounted over /home/agent
# cannot mask them.
out=$(run_in "$HARNESS" 'which claude && which codex') && [[ "$out" != *"/home/"* ]] \
    && pass "CLIs installed system-wide" || fail "CLIs under /home: $out"

run_in "$HARNESS" 'test -d ~/.claude && test -d ~/.codex' >/dev/null 2>&1 \
    && pass "CLI state dirs pre-created" || fail "~/.claude or ~/.codex missing"

# --- Summary ---
echo
if [ "$FAILURES" -eq 0 ]; then
    printf "\033[32mAll checks passed.\033[0m\n"
else
    printf "\033[31m%d check(s) failed.\033[0m\n" "$FAILURES"
    exit 1
fi
