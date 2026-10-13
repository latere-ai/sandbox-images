# Changelog

What changed in the images, for whoever runs them and for the agents that
work in them, one section per release.

## Unreleased

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
