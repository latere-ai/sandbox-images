# Sandbox Images

[![CI](https://github.com/latere-ai/sandbox-images/actions/workflows/ci.yml/badge.svg)](https://github.com/latere-ai/sandbox-images/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Container images for running coding agents and computer-use sessions in an
isolated environment. Latere's hosted sandboxes, built on
[Cella](https://github.com/latere-ai/cella), run them, and each one also runs
on its own under Docker or Podman.

## Images

| Image | Reference | Platforms | Contents |
| --- | --- | --- | --- |
| `sandbox-base` | `ghcr.io/latere-ai/sandbox-base` | amd64, arm64 | Ubuntu 24.04, Go and Go tooling, Node.js 22, Python 3 with libraries for charts, documents, and data, a headless Chromium with Playwright, and a non-root `agent` user |
| `sandbox-gui` | `ghcr.io/latere-ai/sandbox-gui` | amd64 | the base plus an X display, the mutter window manager, a VNC server behind noVNC, and Chrome for Testing |
| `sandbox-harness` | `ghcr.io/latere-ai/sandbox-harness` | amd64, arm64 | the base plus the Claude Code and Codex CLIs |
| `sandbox-science` | `ghcr.io/latere-ai/sandbox-science` | amd64, arm64 | the base plus statistics in Python (SciPy, statsmodels, scikit-learn, pingouin, spatial regression) and R with tidyverse, lme4, and spdep, all ready to use |

`sandbox-gui`, `sandbox-harness`, and `sandbox-science` are built FROM
`sandbox-base`, so everything in the base is in each.

## What's inside

**sandbox-base**

- **OS**: Ubuntu 24.04 with `build-essential`, `git`, `curl`, `wget`, `vim`,
  `jq`, `ripgrep`, `unzip`, `zip`, `openssh-client`, and `sudo`. The locale
  is `en_US.UTF-8` and the time zone is UTC.
- **Go**: the release pinned by `GO_VERSION` in
  [`base/Dockerfile`](base/Dockerfile), with gopls, goimports, gorename,
  godoc, delve (`dlv`), golangci-lint, staticcheck, gosec, gomodifytags,
  impl, gotests, godef, and go-outline.
- **Node.js**: 22 from the NodeSource apt repository. `npm install -g`
  installs into `~/.npm-global`, which is on `PATH`, so it works without
  root.
- **Python**: 3, as `python` and `python3`, with pip and venv.
  `pip install <package>` works without root and without a virtual
  environment: it installs for the `agent` user into `~/.local`, whose `bin`
  directory is on `PATH`, and leaves the Python packages Ubuntu installed
  as they are.
- **Charts, documents, and data**: matplotlib, NumPy, pandas, Pillow,
  ReportLab, pypdf, openpyxl, python-docx, Requests, Beautiful Soup, lxml,
  and PyYAML, installed from Ubuntu 24.04's own packages, so a chart, a PDF,
  a spreadsheet, or a Word file needs nothing installed first. For reading
  PDFs there are poppler's command-line tools, among them `pdftotext`,
  `pdftoppm`, and `pdfinfo`. matplotlib writes image and PDF files and opens
  no window; set `MPLBACKEND` to choose another backend.
- **Fonts**: DejaVu, Liberation (the metrics of Arial, Times New Roman, and
  Courier New), Noto CJK for Chinese, Japanese, and Korean, and Noto Color
  Emoji, and the fonts Playwright installs for its browsers: WenQuanYi Zen
  Hei, IPA Gothic, Loma for Thai, GNU FreeFont, and GNU Unifont. Noto CJK
  draws Chinese, Japanese, and Korean text whether or not a language is set.
  A matplotlib chart draws such text with no font setting. ReportLab embeds
  TrueType fonts only, which Noto CJK is not: for such text in a PDF,
  register WenQuanYi Micro Hei from
  `/usr/share/fonts/truetype/wqy/wqy-microhei.ttc`.
- **Browser**: Chromium, headless, ready with nothing to download. It is the
  build that [Playwright](https://playwright.dev) drives at the version
  pinned by `PLAYWRIGHT_VERSION` in [`base/Dockerfile`](base/Dockerfile),
  and that Playwright is installed beside it under `/opt/playwright`.
  - `playwright` is on `PATH`, and `require('playwright')` works from any
    directory, with no project and no network.
  - `chromium` starts that build directly, for example
    `chromium --headless --screenshot=page.png page.html`.
  - `npx playwright ...` runs the installed copy, so
    `npx playwright install chromium` finds the browser there and returns at
    once. An ES module sees the installed copy after `npm link playwright`
    in its project, which needs no network either. Both rely on a link under
    `~/.npm-global`, so a volume mounted over the home directory takes them
    away; `playwright` and `require('playwright')` do not depend on it.
  - Puppeteer starts it too. The `puppeteer` package finds it and downloads
    no browser of its own; `puppeteer-core` takes
    `executablePath: process.env.PUPPETEER_EXECUTABLE_PATH`.
  - A project that installs Playwright from the registry has a copy of its
    own, at whatever version it names, and that copy keeps its browser in
    the project's `node_modules`: the image sets
    `PLAYWRIGHT_BROWSERS_PATH=0`. `npx playwright install chromium` in the
    project downloads the browser, which needs the network, and the browser
    starts: the image has every system package that Playwright's
    `install-deps chromium` names for Ubuntu 24.04. This works under a
    read-only root file system as well, in `/tmp` or in `/workspace`, and a
    browser a project in `/workspace` downloaded is still there after a
    restart. A project on the image's own version downloads its browser
    too; `npm link playwright` instead gives it the installed copy and its
    browser.
  - `npx playwright install --with-deps chromium` and
    `npx playwright install-deps` find those packages installed and succeed,
    also where sudo cannot run (see **User** below).
  - Python's Playwright keeps its browser in its own package in the same
    way. After `pip install playwright`, install the browser with
    `python -m playwright install chromium`, which needs the network.
    Outside an activated virtual environment, `playwright` on `PATH` is the
    installed Node.js command line, which installs nothing for Python.
  - `xvfb-run` gives a browser with a window a virtual display, for example
    `xvfb-run npx playwright test --headed`. As a container's own command it
    needs an init process, as `docker run --init` gives it: as process 1 it
    waits forever for the display.

  The browser starts as `agent` with no flags from the caller, and under a
  read-only root file system that has a writable `/tmp`. It runs in 256 MiB
  of memory, where its first start in a new container can take ten seconds
  and more; with 384 MiB that start takes a second or two.
- **User**: `agent` (UID and GID 1000) with passwordless sudo, home
  `/home/agent`, working directory `/workspace`. In a container started
  with the no-new-privileges flag, sudo cannot become root. There,
  `sudo apt-get install` of packages the image already has succeeds with
  nothing run, which is what `playwright install --with-deps` asks for, and
  every other sudo command fails as sudo does under that flag.

**sandbox-gui**

- Xvfb on display `:0`, the mutter window manager, x11vnc, and websockify
  serving the noVNC web client on port `6080`.
- Chrome for Testing as `chromium`, and `chromium-launch`, which starts it
  with flags suited to a container. Where the home directory is read-only,
  as in a sandbox with a read-only root file system, `chromium-launch` keeps
  the browser profile under `$TMPDIR` (or `/tmp`) instead. Behind a proxy
  whose `https_proxy` URL carries a credential, as a Cella sandbox's egress
  gateway does, it hands Chromium the proxy address and signs in for it, so
  no one is asked for the proxy's password. In this image `chromium` is that
  Chrome for Testing; Playwright and Puppeteer keep the headless browser
  from the base image.
- Two commands that start something on the display and keep it running:
  `gui-browser [url...]`, one maximized browser that opens again when it is
  closed, and `gui-desktop [url...]`, a taskbar of the open windows with
  Browser, Terminal (lxterminal), Files (pcmanfm) and Text editor (mousepad)
  launchers, beside a browser. Either is a container's or a sandbox's
  command; with neither, the display stays empty until something is
  started on it.
- xdotool, xdpyinfo, ImageMagick, socat, and DejaVu, Noto CJK, and Noto
  Color Emoji fonts.

**sandbox-harness**

- The Claude Code and Codex CLIs, at the versions pinned in
  [`harness/Dockerfile`](harness/Dockerfile). They are installed under
  `/usr/local`, outside the home directory, so a volume mounted over
  `/home/agent` does not hide them.
- `~/.claude` and `~/.codex` already exist, owned by `agent`, so a single
  credential file can be mounted into either one.

**sandbox-science**

For statistical analysis, such as reproducing the results of a published
paper, with nothing to install first.

- **Python**: SciPy, statsmodels, scikit-learn, pingouin, seaborn, NetworkX,
  GeoPandas, libpysal, spreg, Shapely, geopy, pyreadstat, and xarray, beside
  the base's NumPy, pandas, and matplotlib. Most are Ubuntu 24.04's own
  packages, built against its NumPy 1.26. libpysal, pingouin, spreg, and uv
  come from PyPI, at the releases pinned in
  [`science/Dockerfile`](science/Dockerfile), which work with those.
  `pip install <package>` installs for the user, as in the base. A package
  that requires NumPy 2 does not fit beside these: pip would put NumPy 2
  ahead of Ubuntu's, and SciPy and pandas would no longer import. Give such
  a package a virtual environment of its own, as below.
- **uv**: `uv venv` creates a virtual environment, `.venv` in the current
  directory, from the image's Python 3.12, and `uv pip install` installs a
  project's packages into it. The environment holds only what is installed
  into it, so a project's own versions of NumPy or pandas do not disturb the
  image's. In a sandbox, keep it in the project's directory under
  `/workspace`.
- **R**: the release pinned by `R_VERSION` in
  [`science/Dockerfile`](science/Dockerfile), from CRAN's repository for
  Ubuntu, with tidyverse, lme4, lmerTest, ordinal, car, emmeans, afex, psych,
  spdep, and R's recommended packages (MASS, Matrix, nlme, mgcv, survival,
  and the rest). They are Posit Package Manager's builds for Ubuntu 24.04,
  taken on the snapshot date set in
  [`science/Rprofile.site`](science/Rprofile.site), with the system
  libraries they need, GDAL, GEOS, PROJ, and udunits among them.
- **Installing R packages**: `install.packages("<package>")` fetches Posit's
  build from the same snapshot, so it installs in seconds, compiles nothing,
  and fits the packages already there. It installs into the user library,
  `~/R/<platform>-library/<version>` (`R_LIBS_USER`), which R creates when
  it starts, so it works wherever the home directory can be written, as in
  a sandbox whose `HOME` is under `/tmp`. For a package released after the
  snapshot, point R at the current one first:
  `options(repos = c(CRAN = "https://packagemanager.posit.co/cran/__linux__/noble/latest"))`.
  A package Posit has not built compiles from source, which needs whatever
  compiler and libraries it names; the image has the base's C and C++
  compilers and no Fortran compiler.
- **Package list**: `/usr/share/sandbox-images/packages.json` names every
  Python and R package the image holds, with its version:
  `{"pip": {"scipy": "1.11.4", ...}, "cran": {"lme4": "...", ...}}`. Python
  names are normalized as pip compares them; R names keep R's case. Each
  release also publishes the list in the [image catalog](#image-catalog).

## Running an image

The examples use `docker`; `podman` takes the same arguments. Mount the
project you work on under `/workspace`.

### Base

```bash
docker run --rm -it \
  -v "$(pwd)":/workspace/myproject \
  -w /workspace/myproject \
  ghcr.io/latere-ai/sandbox-base:latest \
  bash
```

The shell runs as `agent`. To add a command-line tool or a library, install
it inside the container, for example `npm install -g <package>` or
`pip install <package>`.

### Harness

Mount the project and the credential file of the CLI you run:

```bash
docker run --rm -it \
  -v "$HOME/.codex/auth.json":/home/agent/.codex/auth.json \
  -v "$(pwd)":/workspace/myproject \
  -w /workspace/myproject \
  ghcr.io/latere-ai/sandbox-harness:latest \
  codex
```

Claude Code reads `/home/agent/.claude/.credentials.json` in the same way.
The container runs as UID 1000, so a mounted file must be readable by that
user.

### GUI

```bash
docker run --rm -it \
  --platform linux/amd64 \
  -p 6080:6080 \
  -v "$(pwd)":/workspace/myproject \
  -w /workspace/myproject \
  ghcr.io/latere-ai/sandbox-gui:latest
```

Then open `http://localhost:6080/vnc.html`.

The entrypoint starts the display, the window manager, the VNC server, and
the noVNC bridge, waits for the display to answer, and then runs the command
you pass, `bash` when you pass none. The container stops when that command
exits. To open a browser on the display directly:

```bash
docker run --rm -it \
  --platform linux/amd64 \
  -p 6080:6080 \
  ghcr.io/latere-ai/sandbox-gui:latest \
  chromium-launch https://example.com
```

For a desktop to work in rather than one program, pass `gui-desktop`; for a
browser that stays open, `gui-browser`. In a Cella sandbox the display comes
from the desktop Cella runs beside the workload, and the same two commands are
the sandbox's command: `command: [gui-desktop]` or
`command: [gui-browser, https://example.com]`.

**The VNC password.** On first start the entrypoint generates a password,
writes it to `/home/agent/.vncpass` with mode 0600, and never prints it. Read
it with:

```bash
docker exec <container> cat /home/agent/.vncpass
```

To choose the password instead, set `VNC_PASSWORD`. VNC authentication uses
at most the first eight characters.

**Platforms.** The GUI image is published for `linux/amd64` only, because
Chrome for Testing publishes no Linux arm64 build. On an arm64 host,
`--platform linux/amd64` runs it under emulation.

**Resources.** Limit a container with the runtime's own flags, for example
`--cpus 2 --memory 4g`.

## Tags

Every release publishes each image under three tags:

| Tag | Points at |
| --- | --- |
| `vX.Y.Z` | that release |
| `vX.Y` | the newest patch release of `X.Y` |
| `latest` | the newest build; maintainers can also rebuild it between releases |

Tool versions inside an image change between releases. The
[image contract](#image-contract) below does not. For a reproducible
environment, pin `vX.Y.Z`, or pin the digest, which the
[image catalog](#image-catalog) records for every image of a release.

## Image contract

What stays the same across releases, for building on these images or running
them from your own orchestration:

- **Working directory**: `/workspace`, writable by `agent`. Mount workspaces
  as subdirectories of it.
- **User**: `agent`, UID and GID 1000, passwordless sudo, `HOME=/home/agent`.
- **Home directory**: the image populates `/home/agent` at build time,
  including the shell prompt setup, `~/.npm-global`, and in the harness
  `~/.claude` and `~/.codex`. A volume mounted over `/home/agent` replaces all
  of it; `/workspace` is the path meant for durable mounts.
- **Prompt**: the shell prompt shows the `CELLA_HOST` environment variable
  when it is set, and the container's host name otherwise.
- **GUI**: the display is `DISPLAY=:0` at `SCREEN_GEOMETRY` (default
  `1280x800x24`, read at start). noVNC listens on `NOVNC_PORT` (default
  `6080`); the VNC server itself listens on port 5900 on the container's
  loopback address only. `VNC_PASSWORD` and `~/.vncpass` behave as described
  above. `tini` is PID 1.

To build your own image on one of these, start from a pinned tag and return
to the `agent` user after installing:

```dockerfile
FROM ghcr.io/latere-ai/sandbox-base:vX.Y.Z
USER root
RUN apt-get update && apt-get install -y --no-install-recommends <packages> \
    && rm -rf /var/lib/apt/lists/*
USER agent
```

## Image catalog

Each release also produces `catalog.json`, a machine-readable list of the
images in that release, so an orchestrator can offer them without hard-coding
names or tags. Latere's hosted sandbox service reads it to build its list of
images.

```json
{
  "version": 1,
  "source": { "repo": "latere-ai/sandbox-images", "commit": "<sha>", "tag": "v0.0.16" },
  "images": [
    {
      "name": "sandbox-gui",
      "ref": "ghcr.io/latere-ai/sandbox-gui:v0.0.16",
      "digest": "sha256:...",
      "platforms": ["linux/amd64"],
      "label": "GUI",
      "description": "...",
      "defaults": { "cpu_milli": 500, "memory_mb": 1024, "width": 1280, "height": 800 }
    },
    {
      "name": "sandbox-science",
      "ref": "ghcr.io/latere-ai/sandbox-science:v0.0.16",
      "digest": "sha256:...",
      "platforms": ["linux/amd64", "linux/arm64"],
      "label": "Science",
      "description": "...",
      "packages": { "pip": { "scipy": "1.11.4", "...": "..." }, "cran": { "lme4": "...", "...": "..." } }
    }
  ]
}
```

- `ref` is always a release tag, never `latest`, and `digest` is the digest
  that release pushed.
- `label` and `description` are short texts for a person choosing an image.
- `defaults` is optional. It holds advisory resource hints (`cpu_milli`,
  `memory_mb`, and for a display, `width` and `height`) that an orchestrator
  may apply when it creates a sandbox.
- `packages` is optional. It is the package list of an image that publishes
  one, read from that release's image: per package manager (`pip`, `cran`),
  each package's name and installed version. An orchestrator can check the
  packages a session asks for against it before the session starts.
- `version` is `1`. A change to the shape that breaks a reader raises it.

The file is generated from [`catalog.yaml`](catalog.yaml), the list of images
this repository builds.

## Contributing

Building the images locally, testing them, adding an image, updating a pinned
version, and cutting a release are covered in
[`CONTRIBUTING.md`](CONTRIBUTING.md).

To report a vulnerability, follow the
[security policy](https://github.com/latere-ai/.github/blob/main/SECURITY.md)
rather than opening an issue.

## License

MIT. See [`LICENSE`](LICENSE).
