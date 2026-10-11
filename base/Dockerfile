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
# other program; the build fails if fontconfig stops choosing Noto CJK.
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
    && rm /etc/fonts/conf.d/65-wqy-microhei.conf \
    && fc-cache -f \
    && for face in zh-cn:SC zh-tw:TC ja:JP ko:KR; do \
        fc-match "sans-serif:lang=${face%:*}" | grep -q "Noto Sans CJK ${face#*:}" \
            || { echo "fontconfig does not choose Noto Sans CJK ${face#*:} for ${face%:*}" >&2; exit 1; }; \
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

USER ${USERNAME}
ENV NPM_CONFIG_PREFIX=/home/${USERNAME}/.npm-global
ENV PATH=$PATH:/home/${USERNAME}/.npm-global/bin
WORKDIR /workspace
