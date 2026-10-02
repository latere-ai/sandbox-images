ARG BASE_IMAGE=sandbox-base:latest
FROM ${BASE_IMAGE}

USER root

# GUI stack for future Cella computer-use sandboxes. The VNC server is
# bound to localhost inside the container; orchestration proxies it.
RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb \
    x11vnc \
    mutter \
    dbus-x11 \
    tint2 \
    lxterminal \
    pcmanfm \
    mousepad \
    tango-icon-theme \
    xdotool \
    x11-utils \
    x11-apps \
    imagemagick \
    fonts-dejavu \
    fonts-noto-cjk \
    fonts-noto-color-emoji \
    python3-websockify \
    novnc \
    ca-certificates \
    curl \
    socat \
    tini \
    unzip \
    libnss3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libpango-1.0-0 \
    libcairo2 \
    libasound2t64 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Chrome for Testing is the automation-grade Chromium build used by
# computer-use stacks. Pin the version so image rebuilds are reproducible.
ARG CFT_VERSION=128.0.6613.119
ARG TARGETARCH
RUN set -eux; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in \
        amd64) cft_arch=linux64 ;; \
        *) echo "Chrome for Testing Linux archives are only available for amd64; build this image for linux/amd64" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://storage.googleapis.com/chrome-for-testing-public/${CFT_VERSION}/${cft_arch}/chrome-${cft_arch}.zip" -o /tmp/chrome.zip; \
    unzip -q /tmp/chrome.zip -d /opt; \
    mv "/opt/chrome-${cft_arch}" /opt/chromium; \
    rm /tmp/chrome.zip; \
    ln -s /opt/chromium/chrome /usr/local/bin/chromium; \
    find /opt/chromium/locales -name '*.pak' ! -name 'en-US.pak' -delete

COPY --chmod=0755 entrypoint.sh /usr/local/bin/gui-entrypoint
COPY --chmod=0755 vncpass.sh /usr/local/bin/gui-vncpass
COPY --chmod=0755 supervisor.sh /usr/local/bin/gui-supervisor
COPY --chmod=0755 chromium-launch /usr/local/bin/chromium-launch

# The workload commands that start something on the display: gui-browser, one
# browser, and gui-desktop, a taskbar with the desktop's programs and a
# browser. Each draws on the display this image's entrypoint or a desktop
# beside the sandbox provides, and gui-session is the part they share.
COPY --chmod=0644 session.sh /usr/local/bin/gui-session
COPY --chmod=0755 gui-browser /usr/local/bin/gui-browser
COPY --chmod=0755 gui-desktop /usr/local/bin/gui-desktop
COPY --chmod=0644 desktop/tint2rc /etc/xdg/tint2/gui-desktop.tint2rc
COPY --chmod=0644 desktop/applications/ /usr/share/applications/

# The non-root `agent` user (UID 1000) is created by the base image.
USER agent
ENV DISPLAY=:0
ENV SCREEN_GEOMETRY=1280x800x24
ENV NOVNC_PORT=6080
EXPOSE 6080

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/gui-entrypoint"]
