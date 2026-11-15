---
title: Image catalog manifest and publication
status: implemented
depends_on: []
affects:
  - catalog.yaml
  - .github/workflows/release.yml
  - Makefile
  - test.sh
  - README.md
effort: medium
created: 2026-07-12
updated: 2026-07-12
implemented: 2026-07-12
author: changkun
dispatched_task_id: null
---

# Image catalog manifest and publication

## Overview

This repo is the source of every sandbox image, but the image inventory is
implicit: it is spread across a hardcoded matrix literal in
`.github/workflows/release.yml`, image vars in `Makefile`, prose in
`README.md`, and assertion lists in `test.sh`. Adding a new image directory
means editing all four by hand, and downstream consumers (the Cella control
plane) have no machine-readable view of what images exist or which versions
were published.

This spec introduces `catalog.yaml` as the single source of truth for the
image inventory, generates the CI build matrix from it, and publishes a
digest-pinned `catalog.json` to S3-compatible object storage on every
release so consumers can discover images programmatically.

## Current state

- Images: `base/Dockerfile` (`sandbox-base`, linux/amd64 + linux/arm64) and
  `gui/Dockerfile` (`sandbox-gui`, linux/amd64, `FROM sandbox-base`).
- `.github/workflows/release.yml`: `changes` job does path filtering
  (`base/**`, `gui/**`) via `dorny/paths-filter`; the sandbox matrix is a
  JSON literal containing only `sandbox-gui`. Push happens only on tag
  (`v*`) / release / `workflow_dispatch`; pushes to `main` build without
  pushing.
- Tags via `docker/metadata-action`: `v{{version}}`, `v{{major}}.{{minor}}`,
  `latest`.
- No manifest or catalog file exists anywhere in the repo.

## Design

### catalog.yaml (new, repo root)

One entry per image directory. This file is the inventory; everything else
derives from it.

```yaml
version: 1
images:
  - name: sandbox-base
    context: base
    platforms: [linux/amd64, linux/arm64]
    label: Base
    description: Ubuntu 24.04 with Go, Node.js 22, Python 3, and agent tooling.
  - name: sandbox-gui
    context: gui
    platforms: [linux/amd64]
    from: sandbox-base
    label: GUI
    description: Base plus Xvfb, x11vnc, noVNC, XFCE, and Chrome for Testing.
    defaults:
      cpu_milli: 500
      memory_mb: 1024
      width: 1280
      height: 800
```

- `from` declares the in-repo build dependency: a change to that image (or a
  release build) forces this image to rebuild, and ordering is topological
  (base before dependents). Replaces the hardcoded "base change forces gui"
  logic.
- `defaults` are advisory per-image resource hints that consumers may apply
  at sandbox creation; absent means consumer defaults.

### CI: matrix generation

`release.yml` gains a first job that reads `catalog.yaml` (yq) and emits:

- the paths-filter config (one filter per `context`),
- the build matrix for non-base images (name, context, platforms),
- the topological build order.

The existing `build-base` / `build-sandboxes` jobs consume these outputs
instead of hardcoded literals. Adding a new image directory plus one
`catalog.yaml` entry is then the complete workflow for step "new Dockerfile
becomes a usable image". Push gating is unchanged: only tags, releases, and
manual dispatch publish.

### CI: catalog publication

A new `publish-catalog` job runs after all build jobs succeed, only on
push-eligible events. It composes `catalog.json` from `catalog.yaml` plus
the per-job `docker/build-push-action` `digest` outputs:

```json
{
  "version": 1,
  "source": { "repo": "latere-ai/sandbox-images", "commit": "<sha>", "tag": "v0.0.13" },
  "images": [
    {
      "name": "sandbox-gui",
      "ref": "ghcr.io/latere-ai/sandbox-gui:v0.0.13",
      "digest": "sha256:...",
      "platforms": ["linux/amd64"],
      "label": "GUI",
      "description": "...",
      "defaults": { "cpu_milli": 500, "memory_mb": 1024, "width": 1280, "height": 800 }
    }
  ]
}
```

`ref` is the immutable semver tag, never `latest`: consumers string-match
refs for warm-cache invalidation, so a mutable tag would mask drift.

Upload targets an S3-compatible endpoint configured entirely through repo
secrets/vars (`CATALOG_S3_ENDPOINT`, `CATALOG_S3_REGION`,
`CATALOG_S3_BUCKET`, `CATALOG_S3_PREFIX`, `CATALOG_S3_ACCESS_KEY`,
`CATALOG_S3_SECRET_KEY`); no storage coordinates are committed. Two writes
per release:

- `${PREFIX}/catalog.json` (current, overwritten each release)
- `${PREFIX}/history/<tag>.json` (immutable audit trail)

The JSON schema above is the public contract with consumers; bump the
top-level `version` field on breaking changes.

### Makefile and test.sh

- `Makefile` derives its image list from `catalog.yaml` (yq) instead of
  per-image vars; `make base` / `make gui` behavior is unchanged.
- `test.sh` iterates `catalog.yaml` entries for the per-image existence
  checks; image-specific assertion blocks remain keyed by name.

## Acceptance criteria

1. `catalog.yaml` exists and lists both current images; a schema comment
   documents every field.
2. `release.yml` contains no hardcoded image names outside the checkout of
   `catalog.yaml` (grep gate in CI).
3. A release event publishes all images and uploads `catalog.json` with a
   valid digest per image; the workflow fails if any digest is missing.
4. A push to `main` still builds changed images without pushing and without
   touching S3.
5. Adding a throwaway third image directory plus one catalog entry makes it
   build in CI with no workflow edits (verified once on a branch, then
   reverted).
6. `README.md` documents `catalog.yaml`, the publication flow, and the
   `catalog.json` contract.

## Non-goals

- Changing the tag-gated push policy (main pushes stay build-only).
- Any consumer-side behavior: how the control plane ingests, curates, or
  warms images is out of scope here.
- Image signing / SBOM (tracked separately by the consumer's supply-chain
  spec).

## Verification

1. Tag `v0.0.13-pilot`: both images appear on GHCR, `catalog.json` and
   `history/v0.0.13-pilot.json` appear in the bucket, digests match
   `docker manifest inspect`.
2. Push a `gui/`-only change to `main`: only `sandbox-gui` builds, nothing
   is pushed or uploaded.
3. `sh test.sh v0.0.13-pilot` passes against the published images.

## Rollback

Revert the spec commits; `release.yml` recovers its literal matrix from
history. Published catalog objects are inert data and can stay.

## Outcome (2026-07-12)

Implemented across four commits. Deviations from the plan, all
deliberate:

- All derivation logic is consolidated in one `catalog.sh`
  (`lint | filters | matrix | compose | build | clean`) so the workflow,
  Makefile, and local builds share one code path. `catalog_test.sh`
  (25 checks) covers filters, matrix propagation along `from` edges,
  compose digest-joining and failure on a missing digest, and lint
  fixtures including the workflow grep gate; it runs in the CI catalog
  job on every event.
- `catalog.yaml` gained a `registry` field so the registry is also
  catalog-driven; lint enforces `from` targets are declared earlier,
  which makes list order the build order (single-pass propagation).
- The Makefile delegates to `catalog.sh build` instead of deriving
  per-image vars via yq; targets are the context dirs, unchanged UX.
- Acceptance 3 and 5 are verified locally (compose against fake digest
  dirs; matrix/lint against a fixture with an extra image) but not yet
  in a live CI run: the next `v*` tag is the first real exercise, and
  it will fail deliberately in publish-catalog until the `CATALOG_S3_*`
  repository secrets are configured.
