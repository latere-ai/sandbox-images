#!/bin/bash
#
# Tests for catalog.sh against the live catalog.yaml plus fixtures.
# Usage: bash catalog_test.sh
#
set -euo pipefail
cd "$(dirname "$0")"

FAILURES=0
pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$1"; FAILURES=$((FAILURES + 1)); }
section() { printf "\n\033[1m%s\033[0m\n" "$1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- filters ---
section "filters"
out=$(./catalog.sh filters)
grep -q "^sandbox-base:$" <<<"$out" && grep -q "^  - base/\*\*$" <<<"$out" \
    && pass "base filter emitted" || fail "base filter wrong: $out"
grep -q "^sandbox-gui:$" <<<"$out" && grep -q "^  - gui/\*\*$" <<<"$out" \
    && pass "gui filter emitted" || fail "gui filter wrong: $out"
yq -o=json <<<"$out" >/dev/null 2>&1 \
    && pass "filters output is valid YAML" || fail "filters output is not YAML"

# --- matrix ---
section "matrix"
m=$(./catalog.sh matrix --all)
[[ "$(jq -r '.roots.image[0].name' <<<"$m")" == "sandbox-base" ]] \
    && pass "--all: base in roots" || fail "--all: base missing from roots"
[[ "$(jq -r '.deps.image[0].name' <<<"$m")" == "sandbox-gui" ]] \
    && pass "--all: gui in deps" || fail "--all: gui missing from deps"
[[ "$(jq -r '.roots.image[0].platforms' <<<"$m")" == "linux/amd64,linux/arm64" ]] \
    && pass "--all: platforms joined for buildx" || fail "--all: platforms not joined"
[[ "$(jq -r '.deps.image[0].from' <<<"$m")" == "sandbox-base" ]] \
    && pass "--all: dep carries from" || fail "--all: dep missing from"
[[ "$(jq -r '.registry' <<<"$m")" == "ghcr.io/latere-ai" ]] \
    && pass "--all: registry surfaced" || fail "--all: registry missing"

[[ "$(jq -r '.deps.image[1].name' <<<"$m")" == "sandbox-harness" && "$(jq -r '.deps.image[1].platforms' <<<"$m")" == "linux/amd64,linux/arm64" ]] \
    && pass "--all: harness in deps, multi-arch" || fail "--all: harness wrong: $m"

m=$(./catalog.sh matrix '["sandbox-base"]')
[[ "$(jq -r '.any_root' <<<"$m")" == "true" && "$(jq -c '.deps.image | map(.name)' <<<"$m")" == '["sandbox-gui","sandbox-harness","sandbox-science"]' ]] \
    && pass "base change propagates to gui, harness, and science (from edges)" \
    || fail "base change must rebuild every image built on it: $m"

m=$(./catalog.sh matrix '["sandbox-gui"]')
[[ "$(jq -r '.any_root' <<<"$m")" == "false" && "$(jq -r '.deps.image | length' <<<"$m")" == "1" ]] \
    && pass "gui-only change builds gui alone" || fail "gui-only change wrong: $m"

m=$(./catalog.sh matrix '["sandbox-harness"]')
[[ "$(jq -r '.deps.image | length' <<<"$m")" == "1" && "$(jq -r '.deps.image[0].name' <<<"$m")" == "sandbox-harness" ]] \
    && pass "harness-only change builds harness alone" || fail "harness-only change wrong: $m"

m=$(./catalog.sh matrix '["sandbox-science"]')
[[ "$(jq -r '.any_root' <<<"$m")" == "false" && "$(jq -c '.deps.image | map(.name)' <<<"$m")" == '["sandbox-science"]' ]] \
    && pass "science-only change builds science alone" || fail "science-only change wrong: $m"
[[ "$(jq -r '.deps.image[0].platforms' <<<"$m")" == *"linux/amd64"* ]] \
    && pass "science builds for linux/amd64, the platform hosted sandboxes run" \
    || fail "science must build for linux/amd64: $(jq -r '.deps.image[0].platforms' <<<"$m")"

m=$(./catalog.sh matrix '[]')
[[ "$(jq -r '.any_root' <<<"$m")" == "false" && "$(jq -r '.any_dep' <<<"$m")" == "false" ]] \
    && pass "empty change set builds nothing" || fail "empty change set wrong: $m"

m=$(./catalog.sh matrix --all)
[[ "$(jq -c '.stages | map(.image | map(.name))' <<<"$m")" == '[["sandbox-base"],["sandbox-gui","sandbox-harness","sandbox-science"],[]]' ]] \
    && pass "--all: images staged by FROM depth" || fail "--all: stages wrong: $(jq -c .stages <<<"$m")"
[[ "$(jq -c '.any_stage' <<<"$m")" == '[true,true,false]' ]] \
    && pass "--all: any_stage flags per stage" || fail "--all: any_stage wrong"

# --- compose ---
section "compose"
mkdir -p "$TMP/digests"
printf '{"name":"sandbox-base","digest":"sha256:aaa"}' > "$TMP/digests/sandbox-base.json"
printf '{"name":"sandbox-gui","digest":"sha256:bbb"}' > "$TMP/digests/sandbox-gui.json"
printf '{"name":"sandbox-harness","digest":"sha256:ccc"}' > "$TMP/digests/sandbox-harness.json"
printf '{"name":"sandbox-science","digest":"sha256:ddd"}' > "$TMP/digests/sandbox-science.json"
mkdir -p "$TMP/packages"
printf '{"pip":{"scipy":"1.11.4"},"cran":{"lme4":"2.0-6"}}' > "$TMP/packages/sandbox-science.json"

c=$(./catalog.sh compose v9.9.9 deadbeef "$TMP/digests" "$TMP/packages")
[[ "$(jq -r '.version' <<<"$c")" == "1" ]] \
    && pass "contract version 1" || fail "contract version wrong"
[[ "$(jq -r '.source.tag' <<<"$c")" == "v9.9.9" && "$(jq -r '.source.commit' <<<"$c")" == "deadbeef" ]] \
    && pass "source tag + commit recorded" || fail "source wrong: $(jq -c .source <<<"$c")"
[[ "$(jq -r '.images[0].ref' <<<"$c")" == "ghcr.io/latere-ai/sandbox-base:v9.9.9" ]] \
    && pass "ref pinned to the release tag, not latest" || fail "ref wrong: $(jq -r '.images[0].ref' <<<"$c")"
[[ "$(jq -r '.images[1].digest' <<<"$c")" == "sha256:bbb" ]] \
    && pass "digest joined from build output" || fail "digest join wrong"
[[ "$(jq -r '.images[1].defaults.memory_mb' <<<"$c")" == "1024" ]] \
    && pass "gui defaults carried into contract" || fail "defaults missing"
[[ "$(jq -r '.images[0] | has("defaults")' <<<"$c")" == "false" ]] \
    && pass "base omits defaults" || fail "base must not carry empty defaults"

[[ "$(jq -c '.images[] | select(.name == "sandbox-science") | .packages' <<<"$c")" == '{"pip":{"scipy":"1.11.4"},"cran":{"lme4":"2.0-6"}}' ]] \
    && pass "package list read from the image carried into contract" \
    || fail "science packages missing: $(jq -c '.images[] | select(.name == "sandbox-science")' <<<"$c")"
[[ "$(jq -c '[.images[] | select(has("packages")) | .name]' <<<"$c")" == '["sandbox-science"]' ]] \
    && pass "images that declare no package list carry none" \
    || fail "packages on an image that declares none: $c"

# A release that lost a package list must not publish the image's entry
# without it, as with a lost digest.
if ./catalog.sh compose v9.9.9 deadbeef "$TMP/digests" >/dev/null 2>&1; then
    fail "compose must fail when a declared package list was not read"
else
    pass "compose fails on a missing package list"
fi

rm "$TMP/digests/sandbox-gui.json"
if ./catalog.sh compose v9.9.9 deadbeef "$TMP/digests" "$TMP/packages" >/dev/null 2>&1; then
    fail "compose must fail on a missing digest"
else
    pass "compose fails on a missing digest"
fi

# --- packages: read from the image by a container runtime. A stand-in
# runtime records its calls and serves the file named by FAKE_FILE, so the
# checks need no image and no registry. ---
section "packages"
FAKE="$TMP/fake-runtime"
cat > "$FAKE" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_LOG"
case "$1" in
    create) echo fake-id ;;
    cp) [[ -n "${FAKE_FILE:-}" ]] || exit 1; cp "$FAKE_FILE" "$3" ;;
    rm) ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$FAKE"
export FAKE_LOG="$TMP/fake.log"
read_lists() { : > "$FAKE_LOG"; rm -rf "$TMP/read"; RUNTIME="$FAKE" ./catalog.sh packages "$1" "$TMP/read" >/dev/null 2>&1; }
science_path=$(yq -r '.images[] | select(.name == "sandbox-science") | .packages' catalog.yaml)
science_platform=$(yq -r '.images[] | select(.name == "sandbox-science") | .platforms[0]' catalog.yaml)
printf '{"pip":{"numpy":"1.26.4"},"cran":{"MASS":"7.3-65"}}' > "$TMP/list.json"

FAKE_FILE="$TMP/list.json" read_lists "$TMP/digests" && cmp -s "$TMP/list.json" "$TMP/read/sandbox-science.json" \
    && pass "reads the package list out of the image" \
    || fail "package list not read: $(cat "$FAKE_LOG")"
grep -qx "create --platform $science_platform ghcr.io/latere-ai/sandbox-science@sha256:ddd" "$FAKE_LOG" \
    && pass "addresses the image by the digest this run recorded, on its first platform" \
    || fail "wrong image or platform: $(cat "$FAKE_LOG")"
grep -qx "cp fake-id:$science_path $TMP/read/sandbox-science.json" "$FAKE_LOG" && grep -qx 'rm fake-id' "$FAKE_LOG" \
    && pass "copies the declared path, then removes the container" \
    || fail "wrong copy or container left behind: $(cat "$FAKE_LOG")"
[[ "$(grep -c '^create' "$FAKE_LOG")" == "$(yq '[.images[] | select(.packages)] | length' catalog.yaml)" ]] \
    && pass "reads only the images that declare a package list" \
    || fail "read images without a package list: $(cat "$FAKE_LOG")"

FAKE_FILE="" read_lists "$TMP/digests" \
    && fail "packages must fail when the image lacks the file" \
    || { grep -qx 'rm fake-id' "$FAKE_LOG" \
        && pass "fails when the image lacks the file, and removes the container" \
        || fail "container left behind after a failed copy: $(cat "$FAKE_LOG")"; }

printf '{"pip":["numpy"]}' > "$TMP/bad.json"
FAKE_FILE="$TMP/bad.json" read_lists "$TMP/digests" \
    && fail "packages must reject a list that is not name-version maps" \
    || pass "rejects a list that is not name-version maps"

mkdir -p "$TMP/no-digest"
FAKE_FILE="$TMP/list.json" read_lists "$TMP/no-digest" \
    && fail "packages must fail without a recorded digest" \
    || pass "fails without a recorded digest rather than read another image"

# --- lint: live repo (schema only; the workflow grep gate runs in CI
# and is covered by the fixtures below) ---
section "lint"
out=$(./catalog.sh lint /dev/null 2>&1) \
    && pass "live catalog schema lints clean" || fail "live catalog lint: $out"

# --- lint: fixtures ---
fixture() {
    local d
    for d in base gui harness extra; do
        rm -rf "${TMP:?}/repo/$d"
        mkdir -p "$TMP/repo/$d"; : > "$TMP/repo/$d/Dockerfile"
    done
    cat > "$TMP/repo/catalog.yaml"; cp catalog.sh "$TMP/repo/"
}

fixture <<'EOF'
version: 1
registry: ghcr.io/latere-ai
images:
  - name: sandbox-gui
    context: gui
    platforms: [linux/amd64]
    from: sandbox-base
    label: GUI
    description: x
  - name: sandbox-base
    context: base
    platforms: [linux/amd64]
    label: Base
    description: x
EOF
(cd "$TMP/repo" && ./catalog.sh lint) >/dev/null 2>&1 \
    && fail "lint must reject from-before-declaration" \
    || pass "lint rejects from declared after its dependent"

fixture <<'EOF'
version: 1
registry: ghcr.io/latere-ai
images:
  - name: sandbox-base
    context: missing
    platforms: [linux/amd64]
    label: Base
    description: x
EOF
(cd "$TMP/repo" && ./catalog.sh lint) >/dev/null 2>&1 \
    && fail "lint must reject a context without a Dockerfile" \
    || pass "lint rejects missing Dockerfile"

fixture <<'EOF'
version: 1
registry: ghcr.io/latere-ai
images:
  - name: sandbox-base
    context: base
    platforms: [linux/amd64]
    label: Base
    description: x
  - name: sandbox-base
    context: gui
    platforms: [linux/amd64]
    label: Dup
    description: x
EOF
(cd "$TMP/repo" && ./catalog.sh lint) >/dev/null 2>&1 \
    && fail "lint must reject duplicate names" \
    || pass "lint rejects duplicate names"

fixture <<'EOF'
version: 1
registry: ghcr.io/latere-ai
images:
  - name: sandbox-base
    context: base
    platforms: [linux/amd64]
    label: Base
    description: x
    defaults:
      cpu_milli: 100
      bogus: 1
EOF
(cd "$TMP/repo" && ./catalog.sh lint) >/dev/null 2>&1 \
    && fail "lint must reject unknown defaults keys" \
    || pass "lint rejects unknown defaults keys"

fixture <<'EOF'
version: 1
registry: ghcr.io/latere-ai
images:
  - name: sandbox-base
    context: base
    platforms: [linux/amd64]
    label: Base
    description: x
    packages: usr/share/packages.json
EOF
(cd "$TMP/repo" && ./catalog.sh lint /dev/null) >/dev/null 2>&1 \
    && fail "lint must reject a relative packages path" \
    || pass "lint rejects a relative packages path"
(cd "$TMP/repo" && sed -i.bak 's|packages: usr/|packages: /usr/|' catalog.yaml && ./catalog.sh lint /dev/null) >/dev/null 2>&1 \
    && pass "lint accepts an absolute packages path" \
    || fail "lint must accept an absolute packages path"

# A deny-all .dockerignore with an allow-list drops any COPY source the
# list forgets. The image builds fine locally when the file is present
# and fails only in the pipeline, so lint has to see it.
copy_fixture() {
    fixture <<'EOF'
version: 1
registry: ghcr.io/latere-ai
images:
  - name: sandbox-base
    context: base
    platforms: [linux/amd64]
    label: Base
    description: x
EOF
    printf 'COPY --chmod=0755 boot.sh /usr/local/bin/boot\n' > "$TMP/repo/base/Dockerfile"
    touch "$TMP/repo/base/boot.sh"
}

copy_fixture
printf '*\n!Dockerfile\n' > "$TMP/repo/base/.dockerignore"
(cd "$TMP/repo" && ./catalog.sh lint /dev/null) >/dev/null 2>&1 \
    && fail "lint must reject a COPY source excluded by .dockerignore" \
    || pass "lint rejects a COPY source excluded by .dockerignore"

copy_fixture
printf '*\n!Dockerfile\n!boot.sh\n' > "$TMP/repo/base/.dockerignore"
(cd "$TMP/repo" && ./catalog.sh lint /dev/null) >/dev/null 2>&1 \
    && pass "lint accepts a COPY source the allow-list re-includes" \
    || fail "lint must accept a COPY source the allow-list re-includes"

copy_fixture
rm -f "$TMP/repo/base/boot.sh"
(cd "$TMP/repo" && ./catalog.sh lint /dev/null) >/dev/null 2>&1 \
    && fail "lint must reject a COPY source missing from the context" \
    || pass "lint rejects a COPY source missing from the context"

# Depth 2 (three stages) is supported; the third-level image must land
# in stage 2 and FROM its stage-1 parent.
fixture <<'EOF'
version: 1
registry: ghcr.io/latere-ai
images:
  - name: sandbox-base
    context: base
    platforms: [linux/amd64]
    label: Base
    description: x
  - name: sandbox-harness
    context: harness
    platforms: [linux/amd64]
    from: sandbox-base
    label: Harness
    description: x
  - name: sandbox-gui
    context: gui
    platforms: [linux/amd64]
    from: sandbox-harness
    label: GUI
    description: x
EOF
(cd "$TMP/repo" && ./catalog.sh lint /dev/null) >/dev/null 2>&1 \
    && pass "lint accepts a depth-2 chain (three stages)" \
    || fail "lint must accept depth-2 chains"
m=$(cd "$TMP/repo" && ./catalog.sh matrix --all)
[[ "$(jq -r '.stages[2].image[0].name' <<<"$m")" == "sandbox-gui" && "$(jq -r '.stages[2].image[0].from' <<<"$m")" == "sandbox-harness" ]] \
    && pass "depth-2 image lands in stage 2 with its stage-1 parent" \
    || fail "depth-2 staging wrong: $(jq -c .stages <<<"$m")"

fixture <<'EOF'
version: 1
registry: ghcr.io/latere-ai
images:
  - name: sandbox-base
    context: base
    platforms: [linux/amd64]
    label: Base
    description: x
  - name: sandbox-harness
    context: harness
    platforms: [linux/amd64]
    from: sandbox-base
    label: Harness
    description: x
  - name: sandbox-gui
    context: gui
    platforms: [linux/amd64]
    from: sandbox-harness
    label: GUI
    description: x
  - name: sandbox-extra
    context: extra
    platforms: [linux/amd64]
    from: sandbox-gui
    label: Extra
    description: x
EOF
(cd "$TMP/repo" && ./catalog.sh lint /dev/null) >/dev/null 2>&1 \
    && fail "lint must reject a FROM chain deeper than 3 stages" \
    || pass "lint rejects a FROM chain deeper than 3 stages"

fixture <<'EOF'
version: 1
registry: ghcr.io/latere-ai
images:
  - name: sandbox-base
    context: base
    platforms: [linux/amd64]
    label: Base
    description: x
EOF
mkdir -p "$TMP/repo/.github/workflows"
echo "image: ghcr.io/latere-ai/sandbox-base:latest" > "$TMP/repo/.github/workflows/release.yml"
(cd "$TMP/repo" && ./catalog.sh lint) >/dev/null 2>&1 \
    && fail "grep gate must reject a hardcoded image name in the workflow" \
    || pass "grep gate rejects hardcoded image name in the workflow"
(cd "$TMP/repo" && echo "jobs: {}" > .github/workflows/release.yml && ./catalog.sh lint) >/dev/null 2>&1 \
    && pass "grep gate passes on a catalog-driven workflow" \
    || fail "grep gate false positive"

fixture <<'EOF'
version: 1
registry: ghcr.io/latere-ai
images:
  - name: sandbox-base
    context: base
    platforms: [linux/amd64]
    label: Base
    description: x
EOF
cat > "$TMP/repo/base/Dockerfile" <<'EOF'
FROM ubuntu:24.04
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs
EOF
(cd "$TMP/repo" && ./catalog.sh lint) >/dev/null 2>&1 \
    && fail "lint must reject a Dockerfile that pipes the NodeSource script into bash" \
    || pass "lint rejects a Dockerfile that pipes the NodeSource script into bash"

cat > "$TMP/repo/base/Dockerfile" <<'EOF'
FROM ubuntu:24.04
RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && apt-get install -y nodejs
EOF
(cd "$TMP/repo" && ./catalog.sh lint) >/dev/null 2>&1 \
    && fail "lint must reject a Dockerfile that fetches the NodeSource key at build time" \
    || pass "lint rejects a Dockerfile that fetches the NodeSource key at build time"

: > "$TMP/repo/base/nodesource.gpg.key"
cat > "$TMP/repo/base/Dockerfile" <<'EOF'
FROM ubuntu:24.04
COPY nodesource.gpg.key /tmp/nodesource.gpg.key
RUN gpg --dearmor -o /usr/share/keyrings/nodesource.gpg /tmp/nodesource.gpg.key && \
    echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && apt-get install -y nodejs
EOF
(cd "$TMP/repo" && ./catalog.sh lint) >/dev/null 2>&1 \
    && pass "lint accepts a vendored NodeSource key with a signed apt source" \
    || fail "lint false positive on vendored NodeSource key"

# The vendored key must be the one the base image asserts: a swapped or
# re-fetched key would sail through the grep gates above.
[[ "$(gpg --show-keys --with-colons --with-fingerprint base/nodesource.gpg.key 2>/dev/null \
    | awk -F: '$1 == "fpr" { print $10; exit }')" \
    == "$(grep -oE 'ARG NODE_KEY_FPR=[0-9A-F]+' base/Dockerfile | cut -d= -f2)" ]] \
    && pass "vendored key matches the fingerprint base/Dockerfile asserts" \
    || fail "vendored key does not match NODE_KEY_FPR in base/Dockerfile"

cat > "$TMP/repo/base/Dockerfile" <<'EOF'
FROM ubuntu:24.04
RUN curl -fsSL "https://go.dev/dl/go1.26.4.linux-amd64.tar.gz" | tar -C /usr/local -xzf -
EOF
(cd "$TMP/repo" && ./catalog.sh lint) >/dev/null 2>&1 \
    && fail "lint must reject an unverified Go toolchain download" \
    || pass "lint rejects an unverified Go toolchain download"

cat > "$TMP/repo/base/Dockerfile" <<'EOF'
FROM ubuntu:24.04
ARG GO_SHA256_amd64=deadbeef
RUN curl -fsSL "https://go.dev/dl/go1.26.4.linux-amd64.tar.gz" -o /tmp/go.tar.gz && \
    echo "${GO_SHA256_amd64}  /tmp/go.tar.gz" | sha256sum -c - && \
    tar -C /usr/local -xzf /tmp/go.tar.gz
EOF
(cd "$TMP/repo" && ./catalog.sh lint) >/dev/null 2>&1 \
    && pass "lint accepts a Go download checked with sha256sum" \
    || fail "lint false positive on a checksum-verified Go download"

# Every arch the base image publishes needs a pinned digest, or the build
# falls off the case arm and fails at release time instead of at review.
for arch in $(yq -r '.images[] | select(.context == "base") | .platforms[]' catalog.yaml | cut -d/ -f2); do
    grep -q "ARG GO_SHA256_${arch}=[0-9a-f]\{64\}" base/Dockerfile \
        && pass "base pins a Go checksum for $arch" \
        || fail "base/Dockerfile has no pinned Go checksum for $arch"
done

# --- baseref ---
section "baseref"
# Usage is printed by line range, so a new subcommand silently falls off
# the end of the help unless the range grows with it.
(./catalog.sh 2>&1 >/dev/null || true) | grep -q 'clean' \
    && pass "usage still lists every subcommand" \
    || fail "catalog.sh usage is truncated"

BR="$TMP/baseref"
mkdir -p "$BR"
echo '{"name":"sandbox-base","digest":"sha256:abc123"}' > "$BR/sandbox-base.json"

[[ "$(./catalog.sh baseref sandbox-base "$BR" true)" == "ghcr.io/latere-ai/sandbox-base@sha256:abc123" ]] \
    && pass "resolves the parent to the digest recorded by this run" \
    || fail "baseref did not use the recorded digest: $(./catalog.sh baseref sandbox-base "$BR" true)"

mkdir -p "$TMP/no-digests"
[[ "$(./catalog.sh baseref sandbox-base "$TMP/no-digests" false)" == "ghcr.io/latere-ai/sandbox-base:latest" ]] \
    && pass "falls back to :latest for a non-publishing build" \
    || fail "baseref should fall back to :latest when a digest is not required"

# A publishing run must never quietly rebase onto :latest: that is the
# window where a re-run or a concurrent release rewrites a release image
# onto a different base.
(./catalog.sh baseref sandbox-base "$TMP/no-digests" true) >/dev/null 2>&1 \
    && fail "baseref must fail when a publishing run has no digest for the parent" \
    || pass "baseref fails rather than rebasing a published image onto :latest"

# The release pipeline is the consumer of the two rules above.
rel=.github/workflows/release.yml
[[ -f "$rel" ]] && ! grep -Eq 'BASE_IMAGE=.*:latest' "$rel" \
    && pass "release pipeline does not wire BASE_IMAGE to :latest" \
    || fail "release pipeline still builds dependent images FROM :latest"
[[ -f "$rel" ]] && [[ "$(yq -r '.jobs | keys | .[]' "$rel" | grep -c '^build-stage')" == "3" ]] \
    && pass "release pipeline builds in three FROM-depth stages" \
    || fail "release pipeline must stage builds so a child never races its parent"

# Staging only pays off if the catalog still publishes: an empty stage
# is a skipped job, and a skipped need takes its dependents with it
# unless the dependent runs under always().
[[ -f "$rel" ]] && yq -r '.jobs.publish-catalog.if' "$rel" | grep -q 'always()' \
    && pass "publish-catalog survives an empty build stage" \
    || fail "publish-catalog would be skipped whenever a stage has no images"

# A release reads the package lists the catalog declares and hands them to
# compose; without either, compose fails the release for a declared list.
runs=$(yq -r '.jobs.publish-catalog.steps[].run // ""' "$rel")
grep -q '\./catalog\.sh packages digests packages' <<<"$runs" \
    && grep -q '\./catalog\.sh compose .* digests packages' <<<"$runs" \
    && pass "publish-catalog reads the package lists and composes with them" \
    || fail "publish-catalog does not pass the images' package lists to compose"

# Every stage a release actually runs must record digests, or compose
# has nothing to pin and baseref has nothing to resolve.
for s in 0 1 2; do
    yq -r ".jobs.build-stage$s.steps[].name // \"\"" "$rel" | grep -q '^Upload digest$' \
        && pass "stage $s uploads its digests" \
        || fail "stage $s records no digest for compose and the next stage"
done

# --- summary ---
echo
if [ "$FAILURES" -eq 0 ]; then
    printf "\033[32mAll catalog checks passed.\033[0m\n"
else
    printf "\033[31m%d catalog check(s) failed.\033[0m\n" "$FAILURES"
    exit 1
fi
