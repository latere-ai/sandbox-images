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
| `sandbox-base` | `ghcr.io/latere-ai/sandbox-base` | amd64, arm64 | Ubuntu 24.04, Go and Go tooling, Node.js 22, Python 3, and a non-root `agent` user |
| `sandbox-gui` | `ghcr.io/latere-ai/sandbox-gui` | amd64 | the base plus an X display, the mutter window manager, a VNC server behind noVNC, and Chrome for Testing |
| `sandbox-harness` | `ghcr.io/latere-ai/sandbox-harness` | amd64, arm64 | the base plus the Claude Code and Codex CLIs |

`sandbox-gui` and `sandbox-harness` are built FROM `sandbox-base`, so
everything in the base is in both.

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
- **Python**: 3 with pip and venv.
- **User**: `agent` (UID and GID 1000) with passwordless sudo, home
  `/home/agent`, working directory `/workspace`.

**sandbox-gui**

- Xvfb on display `:0`, the mutter window manager, x11vnc, and websockify
  serving the noVNC web client on port `6080`.
- Chrome for Testing as `chromium`, and `chromium-launch`, which starts it
  with flags suited to a container. Where the home directory is read-only,
  as in a sandbox with a read-only root file system, `chromium-launch` keeps
  the browser profile under `$TMPDIR` (or `/tmp`) instead.
- xdotool, xdpyinfo, ImageMagick, socat, and DejaVu, Noto CJK, and Noto
  Color Emoji fonts.

**sandbox-harness**

- The Claude Code and Codex CLIs, at the versions pinned in
  [`harness/Dockerfile`](harness/Dockerfile). They are installed under
  `/usr/local`, outside the home directory, so a volume mounted over
  `/home/agent` does not hide them.
- `~/.claude` and `~/.codex` already exist, owned by `agent`, so a single
  credential file can be mounted into either one.

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

The shell runs as `agent`. To add a command-line tool, install it inside the
container, for example `npm install -g <package>`.

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
