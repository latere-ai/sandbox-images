# Changelog

What changed in the images, for whoever runs them and for the agents that
work in them, one section per release.

## Unreleased

## v0.0.22 - 2026-10-14

### Fixed

- In `sandbox-base`, a project's own Playwright, at any version, downloads
  its browser with `npx playwright install [--with-deps] chromium` and
  starts it in a sandbox whose root file system is read-only. There the
  install failed after about eight minutes with
  `EROFS: read-only file system, mkdir '/opt/playwright/browsers/__dirlock'`,
  and the browser then could not start, because every Playwright used the
  image's browser directory, which such a sandbox cannot write. The image
  now sets `PLAYWRIGHT_BROWSERS_PATH=0`, so each Playwright keeps its
  browsers in its own package: a project's in its `node_modules`, where a
  browser downloaded in `/workspace` is still there after a restart, and the
  image's own under `/opt/playwright` as before. Python's Playwright, in a
  virtual environment or not, installs and starts its browser there too.
- `npm link playwright` works in a sandbox whose root file system is
  read-only, so an ES module there imports the installed Playwright. It
  failed with `EROFS: read-only file system, chmod`.

### Changed

- A project that installs the image's own Playwright version from the
  registry downloads its browser as well, as a project on any other version
  does; it used to find the image's. `require('playwright')`,
  `npx playwright`, and `npm link playwright` still start the installed
  browser with nothing to download.
- Python's Playwright at the image's version also downloads its browser,
  with `python -m playwright install chromium`. Outside an activated
  virtual environment, `playwright` on `PATH` is the image's Node.js command
  line, which installs nothing for Python.

## v0.0.21 - 2026-10-13

### Fixed

- In `sandbox-base`, `npx playwright install --with-deps chromium` and
  `npx playwright install-deps` succeed where sudo cannot run, as in a
  sandbox started with the no-new-privileges flag. They failed there with
  `sudo: The "no new privileges" flag is set`, and an agent took that to
  mean the browser could not run. The image now has every package that
  Playwright's `install-deps chromium` names for Ubuntu 24.04, and an apt
  install of packages the image already has succeeds with nothing run.

### Added

- A project that pins a Playwright version other than the image's
  downloads that version's Chromium with `npx playwright install chromium`
  and starts it with nothing else to install. Checked with Playwright
  1.49.1, 1.58.2, and 1.65.0-alpha, beside the image's 1.64.0.
- Xvfb, so `xvfb-run` gives a browser with a window a virtual display.
- The fonts Playwright installs for its browsers: WenQuanYi Zen Hei, IPA
  Gothic, Loma, GNU FreeFont, GNU Unifont, and X11's Cyrillic and scalable
  fonts. Thai text now has a font, Loma. Noto CJK still draws Chinese,
  Japanese, and Korean text, with or without a language set.

### Changed

- `sandbox-base` is about 89 MB larger.
