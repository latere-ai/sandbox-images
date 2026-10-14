FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# --- System packages ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    curl \
    wget \
    vim \
    jq \
    unzip \
    zip \
    ca-certificates \
    gnupg \
    openssh-client \
    sudo \
    locales \
    ripgrep \
    python3 \
    python3-pip \
    python3-venv \
    && locale-gen en_US.UTF-8 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# --- Go ---
# The toolchain is downloaded to disk and checked against a pinned digest
# before anything is extracted: this compiler builds every binary in this
# image and in every image FROM it, so a substituted tarball would reach
# all of them with nothing to catch it. Checksums come from the official
# index (https://go.dev/dl/?mode=json) and must be updated in the same
# commit as GO_VERSION; the build fails loudly if they drift.
ARG GO_VERSION=1.27.0
ARG GO_SHA256_amd64=675c26c449cbb18fc24b74650de1eabbae6e16f64326fd85a283fb3b58280685
ARG GO_SHA256_arm64=51798d2c42d0e1c6ed7fd9f48728b4193abac9e8aad6dbac2fe96a81f5909bda
RUN ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
        amd64) SHA="${GO_SHA256_amd64}" ;; \
        arm64) SHA="${GO_SHA256_arm64}" ;; \
        *) echo "no pinned Go checksum for arch: $ARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -o /tmp/go.tar.gz && \
    echo "${SHA}  /tmp/go.tar.gz" | sha256sum -c - && \
    tar -C /usr/local -xzf /tmp/go.tar.gz && \
    rm /tmp/go.tar.gz && \
    ln -s /usr/local/go/bin/go /usr/local/bin/go && \
    ln -s /usr/local/go/bin/gofmt /usr/local/bin/gofmt

# --- Go tools ---
# Major tools are pinned to specific versions for reproducibility.
# Utility tools use @latest (stable, rarely breaking).
ARG GOPLS_VERSION=v0.21.1
ARG DLV_VERSION=v1.24.2
ARG GOLANGCI_LINT_VERSION=v2.13.1
ENV GOPATH=/root/go
ENV PATH=$PATH:/root/go/bin
RUN go install golang.org/x/tools/gopls@${GOPLS_VERSION} && \
    go install golang.org/x/tools/cmd/goimports@latest && \
    go install golang.org/x/tools/cmd/gorename@latest && \
    go install golang.org/x/tools/cmd/godoc@latest && \
    go install github.com/go-delve/delve/cmd/dlv@${DLV_VERSION} && \
    go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@${GOLANGCI_LINT_VERSION} && \
    go install honnef.co/go/tools/cmd/staticcheck@latest && \
    go install github.com/fatih/gomodifytags@latest && \
    go install github.com/josharian/impl@latest && \
    go install github.com/cweill/gotests/gotests@latest && \
    go install github.com/rogpeppe/godef@latest && \
    go install github.com/ramya-rao-a/go-outline@latest && \
    go install github.com/securego/gosec/v2/cmd/gosec@latest && \
    rm -rf /root/go/pkg /root/.cache/go-build
# Move tools to /usr/local so they are available to all users
RUN cp /root/go/bin/* /usr/local/bin/ && rm -rf /root/go
ENV GOPATH=
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- Node.js 22 LTS ---
# Install Node.js from a signed apt source instead of piping a remote setup
# script into bash. The signing key is vendored in this context rather than
# fetched at build time: downloading it from deb.nodesource.com would trust
# the same host whose packages it is meant to verify, so a compromise there
# would serve both a substituted key and packages signed with it. Reviewing
# the key means reviewing nodesource.gpg.key in git. The build asserts the
# primary fingerprint so an edit to that file cannot swap the trust anchor
# unnoticed, and signed-by scopes the keyring to this source alone.
ARG NODE_MAJOR=22
ARG NODE_KEY_FPR=6F71F525282841EEDAF851B42F59B5F99B1BE0B4
COPY nodesource.gpg.key /tmp/nodesource.gpg.key
RUN gpg --show-keys --with-colons --with-fingerprint /tmp/nodesource.gpg.key \
        | awk -F: '$1 == "fpr" { print $10; exit }' \
        | grep -qx "${NODE_KEY_FPR}" \
        || { echo "nodesource.gpg.key does not match NODE_KEY_FPR" >&2; exit 1; } && \
    gpg --dearmor -o /usr/share/keyrings/nodesource.gpg /tmp/nodesource.gpg.key && \
    rm /tmp/nodesource.gpg.key && \
    echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# --- Charts, documents, and data ---
# What a chart, a PDF, a spreadsheet, or a Word file needs is in the image,
# because a sandbox with a fraction of a CPU core takes minutes to install
# it at run time. The libraries are Ubuntu's packages: they are built for the
# system Python and import with no setup.
#
# python-is-python3 provides the `python` command, which scripts and people
# use as often as `python3`. poppler-utils is pdftotext, pdftoppm, and
# pdfinfo. poppler-data holds the character maps they need for PDFs whose
# Chinese, Japanese, or Korean text uses a font the file does not embed; it
# is a recommended package, which this install skips unless it is named.
# fontconfig provides fc-list and fc-match, which show the fonts present.
#
# Fonts: DejaVu and Liberation cover Latin, Greek, and Cyrillic, and
# Liberation has the metrics of Arial, Times New Roman, and Courier New.
# Noto CJK covers Chinese, Japanese, and Korean for everything that finds
# fonts through fontconfig. Two libraries here cannot rely on it: reportlab
# embeds TrueType outlines only, and Noto CJK's are PostScript; matplotlib
# reads only the first face of a font collection, which in Noto CJK is the
# Japanese one. WenQuanYi Micro Hei is a TrueType font with Chinese glyph
# forms that both can use. Its fontconfig rule is removed, because the rule
# puts the font ahead of Noto CJK for Japanese and Korean text in every
# other program.
#
# The fonts from fonts-unifont on are, with Liberation and Noto Color Emoji,
# the fonts in the list of packages `playwright install-deps` installs. They
# are here so that it finds every package in its list installed (see the
# headless browser below). Loma draws Thai, which no other font here has.
# WenQuanYi Zen Hei and the IPA fonts would take Japanese and Korean text,
# and text with no language set, from Noto CJK; 62-noto-cjk.conf keeps Noto
# CJK first for all three languages. The build fails if fontconfig stops
# choosing Noto CJK for any of them, in any generic family.
COPY 62-noto-cjk.conf /etc/fonts/conf.d/62-noto-cjk.conf
RUN apt-get update && apt-get install -y --no-install-recommends \
    python-is-python3 \
    python3-matplotlib \
    python3-numpy \
    python3-pandas \
    python3-pil \
    python3-reportlab \
    python3-pypdf \
    python3-openpyxl \
    python3-docx \
    python3-requests \
    python3-bs4 \
    python3-lxml \
    python3-yaml \
    poppler-utils \
    poppler-data \
    fontconfig \
    fonts-dejavu-core \
    fonts-liberation \
    fonts-noto-cjk \
    fonts-wqy-microhei \
    fonts-unifont \
    fonts-freefont-ttf \
    fonts-ipafont-gothic \
    fonts-tlwg-loma-otf \
    fonts-wqy-zenhei \
    xfonts-cyrillic \
    xfonts-scalable \
    && rm /etc/fonts/conf.d/65-wqy-microhei.conf \
    && fc-cache -f \
    && for face in zh-cn:SC zh-tw:TC ja:JP ko:KR; do \
        for generic in sans-serif:Sans serif:Serif "monospace:Sans Mono"; do \
            want="Noto ${generic#*:} CJK ${face#*:}"; \
            [ "$(fc-match -f '%{family[0]}' "${generic%%:*}:lang=${face%:*}")" = "${want}" ] \
                || { echo "fontconfig does not choose ${want} for ${face%:*} ${generic%%:*} text" >&2; exit 1; }; \
        done; \
    done \
    && for generic in sans-serif serif monospace; do \
        fc-match -f '%{family[0]}' "${generic}:charset=4e2d" | grep -q '^Noto Sans CJK' \
            || { echo "fontconfig does not choose Noto Sans CJK for ${generic} text with no language set" >&2; exit 1; }; \
    done \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# matplotlib's defaults, in Ubuntu's /etc/matplotlibrc:
#
# font.family: the stock font, DejaVu Sans, has no Chinese, Japanese, or
# Korean glyphs, so a chart title in those languages draws as empty boxes
# until the script names another font. With the two fonts listed after the
# generic family, matplotlib takes from them only the glyphs DejaVu Sans
# lacks, and Latin text looks as it did.
#
# backend: Agg writes files and opens no window. Ubuntu's default, TkAgg,
# opens one wherever a display exists, as in the GUI image, and a script
# that calls plt.show() then blocks until someone closes the window.
# MPLBACKEND still selects another backend for one process.
#
# python reads both settings back, so the build fails if the file changes
# shape and an edit stops applying.
RUN sed -i \
        -e 's/^backend: .*/backend: Agg/' \
        -e 's/^#font\.family: .*/font.family: sans-serif, WenQuanYi Micro Hei, Noto Sans CJK JP/' \
        /etc/matplotlibrc && \
    MPLCONFIGDIR=/tmp/mplconfig python3 -c "import matplotlib as m; \
        assert m.rcParams['backend'].lower() == 'agg', m.rcParams['backend']; \
        assert m.rcParams['font.family'] == ['sans-serif', 'WenQuanYi Micro Hei', 'Noto Sans CJK JP'], m.rcParams['font.family']" && \
    rm -rf /tmp/mplconfig

# --- Interactive prompt: instance-aware hostname ---
# The sandbox runtime injects CELLA_HOST into each interactive session
# with the human-friendly instance name. A pooled container keeps the
# kernel hostname it was created with (immutable on a running
# container), so rewrite the stock PS1 to prefer CELLA_HOST and fall
# back to \h when it is unset. Patched in /etc/skel so users created by
# child images (useradd -m) inherit it, plus root and the default user
# already materialized from skel. Build fails if the base ever stops
# shipping a \h prompt, so this cannot silently regress.
RUN set -eu; patched=0; \
    for rc in /etc/skel/.bashrc /root/.bashrc /home/ubuntu/.bashrc; do \
        [ -f "$rc" ] || continue; \
        if ! grep -q 'CELLA_HOST' "$rc" && grep -q '\\h' "$rc"; then \
            sed -i 's/\\h/${CELLA_HOST:-\\h}/g' "$rc"; \
        fi; \
        grep -q 'CELLA_HOST' "$rc" && patched=$((patched+1)) || true; \
    done; \
    [ "$patched" -gt 0 ] || { echo 'base .bashrc had no \h prompt to patch' >&2; exit 1; }

# --- Non-root user ---
# Every sandbox runs as a single non-root user (UID 1000) with passwordless
# sudo. The user is created after the skel patch above so its $HOME/.bashrc is
# materialized from the patched /etc/skel. Child images (e.g. gui) inherit this
# user instead of recreating it.
ARG USERNAME=agent
ARG USER_UID=1000
ARG USER_GID=1000
RUN userdel -r ubuntu 2>/dev/null || true && \
    groupdel ubuntu 2>/dev/null || true && \
    groupadd --gid ${USER_GID} ${USERNAME} && \
    useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash ${USERNAME} && \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} && \
    mkdir -p /workspace && \
    chown ${USERNAME}:${USERNAME} /workspace

# --- Headless browser ---
# A web page built in a sandbox is tested in a real browser, and a sandbox
# cannot be relied on to fetch one: the download takes minutes on a fraction
# of a CPU core, and a restricted network may not allow its host. So the
# image carries Chromium and what it needs to start.
#
# These are the packages `playwright install-deps chromium` installs on
# Ubuntu 24.04: the shared libraries Chromium links against, and Xvfb, the
# display that a browser started with a window needs (`xvfb-run`). The fonts
# in the same list are installed with the others above. A sandbox cannot
# install them itself: it runs without root, and where it sets the
# no-new-privileges flag, sudo cannot run at all. With every one present,
# the Chromium that a project's own Playwright downloads, at any version,
# starts as this one does, and `playwright install --with-deps`
# finds nothing to install (see the sudo script below). The build checks
# them against Playwright's own list.
#
# libgbm1 brings Mesa and LLVM with it, about 180 MB that a headless browser
# never loads; Ubuntu packages them as its dependencies.
# fonts-noto-color-emoji is here because without it the browser draws most
# emoji as nothing at all.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libasound2t64 \
    libatk-bridge2.0-0t64 \
    libatk1.0-0t64 \
    libatspi2.0-0t64 \
    libcairo2 \
    libcups2t64 \
    libdbus-1-3 \
    libdrm2 \
    libgbm1 \
    libglib2.0-0t64 \
    libnspr4 \
    libnss3 \
    libpango-1.0-0 \
    libx11-6 \
    libxcb1 \
    libxcomposite1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxkbcommon0 \
    libxrandr2 \
    xvfb \
    fonts-noto-color-emoji \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Playwright is pinned, and the browser build follows from the pin: each
# Playwright release drives one Chromium revision, so a new
# PLAYWRIGHT_VERSION brings a new browser. `playwright install chromium`
# fetches three things, and all three stay, because that command looks for
# all three: Chromium, the headless shell that `chromium.launch()` starts by
# default, and the ffmpeg that records video. With them present, the same
# command run later in a sandbox finds nothing to download.
#
# PLAYWRIGHT_BROWSERS_PATH=0 has each copy of Playwright keep its browsers
# in its own package, in playwright-core/.local-browsers. In the installed
# copy that is a link to /opt/playwright/browsers. A project's own
# Playwright, at any version, downloads its browser into the project's
# node_modules, which a sandbox with a read-only root file system can write,
# in /tmp or in /workspace; in /workspace the browser is still there after
# the sandbox restarts. One browser directory named for every Playwright
# would not do: such a sandbox cannot write a directory in the image, so a
# project's install could neither lock it nor add its browser to it. Each copy
# also keeps its own record of which packages use its browsers, so an
# install by one never removes the browsers of another. A project that
# installs the image's own version from the registry downloads its browser
# too; `npm link playwright` gives a project the installed copy instead.
#
# It all lives under /opt/playwright, outside the home directory, so a volume
# mounted over the home does not hide the browser and a read-only home does
# not stop it. The tree belongs to the sandbox user for two reasons:
# Playwright takes a lock in the browser directory even when it has nothing
# to install, and npm sets the mode of a package's command when it links the
# package into a project. The owner is set in the step that writes the
# files, because a later layer that changed it would hold a second copy of
# every file.
#
# /opt/playwright/chrome names the Chromium binary, whose directory differs
# by revision and by architecture. The build fails if the installed copy's
# browser is not under /opt/playwright/browsers, as when a Playwright
# release stops reading 0 this way, and if a binary lacks a shared library,
# so a browser build that needs one more is caught here and not in a
# sandbox.
ARG PLAYWRIGHT_VERSION=1.64.0
ENV PLAYWRIGHT_BROWSERS_PATH=0
RUN NPM_CONFIG_PREFIX=/opt/playwright npm install -g playwright@${PLAYWRIGHT_VERSION} && \
    npm cache clean --force && \
    core="$(node -p "require('path').dirname(require.resolve('playwright-core/package.json', { paths: ['/opt/playwright/lib/node_modules/playwright'] }))")" && \
    mkdir /opt/playwright/browsers && \
    ln -s /opt/playwright/browsers "${core}/.local-browsers" && \
    /opt/playwright/bin/playwright install chromium && \
    chrome="$(readlink -f "$(node -e "console.log(require('/opt/playwright/lib/node_modules/playwright').chromium.executablePath())")")" && \
    case "${chrome}" in \
        /opt/playwright/browsers/*) ;; \
        *) echo "the installed Playwright looks for its browser at ${chrome}, not under /opt/playwright/browsers" >&2; exit 1 ;; \
    esac && \
    test -x "${chrome}" && \
    ln -s "${chrome}" /opt/playwright/chrome && \
    if find /opt/playwright/browsers -type f -perm -u+x -exec ldd {} + 2>/dev/null | grep 'not found'; then \
        echo 'a browser binary lacks a shared library' >&2; exit 1; \
    fi && \
    chown -R ${USERNAME}:${USERNAME} /opt/playwright && \
    rm -rf /tmp/node-compile-cache

# The three commands are scripts; each explains itself. playwright is the
# installed command line, kept usable where the browser directory is
# read-only. chromium is the browser with the flags a container needs. A
# child image with a browser of its own may point /usr/local/bin/chromium
# at it, so the script itself lives under /opt/playwright, where its path
# stays the same. sudo comes ahead of the system's sudo on PATH: where sudo
# cannot run, it lets an apt install with nothing to do succeed, which is
# what `playwright install --with-deps` and `playwright install-deps` ask
# for here.
COPY --chmod=0755 playwright /usr/local/bin/playwright
COPY --chmod=0755 chromium /opt/playwright/bin/chromium
COPY --chmod=0755 sudo /usr/local/bin/sudo
RUN ln -s /opt/playwright/bin/chromium /usr/local/bin/chromium

USER ${USERNAME}
ENV NPM_CONFIG_PREFIX=/home/${USERNAME}/.npm-global
ENV PATH=$PATH:/home/${USERNAME}/.npm-global/bin

# `require('playwright')` finds the installed Playwright from any directory,
# with no project, through NODE_PATH. Node reads the variable for CommonJS
# only.
ENV NODE_PATH=/opt/playwright/lib/node_modules

# npx looks for a command in the project and then in npm's global directory,
# which for this user is in the home directory, and never on PATH. `npm link`
# records the package there, so `npx playwright` finds it, and
# `npm link playwright` in a project, which is how an ES module imports it,
# has something to link. Without the record npx asks the registry, and with
# the network off it gives up only after about seventy seconds. The command
# npx then runs is pointed at the playwright script, so it behaves as
# `playwright` does.
RUN cd /opt/playwright/lib/node_modules/playwright && npm link && \
    ln -sf /usr/local/bin/playwright ~/.npm-global/bin/playwright && \
    rm -rf ~/.npm /tmp/node-compile-cache

# `playwright install-deps chromium` asks sudo to install Playwright's own
# list of packages for its browser. The build makes that request as a
# sandbox with the no-new-privileges flag would, with the system's sudo
# replaced by a command that fails, so a package in the list that the image
# lacks fails the build and not a `--with-deps` in a sandbox.
RUN printf 'NoNewPrivs:\t1\n' > /tmp/no-new-privileges && \
    SUDO_PROC_STATUS=/tmp/no-new-privileges SUDO_BINARY=/bin/false playwright install-deps chromium && \
    rm -rf /tmp/no-new-privileges /tmp/node-compile-cache

# Puppeteer downloads browsers of its own when it is installed, about 670 MB
# into the home directory. It is told to skip that and to start the
# installed Chromium through the chromium script, which adds the flags
# Puppeteer does not. Only the `puppeteer` package reads these two
# variables; `puppeteer-core` takes the path as `executablePath`.
ENV PUPPETEER_SKIP_DOWNLOAD=true
ENV PUPPETEER_EXECUTABLE_PATH=/opt/playwright/bin/chromium

# pip refuses to install into Ubuntu's Python, which apt manages. With the
# refusal lifted, pip run as this user still cannot write the system
# directories, so it installs for the user under ~/.local and leaves the apt
# packages as installed: `pip install <package>` works with no flag and no
# virtual environment. sudo does not pass the variable on, so
# `sudo pip install` is refused as before. PIP_USER is left unset: it would
# make pip fail inside a virtual environment.
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV PATH=$PATH:/home/${USERNAME}/.local/bin
WORKDIR /workspace
