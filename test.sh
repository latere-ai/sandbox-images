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

# A hosted sandbox runs an image with a read-only root file system. What it
# can write is /tmp and /dev/shm, both empty at every start, and a volume at
# /workspace. sudo cannot become root there (no-new-privileges), the
# container holds no capabilities, and HOME is a directory under /tmp. With
# --read-only, podman also mounts writable directories over /run and
# /var/tmp, which a hosted sandbox does not have; --read-only-tmpfs=false
# stops that, and makes /dev/shm read-only too, so /dev/shm is mounted again.
SANDBOX_FLAGS="--read-only --tmpfs /tmp:rw,exec --security-opt no-new-privileges --cap-drop all -e HOME=/tmp/home"
if [[ "$RUNTIME" == podman ]]; then
    SANDBOX_FLAGS="$SANDBOX_FLAGS --read-only-tmpfs=false --tmpfs /dev/shm:rw,nosuid,nodev"
fi

# run_sandbox is run_in under those conditions, with the volume named by
# WORKSPACE at /workspace. HOME is created first, as the hosted sandbox
# creates it before it runs a command.
run_sandbox() {
    local image="$1"; shift
    RUN_FLAGS="$SANDBOX_FLAGS -v ${WORKSPACE:?}:/workspace ${RUN_FLAGS:-}" run_in "$image" "mkdir -p \"\$HOME\" && $*"
}

# run_where runs a command with the network off, under the conditions its
# first argument names: a writable root; a writable root where sudo cannot
# run; a read-only root with a writable /tmp and the image's HOME; or a
# hosted sandbox.
run_where() {
    local where="$1"; shift
    case "$where" in
        "writable root") run_offline "$@" ;;
        "no new privileges") RUN_FLAGS="--security-opt no-new-privileges ${RUN_FLAGS:-}" run_offline "$@" ;;
        "read-only root") RUN_FLAGS="--read-only --tmpfs /tmp:rw,exec ${RUN_FLAGS:-}" run_offline "$@" ;;
        "hosted sandbox") RUN_FLAGS="--network none ${RUN_FLAGS:-}" run_sandbox "$@" ;;
        *) echo "run_where: unknown conditions '$where'" >&2; return 2 ;;
    esac
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
    # The volume run_sandbox mounts at /workspace. It holds the browsers the
    # projects below download, so it is removed however the run ends.
    WORKSPACE="sandbox-images-test-workspace-$$"
    $RUNTIME volume create "$WORKSPACE" >/dev/null
    trap '$RUNTIME volume rm -f "$WORKSPACE" >/dev/null 2>&1 || true' EXIT

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
    # the installed Playwright has to report it. PLAYWRIGHT_OTHER is another
    # version, which a project of its own installs.
    PLAYWRIGHT_PIN=$(sed -n 's/^ARG PLAYWRIGHT_VERSION=//p' base/Dockerfile)
    PLAYWRIGHT_OTHER="${PLAYWRIGHT_OTHER:-1.58.2}"

    out=$(run_in "$BASE" 'playwright --version') && [[ "$out" == "Version $PLAYWRIGHT_PIN" ]] \
        && pass "playwright: $out" || fail "playwright version (want $PLAYWRIGHT_PIN, got: $out)"

    out=$(run_offline "$BASE" 'cd /tmp && printf "<h1>ok</h1>" > page.html && playwright screenshot file:///tmp/page.html shot.png && test -s shot.png && echo written') \
        && [[ "$out" == *"written"* ]] \
        && pass "playwright screenshot, network off: writes a PNG" \
        || fail "playwright screenshot failed with the network off (got: $out)"

    # A page with a button and a counter, loaded from a file by a script that
    # requires Playwright from a directory with no project: the click has to
    # change the count, and a 1280x800 screenshot has to come out. The second
    # page is Chinese, Japanese, and Korean text and an emoji. The browser
    # reports the font that drew each, and a font without the glyphs would
    # show as another family.
    read -r -d '' browser_script <<'JS' || true
const fs = require('fs');
const { chromium } = require('playwright');
(async () => {
  fs.writeFileSync('counter.html', `<p id="count">0</p><button id="add">Add one</button>
<script>let n = 0; document.getElementById('add').onclick = () => { document.getElementById('count').textContent = String(++n); };</script>`);
  fs.writeFileSync('text.html', '<html lang="zh-CN"><meta charset="utf-8"><h1>北京与上海气温</h1><p id="ja" lang="ja">東京の気温</p><p id="ko" lang="ko">서울</p><p id="emoji">&#x1F680;</p></html>');
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
  for (const selector of ['h1', '#ja', '#ko', '#emoji']) {
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
    # The image has other fonts with Japanese and Korean glyphs, which
    # Playwright's list of packages names; Noto CJK has to draw both all the
    # same.
    grep -qx '#ja=Noto Sans CJK JP' <<<"$out" && grep -qx '#ko=Noto Sans CJK KR' <<<"$out" \
        && pass "browser fonts: Japanese and Korean text are drawn with Noto Sans CJK JP and KR" \
        || fail "browser fonts: Japanese or Korean text is drawn with another font (got: $(grep '^#' <<<"$out" | tr '\n' ' '))"
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

    # The installed Playwright where the root file system is read-only, with
    # the image's HOME and in a hosted sandbox: the browser directory and the
    # home directory cannot be written there. The install command has to
    # return at once all the same, and the browser has to start.
    for where in "read-only root" "hosted sandbox"; do
        out=$(run_where "$where" "$BASE" 'cd /tmp && playwright install chromium && node -e "require(\"playwright\").chromium.launch().then(async b => { console.log(\"launched=\" + b.version()); await b.close(); })" && echo "seconds=$SECONDS"') \
            && [[ "$out" == *"launched="* && "$out" =~ seconds=([0-9]+) ]] && (( BASH_REMATCH[1] < 30 )) \
            && pass "$where, network off: playwright install returns at once and the browser starts (${BASH_REMATCH[1]} s)" \
            || fail "$where: playwright install or the browser failed (got: $out)"
    done

    # What someone types first, in a directory with no project and with the
    # network off: npx has to find the installed Playwright, and the install
    # command has to find the browser and return. Thirty seconds is far above
    # the second or two this takes, and below the minute and more npx spends
    # before it gives up on a registry it cannot reach.
    for where in "writable root" "read-only root" "hosted sandbox"; do
        out=$(run_where "$where" "$BASE" 'cd "$(mktemp -d)" && npx playwright --version && npx playwright install chromium && echo "seconds=$SECONDS"') \
            && [[ "$out" == *"Version $PLAYWRIGHT_PIN"* && "$out" =~ seconds=([0-9]+) ]] && (( BASH_REMATCH[1] < 30 )) \
            && pass "npx playwright install chromium, network off, $where: nothing to download (${BASH_REMATCH[1]} s)" \
            || fail "npx playwright did not use the installed Playwright ($where, got: $out)"
    done

    # An ES module does not see NODE_PATH. `npm link playwright` gives the
    # project the installed copy, with the network off.
    for where in "writable root" "hosted sandbox"; do
        out=$(run_where "$where" "$BASE" 'cd "$(mktemp -d)" && npm link playwright >/dev/null && printf "import { chromium } from \"playwright\";\nconst browser = await chromium.launch();\nconsole.log(\"esm=\" + browser.version());\nawait browser.close();\n" > check.mjs && node check.mjs') \
            && [[ "$out" == *"esm="[0-9]* ]] \
            && pass "ES module, network off, $where: npm link playwright, then import" \
            || fail "ES module could not import the installed Playwright ($where, got: $out)"
    done

    # A browser with a window, on the virtual display Xvfb gives it. As
    # process 1, xvfb-run waits forever for Xvfb to say it is ready, so the
    # command after it keeps bash as process 1 and xvfb-run its child, as a
    # command in a sandbox is.
    for where in "writable root" "hosted sandbox"; do
        out=$(run_where "$where" "$BASE" 'xvfb-run -a node -e "require(\"playwright\").chromium.launch({ headless: false }).then(async b => { const p = await b.newPage(); console.log(\"headed=\" + await p.evaluate(() => screen.width)); await b.close(); })" && echo exited') \
            && [[ "$out" =~ headed=([1-9][0-9]*) ]] \
            && pass "xvfb-run, network off, $where: a browser with a window starts (screen ${BASH_REMATCH[1]} px wide)" \
            || fail "xvfb-run could not start a browser with a window ($where, got: $out)"
    done

    # Where sudo cannot run, as with the no-new-privileges flag alone and in
    # a hosted sandbox. Playwright's install of its browser's system packages
    # asks sudo for them all the same; the image has every one, so the
    # command has nothing to install and succeeds, with the network off.
    for where in "no new privileges" "hosted sandbox"; do
        out=$(run_where "$where" "$BASE" 'cd "$(mktemp -d)" && npx playwright install --with-deps chromium && npx playwright install-deps chromium && echo "with-deps=ok seconds=$SECONDS"') \
            && [[ "$out" == *"with-deps=ok"* && "$out" =~ seconds=([0-9]+) ]] && (( BASH_REMATCH[1] < 30 )) \
            && pass "$where, network off: playwright install --with-deps chromium and install-deps succeed (${BASH_REMATCH[1]} s)" \
            || fail "$where: playwright install --with-deps chromium failed (got: $out)"
    done

    # A project on another Playwright version in a hosted sandbox, once in
    # /tmp and once in /workspace. Its Playwright downloads its own Chromium,
    # a few hundred MB, and `--with-deps` and the browser have to work with
    # what the image has. Then a new sandbox on the same volume, with the
    # network off, starts the browser of the project in /workspace again: a
    # sandbox that restarts keeps it. Playwright prints why an install failed
    # among its progress lines, so the end of them is kept for the failure.
    other_script="const { chromium } = require(process.cwd() + '/node_modules/playwright'); chromium.launch().then(async b => { const p = await b.newPage(); await p.setContent('<title>other</title>'); console.log('other=' + await p.title() + ' ' + b.version()); await b.close(); })"
    for dir in /tmp/other /workspace/other; do
        out=$(run_sandbox "$BASE" "mkdir -p $dir && cd $dir && npm init -y >/dev/null && npm install --silent --no-audit --no-fund -D playwright@${PLAYWRIGHT_OTHER} && { npx playwright install --with-deps chromium >install.log 2>&1 || { tail -n 5 install.log; false; }; } && node -e \"$other_script\"") \
            && [[ "$out" == *"other=other "* ]] \
            && pass "playwright@${PLAYWRIGHT_OTHER} in a project in ${dir%/*}, hosted sandbox: install --with-deps and its own Chromium start (${out##*other=other })" \
            || fail "playwright@${PLAYWRIGHT_OTHER} in a project in ${dir%/*}, hosted sandbox: could not install or start its Chromium (got: $out)"
    done
    out=$(run_where "hosted sandbox" "$BASE" "cd /workspace/other && node -e \"$other_script\"") \
        && [[ "$out" == *"other=other "* ]] \
        && pass "playwright@${PLAYWRIGHT_OTHER} in /workspace, a new hosted sandbox, network off: its Chromium starts with nothing downloaded" \
        || fail "playwright@${PLAYWRIGHT_OTHER} in /workspace: its Chromium did not survive a new sandbox (got: $out)"

    # Python's Playwright, from PyPI into a virtual environment, in a hosted
    # sandbox: its own command line downloads its browser, and the browser
    # starts. No version is named, as a person installing it names none.
    read -r -d '' python_script <<'PY' || true
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page()
    page.set_content("<title>python</title>")
    print("python=" + page.title() + " " + browser.version)
    browser.close()
PY
    out=$(run_sandbox "$BASE" "python -m venv /tmp/venv && /tmp/venv/bin/pip install --quiet playwright && { /tmp/venv/bin/playwright install chromium >/tmp/install.log 2>&1 || { tail -n 5 /tmp/install.log; false; }; } && /tmp/venv/bin/python - <<'PY'
$python_script
PY") && [[ "$out" == *"python=python "* ]] \
        && pass "Python Playwright in a virtual environment, hosted sandbox: playwright install chromium, then its browser starts (${out##*python=python })" \
        || fail "Python Playwright in a virtual environment, hosted sandbox: could not install or start its browser (got: $out)"

    # Puppeteer, installed from the registry into /workspace in a hosted
    # sandbox, then run with the network off on a writable root and in a
    # hosted sandbox. The install must not fetch Puppeteer's own browsers,
    # and a launch with no arguments must start the installed Chromium. No
    # version is named: a failure here that the image did not cause means the
    # pinned browser has fallen behind the current Puppeteer.
    read -r -d '' puppeteer_script <<'JS' || true
const puppeteer = require('puppeteer');
(async () => {
  const browser = await puppeteer.launch();
  const page = await browser.newPage();
  await page.setContent('<button onclick="this.textContent = 1">0</button>');
  await page.click('button');
  console.log('puppeteer=' + await page.$eval('button', button => button.textContent) + ' ' + await browser.version());
  await browser.close();
})().catch(error => { console.error(error.message); process.exit(1); });
JS
    out=$(run_sandbox "$BASE" 'mkdir -p /workspace/puppeteer && cd /workspace/puppeteer && npm install --silent puppeteer && echo "own-browsers=$(ls ~/.cache/puppeteer 2>/dev/null | wc -l)"') \
        && [[ "$out" == *"own-browsers=0"* ]] \
        && pass "puppeteer, hosted sandbox: its install downloads no browser" \
        || fail "puppeteer: its install downloaded a browser or failed (got: $out)"
    for where in "writable root" "hosted sandbox"; do
        flags=""
        if [[ "$where" == "writable root" ]]; then flags="-v $WORKSPACE:/workspace"; fi
        out=$(RUN_FLAGS="$flags" run_where "$where" "$BASE" "cd /workspace/puppeteer && node - <<'JS'
$puppeteer_script
JS") && [[ "$out" == *"puppeteer=1 "* ]] \
            && pass "puppeteer, network off, $where: starts the installed Chromium and clicks (${out#puppeteer=1 })" \
            || fail "puppeteer could not start the installed Chromium ($where, got: $out)"
    done
    $RUNTIME volume rm "$WORKSPACE" >/dev/null 2>&1 || fail "could not remove the volume $WORKSPACE"
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

# --- Science image ---
if selected sandbox-science; then
    section "sandbox-science:${TAG}"
    SCIENCE="${REGISTRY}/sandbox-science:${TAG}"
    WORKSPACE="sandbox-images-test-science-$$"
    $RUNTIME volume create "$WORKSPACE" >/dev/null
    trap '$RUNTIME volume rm -f "$WORKSPACE" >/dev/null 2>&1 || true' EXIT

    # The pins live only in science/Dockerfile and science/Rprofile.site; the
    # image has to report them.
    R_PIN=$(sed -n 's/^ARG R_VERSION=//p' science/Dockerfile)
    UV_PIN=$(sed -n 's/^ARG UV_VERSION=//p' science/Dockerfile)
    R_PACKAGES=$(sed -n 's/^ARG R_PACKAGES="\(.*\)"$/\1/p' science/Dockerfile)
    R_RECOMMENDED=$(sed -n 's/^ARG R_RECOMMENDED="\(.*\)"$/\1/p' science/Dockerfile)
    SNAPSHOT=$(sed -n 's/^ *snapshot <- "\(.*\)"$/\1/p' science/Rprofile.site)
    PACKAGES_PATH=$(yq -r '.images[] | select(.name == "sandbox-science") | .packages' catalog.yaml)

    out=$(run_in "$SCIENCE" 'whoami && pwd') && [[ "$out" == $'agent\n/workspace' ]] \
        && pass "user agent, workdir /workspace" || fail "user or workdir wrong (got: $out)"

    # The Python stack imports with nothing installed, in a hosted sandbox
    # with the network off: a read-only root, HOME under /tmp, no privileges.
    modules="scipy statsmodels sklearn pingouin seaborn networkx libpysal spreg shapely geopy pyreadstat"
    out=$(run_where "hosted sandbox" "$SCIENCE" "python - <<'PY'
import importlib
for name in '$modules'.split():
    try:
        print(name + '=' + getattr(importlib.import_module(name), '__version__', '?'))
    except Exception as error:
        print(name + ' failed: ' + repr(error))
PY")
    for module in $modules; do
        grep -q "^$module=" <<<"$out" \
            && pass "python library, hosted sandbox, network off: $(grep "^$module=" <<<"$out")" \
            || fail "python library does not import: $module (got: $(grep "^$module" <<<"$out"))"
    done

    out=$(run_where "hosted sandbox" "$SCIENCE" 'uv --version && uv venv --quiet /tmp/venv && /tmp/venv/bin/python -c "import sys; print(sys.prefix)"') \
        && [[ "$out" == *"uv $UV_PIN"* && "$out" == *"/tmp/venv"* ]] \
        && pass "uv $UV_PIN, hosted sandbox, network off: uv venv uses the image's Python" \
        || fail "uv venv failed (got: $out)"

    # Installs a session makes land where it can write: pip for the user
    # under HOME, beside the image's packages, and uv into a project's
    # virtual environment under /workspace.
    out=$(run_sandbox "$SCIENCE" 'pip install --quiet tomli-w && python -c "import scipy, tomli_w; print(tomli_w.__file__)"') \
        && [[ "$out" == *"/tmp/home/.local/lib/"* ]] \
        && pass "pip install, hosted sandbox: installs under HOME, SciPy still imports" \
        || fail "pip install in a hosted sandbox failed (got: $out)"
    out=$(run_sandbox "$SCIENCE" 'mkdir -p /workspace/project && cd /workspace/project && uv venv --quiet && uv pip install --quiet tomli-w && .venv/bin/python -c "import tomli_w; print(tomli_w.__file__)"') \
        && [[ "$out" == *"/workspace/project/.venv/lib/"* ]] \
        && pass "uv pip install, hosted sandbox: installs into the project's virtual environment" \
        || fail "uv pip install in a hosted sandbox failed (got: $out)"

    out=$(run_in "$SCIENCE" 'R --version | head -n 1') && [[ "$out" == "R version $R_PIN "* ]] \
        && pass "R: $out" || fail "R is not $R_PIN (got: $out)"

    # Every R package the image installs loads, with the network off.
    out=$(run_where "hosted sandbox" "$SCIENCE" "Rscript -e 'for (p in strsplit(\"$R_RECOMMENDED $R_PACKAGES\", \" \")[[1]]) { suppressPackageStartupMessages(library(p, character.only = TRUE)); cat(\"loaded=\", p, \" \", format(packageVersion(p)), \"\\n\", sep = \"\") }'" 2>&1) || true
    for p in $R_PACKAGES; do
        grep -q "^loaded=$p " <<<"$out" \
            && pass "R package, hosted sandbox, network off: ${p} $(sed -n "s/^loaded=$p //p" <<<"$out")" \
            || fail "R package does not load: $p (got: $(tail -n 5 <<<"$out"))"
    done
    loaded=0
    for p in $R_RECOMMENDED; do grep -q "^loaded=$p " <<<"$out" && loaded=$((loaded + 1)); done
    [[ "$loaded" -eq "$(wc -w <<<"$R_RECOMMENDED")" ]] \
        && pass "R's recommended packages load ($loaded)" \
        || fail "R's recommended packages: $loaded of $(wc -w <<<"$R_RECOMMENDED") load"

    # A linear mixed model, the fit the analyses most often need: random
    # intercepts and slopes per subject on lme4's sleepstudy data.
    out=$(run_where "hosted sandbox" "$SCIENCE" "Rscript -e 'library(lme4); fit <- lmer(Reaction ~ Days + (Days | Subject), sleepstudy); cat(\"fixef=\", round(fixef(fit), 2), \"\\n\")'" 2>&1) \
        && [[ "$out" == *"fixef= 251.41 10.47"* ]] \
        && pass "lme4::lmer fits sleepstudy, hosted sandbox, network off: ${out##*fixef= }" \
        || fail "lme4::lmer fit failed (got: $out)"

    # The site profile: Posit's built packages at the image's snapshot, and a
    # user library under HOME that exists before anything is installed.
    out=$(run_where "hosted sandbox" "$SCIENCE" "Rscript -e 'cat(\"repos=\", getOption(\"repos\")[[\"CRAN\"]], \"\\n\", \"lib=\", .libPaths()[1], \" \", dir.exists(.libPaths()[1]), \"\\n\", sep = \"\")'") \
        && [[ "$out" == *"repos=https://packagemanager.posit.co/cran/__linux__/noble/$SNAPSHOT"* && "$out" =~ lib=/tmp/home/[^[:space:]]+\ TRUE ]] \
        && pass "R site profile, hosted sandbox: Posit noble $SNAPSHOT, user library under HOME" \
        || fail "R site profile wrong (got: $out)"

    # Where HOME cannot be written, R leaves the user library out and starts.
    out=$(run_where "read-only root" "$SCIENCE" "Rscript -e 'cat(\"sum=\", 1 + 1, \"\\n\", sep = \"\")'") \
        && [[ "$out" == *"sum=2"* ]] \
        && pass "R, read-only root and read-only HOME: starts" \
        || fail "R does not start where HOME cannot be written (got: $out)"

    # A CRAN package the image lacks, installed by a session into its user
    # library: Posit has to serve it built, so nothing compiles. fastmatch
    # has C code, which a source install would compile. The library is not
    # created first; the image has to create it.
    read -r -d '' install_script <<'R' || true
stopifnot(!requireNamespace("fastmatch", quietly = TRUE))
install.packages("fastmatch")
library(fastmatch)
cat("installed=", find.package("fastmatch"), "\n", sep = "")
R
    out=$(run_sandbox "$SCIENCE" "cat > /tmp/install.R <<'R' && Rscript /tmp/install.R 2>&1 && echo \"seconds=\$SECONDS\"
$install_script
R")
    [[ "$out" == *"installing *binary* package"* && "$out" != *"*source*"* && "$out" != *"gcc"* && "$out" =~ installed=/tmp/home/R/ && "$out" =~ seconds=([0-9]+) ]] && (( BASH_REMATCH[1] < 60 )) \
        && pass "install.packages(\"fastmatch\"), hosted sandbox: a built package into the user library, nothing compiled (${BASH_REMATCH[1]} s)" \
        || fail "install.packages(\"fastmatch\") in a hosted sandbox did not install a built package (got: $out)"

    # The package list the image publishes: it parses, names every package
    # above, and has a real version for each.
    out=$(run_in "$SCIENCE" "cat $PACKAGES_PATH")
    missing=$(jq -r --arg pip "scipy statsmodels scikit-learn pingouin seaborn networkx libpysal spreg shapely geopy pyreadstat uv" --arg cran "$R_RECOMMENDED $R_PACKAGES" '
        . as $list
        | [($pip | split(" ")[] | select($list.pip[.] == null) | "pip " + .),
           ($cran | split(" ")[] | select($list.cran[.] == null) | "cran " + .),
           ($list[] | to_entries[] | select(.value == "0.0.0" or .value == "") | "version of " + .key)]
        | join(", ")' <<<"$out" 2>&1)
    [[ -z "$missing" ]] \
        && pass "package list at $PACKAGES_PATH: $(jq -r 'to_entries | map("\(.value | length) \(.key)") | join(", ")' <<<"$out")" \
        || fail "package list incomplete or unreadable: $missing"

    $RUNTIME volume rm "$WORKSPACE" >/dev/null 2>&1 || fail "could not remove the volume $WORKSPACE"
fi

# --- Summary ---
echo
if [ "$FAILURES" -eq 0 ]; then
    printf "\033[32mAll checks passed.\033[0m\n"
else
    printf "\033[31m%d check(s) failed.\033[0m\n" "$FAILURES"
    exit 1
fi
