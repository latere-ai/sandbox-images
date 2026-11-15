---
title: Science image and per-image package lists
status: implemented
depends_on: [002-catalog-publish.md]
affects:
  - science/ (new)
  - catalog.yaml
  - catalog.sh
  - catalog_test.sh
  - .github/workflows/release.yml
  - test.sh
  - README.md
  - CONTRIBUTING.md
effort: medium
created: 2026-10-16
updated: 2026-10-16
implemented: 2026-10-16
author: changkun
dispatched_task_id: null
---

# Science image and per-image package lists

## Overview

Statistical work, such as reproducing the analysis of a published paper,
needs more than the base image holds: SciPy, statsmodels, and their
neighbors in Python, and R with the packages for mixed models, ANOVA, and
spatial regression. In a hosted sandbox none of it can be added with apt,
because the root file system is read-only and nothing runs as root. pip and
R can install only into `/tmp` or `/workspace`, and R without binary
packages builds every package from source: tens of minutes per run, and
failures on missing compilers and system libraries.

This spec adds `sandbox-science`, the base image plus a scientific Python
stack and R, and lets an image publish the packages it holds, so an
orchestrator can check what a session asks for against what the image has
before the session starts.

## Design

### The image

`science/Dockerfile` builds FROM `sandbox-base` and installs nothing the base
already has.

- **Python**, the same way the base installs its libraries: Ubuntu 24.04's
  own packages for SciPy, statsmodels, scikit-learn, seaborn, NetworkX,
  Shapely, geopy, and pyreadstat. pingouin, spreg, and uv are not in
  Ubuntu, and Ubuntu's libpysal records its version as 0.0.0; pip installs
  these four into `/usr/local` with `--no-deps`, at pinned versions whose
  requirements Ubuntu's packages meet. The build fails if pip
  reports a broken requirement, if a package exists both in Ubuntu's and in
  pip's directory, or if a small pingouin or spreg fit fails.
- **R** from CRAN's Ubuntu repository (`noble-cran40`), pinned to one
  release, with the repository's signing key vendored in the context and its
  fingerprint asserted, as the base does for NodeSource. Every R package,
  the recommended ones included, comes from Posit Package Manager's binaries
  for Ubuntu 24.04 at one snapshot date: tidyverse, lme4, lmerTest, ordinal,
  car, emmeans, afex, psych, spdep. One source keeps compiled packages
  consistent with each other (lme4 is built against a specific Matrix).
  The system libraries those binaries link against (GDAL, GEOS, PROJ,
  udunits, and the rest) are installed with apt. The build fails if a
  package was built from source, if a shared object lacks a library, or if
  a package does not load.
- **The site profile** (`/etc/R/Rprofile.site`) sets `repos` to the same
  Posit snapshot and `HTTPUserAgent` to the form Posit needs to serve a
  binary, so `install.packages()` in a session also installs a binary. The
  build installs through the same profile.

### Installs in a hosted sandbox

A hosted sandbox runs the image with a read-only root, as `agent`, with
`HOME` under `/tmp`, and writable `/tmp` and `/workspace` only.

- R's user library is R's default `R_LIBS_USER`, under `HOME`. R uses it
  only if it exists, and a non-interactive `install.packages()` fails rather
  than create it, so the site profile creates it at start.
- pip keeps the base's convention: `pip install` installs for the user
  under `~/.local`.
- uv is for virtual environments: `uv venv` in a project directory under
  `/workspace` gives the project an environment of its own. uv prefers the
  image's Python to downloading one, and copies files from its cache rather
  than linking across file systems.

### The package list

The image carries `/usr/share/sandbox-images/packages.json`, written at the
end of the build from what is installed:

```json
{ "pip": { "scipy": "1.11.4", "...": "..." }, "cran": { "lme4": "2.0-6", "...": "..." } }
```

`pip` holds every Python distribution the image's Python sees, by its
normalized name; `cran` holds every R package installed, by R's name.

`catalog.yaml` gains an optional per-image field, `packages`, the absolute
path of that file in the image. On a release, the catalog job reads the file
from each image that declares it, by the digest the release pushed, and
`catalog.json` carries it as the image's `packages`. The field is additive;
`version` stays `1`. `catalog.sh compose` fails when an image declares a
list and none was read, as it does for a missing digest.

## Acceptance criteria

1. `sandbox-science` is in `catalog.yaml`, FROM `sandbox-base`, declared for
   `linux/amd64` at least, with a label, a description, and `packages`.
2. Under the hosted sandbox's conditions: the Python stack imports, every R
   package listed above loads, and an `lme4::lmer` fit on `sleepstudy`
   runs, all with the network off.
3. Under the same conditions with the network on, `install.packages()` of a
   CRAN package the image lacks installs a binary into the user library,
   with nothing compiled.
4. `packages.json` is in the image and parses; `catalog.json` composed for a
   release carries it for every image that declares it, and composition
   fails when one is missing.
5. README, CONTRIBUTING, and CHANGELOG describe the image and the field.

## Non-goals

- A package cache for installs at run time; the orchestrator runs that.
- Package lists for the other images. The field is there for them.
- Composing images (science with a display); each combination would be its
  own catalog entry.

## Outcome (2026-10-16)

Implemented as designed. Where the build differs from the first draft of
the design:

- libpysal comes from PyPI (4.13.0), not from Ubuntu. Ubuntu's package
  records its version as 0.0.0, so `pip check` failed on spreg's requirement,
  and a session's `pip install` of anything needing libpysal would have
  installed a second copy, with NumPy 2 behind it. Newer pingouin, spreg,
  and libpysal releases require NumPy 2; the pins are the last releases that
  run on Ubuntu's NumPy 1.26 stack, and the build's spreg and pingouin fits
  confirm it.
- The duplicate check compares directories, not records: Ubuntu's xarray
  carries two records of itself in one directory.
- `list-packages` reads the Ubuntu package's version for the few Python
  packages whose records say 0.0.0 (kiwisolver, mpmath).
- R's recommended packages come from Posit with the rest, not from apt, so
  every compiled package comes from one source. `r-base-dev` is not
  installed: a package Posit has not built needs a compiler and libraries
  the image may lack.
- The shared-library check found one library the first list missed, libuv,
  which tidyverse's `fs` links against.
- A session's `install.packages()` uses the same Posit snapshot as the
  build, so it never upgrades a package the image holds.
- `catalog.sh packages` reads a list by `create` and `cp`, not by running
  the image, so no emulation is needed for the image's first platform.
- The build does not run uv: under QEMU, when an image is built for another
  platform, `uv --version` crashes with a segmentation fault. `test.sh`
  runs it on the image's own platform.

Verified on local builds FROM the published `sandbox-base` v0.0.22:
`make test`, `./catalog.sh lint`, and `LOCAL=1 bash test.sh latest
sandbox-science` pass on arm64. The amd64 build, under QEMU on an arm64
host, passes every check but the two that run uv, which crash there. The
image is 3.90 GB uncompressed on arm64 (656 MB more than the base) and
3.94 GB on amd64 (664 MB more). The install check discriminates: without the site
profile `install.packages()` fails for want of a writable library, and
without the user agent Posit serves the source and gcc compiles it.
