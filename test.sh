#!/bin/bash
#
# Verify sandbox images are functional.
# Usage: bash test.sh [tag] [image...]    (default: latest, every cataloged image)
#
# Each image is pulled from the registry first, so the checks cover what is
# published. LOCAL=1 checks the images a local build (`make`) left in the
# runtime's storage instead, and never pulls.
#
set -euo pipefail
cd "$(dirname "$0")"

TAG="${1:-latest}"
shift || true
RUNTIME="${RUNTIME:-podman}"
REGISTRY="${REGISTRY:-$(yq -r '.registry' catalog.yaml)}"
LOCAL="${LOCAL:-}"
FAILURES=0

pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }
section() { printf "\n\033[1m%s\033[0m\n" "$1"; }

# IMAGES is what this run checks: the images named after the tag, or every
# cataloged image. A name the catalog does not list stops the run, so a typo
# cannot pass by checking nothing.
CATALOGED=$(yq -r '.images[].name' catalog.yaml)
IMAGES=$(echo ${*:-$CATALOGED})
for name in $IMAGES; do
    grep -qx -- "$name" <<<"$CATALOGED" \
        || { echo "test.sh: '$name' is not an image in catalog.yaml" >&2; exit 2; }
done
selected() { [[ " $IMAGES " == *" $1 "* ]]; }

# With LOCAL=1 an image that was not built locally fails its checks: without
# --pull=never the runtime would fetch the published image under the same
# name, and the run would pass on something other than the build.
PULL_POLICY=""
if [[ -n "$LOCAL" ]]; then PULL_POLICY="--pull=never"; fi

# podman warns on stdout-adjacent stderr when running a non-native
# platform image (the amd64-only gui image on an arm64 host); strip it
# so exact-match assertions see only the command's output.
run_in() {
    local image="$1" out rc; shift
    out=$($RUNTIME run --rm $PULL_POLICY ${RUN_FLAGS:-} --entrypoint bash "$image" -c "$*" 2>&1); rc=$?
    printf '%s\n' "$out" | grep -v '^WARNING: image platform'
    return $rc
}

# run_offline is run_in with the network off: what passes here passed with
# nothing downloaded. RUN_FLAGS adds runtime flags to either.
run_offline() { RUN_FLAGS="--network none ${RUN_FLAGS:-}" run_in "$@"; }

run_in_root() {
    local image="$1"; shift
    $RUNTIME run --rm $PULL_POLICY --user root --entrypoint bash "$image" -c "$*" 2>&1
}

# --- Catalog coverage: every image being checked must exist and run ---
# Pre-pull with an explicit platform: podman refuses to auto-pull a
# non-native image (e.g. the amd64-only gui image on an arm64 host), so
# pick the host platform when the image ships it, else its first one.
section "catalog images @ ${TAG}"
HOST_PLATFORM="linux/$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')"
for name in $IMAGES; do
    if [[ -n "$LOCAL" ]]; then
        run_in "${REGISTRY}/${name}:${TAG}" 'true' >/dev/null 2>&1 \
            && pass "image runnable: $name (local build)" \
            || fail "image not runnable: $name (no local build of it?)"
        continue
    fi
    platform=$(yq -r ".images[] | select(.name==\"$name\") | .platforms | (map(select(. == \"$HOST_PLATFORM\")) + .)[0]" catalog.yaml)
    $RUNTIME pull -q --platform "$platform" "${REGISTRY}/${name}:${TAG}" >/dev/null 2>&1 \
        && run_in "${REGISTRY}/${name}:${TAG}" 'true' >/dev/null 2>&1 \
        && pass "image runnable: $name ($platform)" || fail "image not runnable: $name"
done

# --- Base image ---
if selected sandbox-base; then
    section "sandbox-base:${TAG}"
    BASE="${REGISTRY}/sandbox-base:${TAG}"

    out=$(run_in "$BASE" 'go version') && [[ "$out" == *"go1."* ]] \
        && pass "go: $out" || fail "go not found"

    out=$(run_in "$BASE" 'node --version') && [[ "$out" == v* ]] \
        && pass "node: $out" || fail "node not found"

    out=$(run_in "$BASE" 'python3 --version') && [[ "$out" == *"Python"* ]] \
        && pass "python3: $out" || fail "python3 not found"

    # `python` is the command scripts and people try first; an image with
    # only `python3` fails them before any work starts.
    out=$(run_in "$BASE" 'python --version') && [[ "$out" == "Python 3."* ]] \
        && pass "python: $out" || fail "python does not run Python 3 (got: $out)"

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

    # The libraries for charts, documents, and data import with nothing
    # installed at run time.
    for module in matplotlib numpy pandas PIL reportlab pypdf openpyxl docx requests bs4 lxml yaml; do
        run_in "$BASE" "python -c 'import $module'" >/dev/null 2>&1 \
            && pass "python library: $module" || fail "python library missing: $module"
    done

    out=$(run_in "$BASE" 'pdftotext -v') && [[ "$out" == *"pdftotext version"* ]] \
        && pass "pdftotext: ${out%%$'\n'*}" || fail "pdftotext not found"

    # Fonts for Chinese, Japanese, and Korean. fontconfig has to choose Noto
    # CJK's face for each language: WenQuanYi Micro Hei is there for
    # reportlab and matplotlib, and its glyphs are the Chinese forms.
    out=$(run_in "$BASE" 'fc-list :lang=zh family | sort -u') && [[ "$out" == *"Noto Sans CJK SC"* ]] \
        && pass "fonts: $(wc -l <<<"$out" | tr -d ' ') families cover Chinese" \
        || fail "fonts: fc-list finds no Noto Sans CJK SC (got: $out)"

    for face in zh-cn:SC zh-tw:TC ja:JP ko:KR; do
        out=$(run_in "$BASE" "fc-match sans-serif:lang=${face%:*}") && [[ "$out" == *"Noto Sans CJK ${face#*:}"* ]] \
            && pass "fonts: ${face%:*} text uses Noto Sans CJK ${face#*:}" \
            || fail "fonts: ${face%:*} text does not use Noto Sans CJK ${face#*:} (got: $out)"
    done

    # A window on a display would block a script at plt.show() until someone
    # closed it, so the configured backend only writes files.
    out=$(run_in "$BASE" "python -c 'import matplotlib; print(matplotlib.rcParams[\"backend\"])'") && [[ "$out" == "agg" ]] \
        && pass "matplotlib backend: $out" || fail "matplotlib backend is $out, expected agg"

    # The Chinese text the document checks write and read back.
    doc_title="北京与上海气温"

    # A chart with a Chinese title, and a one-page PDF that carries the chart
    # and the same title. The chart names no font, so the glyphs have to come
    # from the image's matplotlib defaults: a glyph no font has is a warning,
    # raised as an error here. The PDF embeds the TrueType CJK font, and
    # pdftotext has to read the title back out of it.
    read -r -d '' doc_script <<PY || true
import os, warnings
import matplotlib.pyplot as plt
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas

warnings.filterwarnings("error", message="Glyph .* missing")
fig, ax = plt.subplots()
ax.bar(["北京", "上海"], [12, 18])
ax.set_title("$doc_title")
fig.savefig("chart.png")

pdfmetrics.registerFont(TTFont("cjk", "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc"))
page = canvas.Canvas("page.pdf")
page.setFont("cjk", 18)
page.drawString(72, 760, "$doc_title")
page.drawImage("chart.png", 72, 380, width=440, height=330)
page.save()
for name in ("chart.png", "page.pdf"):
    assert os.path.getsize(name) > 0, name
PY
    out=$(run_in "$BASE" "cd /tmp && python - <<'PY' && pdfinfo page.pdf | grep Pages && pdftotext page.pdf -
$doc_script
PY") && [[ "$out" =~ Pages:[[:space:]]+1 && "$out" == *"$doc_title"* ]] \
        && pass "chart and PDF with a Chinese title: drawn, and the title reads back from the PDF" \
        || fail "chart or PDF with a Chinese title failed (got: $out)"

    # A PDF whose Chinese text uses a font the file does not embed, as many
    # PDFs from the web do. poppler reads and draws it only with its CJK
    # character maps installed.
    read -r -d '' cid_script <<PY || true
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from reportlab.pdfgen import canvas

pdfmetrics.registerFont(UnicodeCIDFont("STSong-Light"))
page = canvas.Canvas("cid.pdf")
page.setFont("STSong-Light", 18)
page.drawString(72, 760, "$doc_title")
page.save()
PY
    out=$(run_in "$BASE" "cd /tmp && python - <<'PY' && pdftotext cid.pdf - && pdftoppm -png -r 50 cid.pdf cid && test -s cid-1.png
$cid_script
PY") && [[ "$out" == *"$doc_title"* && "$out" != *"Syntax Error"* ]] \
        && pass "poppler reads and draws a PDF with a CJK font that is not embedded" \
        || fail "poppler cannot read a PDF with a CJK font that is not embedded (got: $out)"

    # pip as agent installs for the user and leaves Ubuntu's packages in
    # place: the new module comes from ~/.local, matplotlib still imports
    # beside it, and the command the package installs is on PATH.
    out=$(run_in "$BASE" 'pip install --quiet tabulate && python -c "import matplotlib, tabulate; print(tabulate.__file__)" && command -v tabulate') \
        && [[ "$out" == *"/home/agent/.local/lib/"*"/home/agent/.local/bin/tabulate"* ]] \
        && pass "pip install as agent: installs under ~/.local, matplotlib still imports" \
        || fail "pip install as agent failed (got: $out)"

    # A virtual environment still takes its own installs. Forcing every
    # install to be a user install would make pip refuse here.
    out=$(run_in "$BASE" 'python -m venv /tmp/venv && /tmp/venv/bin/pip install --quiet tabulate && /tmp/venv/bin/python -c "import tabulate; print(tabulate.__file__)"') \
        && [[ "$out" == *"/tmp/venv/lib/"* ]] \
        && pass "pip install in a virtual environment: installs into it" \
        || fail "pip install in a virtual environment failed (got: $out)"

    # sudo drops the setting that lets agent install, so root's pip still
    # leaves the Python that apt manages alone.
    out=$(run_in "$BASE" 'sudo pip install --quiet tabulate') \
        && fail "sudo pip install wrote into the system Python" \
        || { [[ "$out" == *"externally-managed-environment"* ]] \
            && pass "sudo pip install: still refused" \
            || fail "sudo pip install failed for another reason (got: $out)"; }

    # The headless browser. The version pin lives only in the Dockerfile ARG;
    # the installed Playwright has to report it.
    PLAYWRIGHT_PIN=$(sed -n 's/^ARG PLAYWRIGHT_VERSION=//p' base/Dockerfile)

    out=$(run_in "$BASE" 'playwright --version') && [[ "$out" == "Version $PLAYWRIGHT_PIN" ]] \
        && pass "playwright: $out" || fail "playwright version (want $PLAYWRIGHT_PIN, got: $out)"

    out=$(run_offline "$BASE" 'cd /tmp && printf "<h1>ok</h1>" > page.html && playwright screenshot file:///tmp/page.html shot.png && test -s shot.png && echo written') \
        && [[ "$out" == *"written"* ]] \
        && pass "playwright screenshot, network off: writes a PNG" \
        || fail "playwright screenshot failed with the network off (got: $out)"

    # A page with a button and a counter, loaded from a file by a script that
    # requires Playwright from a directory with no project: the click has to
    # change the count, and a 1280x800 screenshot has to come out. The second
    # page is Chinese text and an emoji. The browser reports the font that
    # drew each, and a font without the glyphs would show as another family.
    read -r -d '' browser_script <<'JS' || true
const fs = require('fs');
const { chromium } = require('playwright');
(async () => {
  fs.writeFileSync('counter.html', `<p id="count">0</p><button id="add">Add one</button>
<script>let n = 0; document.getElementById('add').onclick = () => { document.getElementById('count').textContent = String(++n); };</script>`);
  fs.writeFileSync('text.html', '<html lang="zh-CN"><meta charset="utf-8"><h1>北京与上海气温</h1><p id="emoji">&#x1F680;</p></html>');
  const browser = await chromium.launch();
  console.log('browser=' + browser.version());
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  await page.goto('file://' + process.cwd() + '/counter.html');
  await page.click('#add');
  console.log('count=' + await page.textContent('#count'));
  await page.screenshot({ path: 'counter.png' });
  console.log('counter.png=' + fs.statSync('counter.png').size);
  await page.goto('file://' + process.cwd() + '/text.html');
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('DOM.enable');
  await cdp.send('CSS.enable');
  const { root } = await cdp.send('DOM.getDocument');
  for (const selector of ['h1', '#emoji']) {
    const { nodeId } = await cdp.send('DOM.querySelector', { nodeId: root.nodeId, selector });
    const { fonts } = await cdp.send('CSS.getPlatformFontsForNode', { nodeId });
    console.log(selector + '=' + fonts.map(font => font.familyName).join(','));
  }
  await page.screenshot({ path: 'text.png' });
  console.log('text.png=' + fs.statSync('text.png').size);
  await browser.close();
})().catch(error => { console.error(error.message); process.exit(1); });
JS
    out=$(run_offline "$BASE" "cd /tmp && node - <<'JS'
$browser_script
JS") || true
    [[ "$out" == *"count=1"* && "$out" =~ counter\.png=([1-9][0-9]*) ]] \
        && pass "browser, network off: a script loads a page, clicks, and takes a screenshot (${BASH_REMATCH[1]} bytes)" \
        || fail "browser script failed with the network off (got: $out)"
    [[ "$out" == *"h1=Noto Sans CJK SC"* && "$out" =~ text\.png=([1-9][0-9]*) ]] \
        && pass "browser fonts: Chinese text is drawn with Noto Sans CJK SC" \
        || fail "browser fonts: Chinese text is not drawn with Noto Sans CJK SC (got: $out)"
    [[ "$out" == *"#emoji=Noto Color Emoji"* ]] \
        && pass "browser fonts: an emoji is drawn with Noto Color Emoji" \
        || fail "browser fonts: an emoji is not drawn with Noto Color Emoji (got: $out)"

    # chromium on PATH is the browser Playwright installed and just started.
    browser_version=$(sed -n 's/^browser=//p' <<<"$out")
    out=$(run_in "$BASE" 'chromium --version') && [[ -n "$browser_version" && "$out" == *"$browser_version"* ]] \
        && pass "chromium: $out" \
        || fail "chromium is not the browser Playwright installed (want ${browser_version:-a version}, got: $out)"

    out=$(run_offline "$BASE" 'cd /tmp && printf "<h1>ok</h1>" > page.html && chromium --headless --screenshot=shot.png file:///tmp/page.html && test -s shot.png && echo written') \
        && [[ "$out" == *"written"* ]] \
        && pass "chromium --headless --screenshot, network off: writes a PNG" \
        || fail "chromium --headless --screenshot failed (got: $out)"

    # A sandbox with a read-only root file system: the home directory and the
    # browser directory cannot be written, /tmp can. The install command has
    # to return at once all the same, and the browser has to start.
    out=$(RUN_FLAGS="--read-only --tmpfs /tmp:rw,exec" run_offline "$BASE" 'cd /tmp && playwright install chromium && node -e "require(\"playwright\").chromium.launch().then(async b => { console.log(\"launched=\" + b.version()); await b.close(); })" && echo "seconds=$SECONDS"') \
        && [[ "$out" == *"launched="* && "$out" =~ seconds=([0-9]+) ]] && (( BASH_REMATCH[1] < 30 )) \
        && pass "read-only root file system: playwright install returns at once and the browser starts (${BASH_REMATCH[1]} s)" \
        || fail "read-only root file system: playwright install or the browser failed (got: $out)"
fi

# --- GUI image ---
if selected sandbox-gui; then
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

    # chromium is Chrome for Testing at the version this image's Dockerfile
    # pins, which is what chromium-launch starts, whatever command of that
    # name the base image has.
    CFT_PIN=$(sed -n 's/^ARG CFT_VERSION=//p' gui/Dockerfile)
    out=$(run_in "$GUI" 'chromium --version') && [[ "$out" == *"$CFT_PIN"* ]] \
        && pass "chromium: $out" || fail "chromium is not Chrome for Testing $CFT_PIN (got: $out)"

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
fi

# --- Harness image ---
if selected sandbox-harness; then
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
fi

# --- Summary ---
echo
if [ "$FAILURES" -eq 0 ]; then
    printf "\033[32mAll checks passed.\033[0m\n"
else
    printf "\033[31m%d check(s) failed.\033[0m\n" "$FAILURES"
    exit 1
fi
