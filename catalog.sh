#!/bin/bash
#
# Everything derived from catalog.yaml: linting, the CI change filters
# and build matrices, the published catalog.json, and local builds.
#
# Usage:
#   ./catalog.sh lint [workflow-file]      validate catalog.yaml (+ grep gate)
#   ./catalog.sh filters                   paths-filter YAML for CI
#   ./catalog.sh matrix <changed|--all>    build matrices from a changed set
#                                          (changed = JSON array of image names)
#   ./catalog.sh compose <tag> <commit> <digest-dir> [packages-dir]
#                                          print catalog.json (digest-dir holds
#                                          one {"name","digest"} JSON per image,
#                                          packages-dir one <name>.json package
#                                          list per image that declares one)
#   ./catalog.sh packages <digest-dir> <out-dir>
#                                          read each declared package list from
#                                          the image at the digest digest-dir
#                                          records, into <out-dir>/<name>.json
#   ./catalog.sh baseref <from> <digest-dir> <require>
#                                          BASE_IMAGE for a child build: the
#                                          parent's digest from this run, or
#                                          :latest when <require> is not true
#   ./catalog.sh build [context...]        build images locally (RUNTIME=podman)
#   ./catalog.sh clean                     remove locally built images
#
set -euo pipefail
cd "$(dirname "$0")"

CATALOG=catalog.yaml
RUNTIME="${RUNTIME:-podman}"

command -v yq >/dev/null || { echo "catalog.sh: yq is required (https://github.com/mikefarah/yq)" >&2; exit 1; }
command -v jq >/dev/null || { echo "catalog.sh: jq is required" >&2; exit 1; }

json() { yq -o=json "$CATALOG"; }

# copy_sources prints the build-context paths a Dockerfile COPYs. Flags
# are dropped and `COPY --from=` instructions are skipped: those read
# from an earlier stage or an external image, not from the context.
copy_sources() {
    awk 'toupper($1) == "COPY" {
        from_stage = 0; n = 0; delete a
        for (i = 2; i <= NF; i++) {
            if ($i ~ /^--from=/) { from_stage = 1; continue }
            if ($i ~ /^--/) continue
            a[++n] = $i
        }
        if (from_stage) next
        for (i = 1; i < n; i++) print a[i]
    }' "$1"
}

# context_excludes reports whether a context's .dockerignore keeps `path`
# out of the build context. Patterns are evaluated in file order and the
# last match decides; a leading `!` re-includes. That last-match rule is
# what makes a deny-all-then-allow-list file silently drop a newly added
# script: the file is committed, the COPY is written, and only the image
# build fails.
context_excludes() {
    local ctx="$1" path="$2" excluded=1 line pat
    [[ -f "$ctx/.dockerignore" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n "$line" ]] || continue
        pat="${line#!}"
        # shellcheck disable=SC2053
        if [[ "$path" == $pat ]]; then
            [[ "$line" == '!'* ]] && excluded=1 || excluded=0
        fi
    done < "$ctx/.dockerignore"
    return "$excluded"
}

lint() {
    local workflow="${1:-.github/workflows/release.yml}" errors=0
    err() { echo "lint: $1" >&2; errors=$((errors + 1)); }

    json >/dev/null || { echo "lint: $CATALOG does not parse" >&2; exit 1; }
    [[ "$(json | jq -r '.version')" == "1" ]] || err "version must be 1"
    [[ -n "$(json | jq -r '.registry // ""')" ]] || err "registry is required"

    local names
    names=$(json | jq -r '.images[].name')
    [[ -n "$names" ]] || err "images list is empty"
    [[ "$(sort <<<"$names" | uniq -d)" == "" ]] || err "duplicate image names"
    [[ "$(json | jq -r '.images[].context' | sort | uniq -d)" == "" ]] || err "duplicate contexts"

    local i n ctx from count
    count=$(json | jq '.images | length')
    for ((i = 0; i < count; i++)); do
        n=$(json | jq -r ".images[$i].name // \"\"")
        ctx=$(json | jq -r ".images[$i].context // \"\"")
        from=$(json | jq -r ".images[$i].from // \"\"")
        [[ "$n" =~ ^[a-z0-9][a-z0-9-]*$ ]] || err "images[$i]: bad or missing name '$n'"
        [[ -f "$ctx/Dockerfile" ]] || err "$n: context '$ctx' has no Dockerfile"
        # NodeSource trust gates. Piping their setup script into bash runs
        # unpinned remote content as root; fetching their signing key at
        # build time trusts the same host the key is supposed to verify.
        # Both must stay out of every Dockerfile, not just base's.
        if [[ -f "$ctx/Dockerfile" ]]; then
            if grep -Eq 'nodesource\.com/setup[^[:space:]]*[[:space:]]*\|[[:space:]]*bash' "$ctx/Dockerfile"; then
                err "$n: Dockerfile pipes the NodeSource setup script into bash; use a signed apt source instead"
            fi
            if grep -Eq 'nodesource\.com/gpgkey' "$ctx/Dockerfile"; then
                err "$n: Dockerfile fetches the NodeSource signing key at build time; vendor the key in the context and COPY it"
            fi
            # The Go toolchain compiles binaries for this image and every
            # image FROM it, so its tarball may not be extracted on the
            # strength of HTTPS alone. Pairing the download with a digest
            # check is what the gate looks for.
            if grep -Eq 'go\.dev/dl/' "$ctx/Dockerfile" && ! grep -Eq 'sha256sum[[:space:]]+-c' "$ctx/Dockerfile"; then
                err "$n: Dockerfile downloads the Go toolchain without a sha256sum -c check; pin the per-arch digest"
            fi
        fi
        [[ "$(json | jq ".images[$i].platforms | length")" -gt 0 ]] || err "$n: platforms is required"
        [[ -n "$(json | jq -r ".images[$i].label // \"\"")" ]] || err "$n: label is required"
        [[ -n "$(json | jq -r ".images[$i].description // \"\"")" ]] || err "$n: description is required"
        if [[ -n "$from" ]]; then
            json | jq -e ".images[:$i] | map(.name) | index(\"$from\")" >/dev/null \
                || err "$n: from '$from' must be declared earlier in the list"
        fi
        json | jq -e ".images[$i].defaults // {} | keys - [\"cpu_milli\",\"memory_mb\",\"width\",\"height\"] == []" >/dev/null \
            || err "$n: unknown defaults key"
        # packages is read from the image, where only an absolute path
        # names one file whatever the working directory.
        json | jq -e ".images[$i].packages // \"/\" | type == \"string\" and startswith(\"/\")" >/dev/null \
            || err "$n: packages must be an absolute path in the image"
        # Every file the Dockerfile COPYs must exist in the context and
        # survive its .dockerignore.
        if [[ -f "$ctx/Dockerfile" ]]; then
            local src
            while read -r src; do
                [[ -n "$src" ]] || continue
                if [[ ! -e "$ctx/$src" ]]; then
                    err "$n: COPY source '$src' is missing from context '$ctx'"
                elif context_excludes "$ctx" "$src"; then
                    err "$n: COPY source '$src' is excluded by $ctx/.dockerignore"
                fi
            done < <(copy_sources "$ctx/Dockerfile")
        fi
    done

    # The pipelines build three FROM-depth stages (0, 1, 2); a deeper
    # chain would race its parent inside the last stage job, so adding
    # one must be an explicit pipeline change, not a catalog edit.
    json | jq -e '(reduce .images[] as $i ({};
            . + {($i.name): (if $i.from == null then 0 else ((.[$i.from] // 2) + 1) end)}))
        | to_entries | map(select(.value > 2)) | length == 0' >/dev/null \
        || err "FROM chain deeper than 3 stages (depth > 2); add a build stage to the pipelines first"

    # The workflow must stay fully catalog-driven: no image name may
    # appear in it as a literal.
    if [[ -f "$workflow" ]]; then
        for n in $names; do
            if grep -q "$n" "$workflow"; then
                err "$workflow hardcodes image name '$n'"
            fi
        done
    fi

    [[ "$errors" -eq 0 ]] || exit 1
    echo "lint: ok ($count images)"
}

filters() {
    json | jq -r '.images[] | "\(.name):\n  - \(.context)/**"'
}

# matrix <changed> — <changed> is a JSON array of image names (from
# paths-filter) or --all. Rebuilds propagate along `from` edges; a single
# in-order pass suffices because lint enforces that `from` targets are
# declared earlier. Images build in stages by FROM depth (stage 0 = no
# `from`, stage N = FROM a stage N-1 image); the pipelines wire three
# stage jobs and lint rejects deeper chains. The roots/deps keys are the
# legacy two-stage view (stage 0 / everything deeper) kept for pipelines
# pinned before stages existed.
matrix() {
    local changed="${1:?usage: catalog.sh matrix <changed-json|--all>}"
    if [[ "$changed" == "--all" ]]; then
        changed=$(json | jq -c '[.images[].name]')
    fi
    json | jq -c --argjson c0 "$changed" '
        .registry as $reg
        | (.images | reduce .[] as $i ({};
            . + {($i.name): (if $i.from == null then 0 else (.[$i.from] + 1) end)})) as $depth
        | (.images | reduce .[] as $i ($c0;
            if (index($i.name) == null) and ($i.from != null) and (index($i.from) != null)
            then . + [$i.name] else . end)) as $sel
        | [.images[] | select(.name as $n | $sel | index($n))
            | {name, context, platforms: (.platforms | join(",")), depth: $depth[.name]}
              + (if .from != null then {from} else {} end)] as $imgs
        | ([range(0; 3)] | map(. as $d | [$imgs[] | select(.depth == $d) | del(.depth)])) as $stages
        | {registry: $reg,
           roots: {image: ($stages[0] | map(del(.from)))}, any_root: ($stages[0] | length > 0),
           deps: {image: ($stages[1] + $stages[2])}, any_dep: (($stages[1] + $stages[2]) | length > 0),
           stages: ($stages | map({image: .})),
           any_stage: ($stages | map(length > 0))}'
}

# compose <tag> <commit> <digest-dir> [packages-dir] — join catalog.yaml
# with the digests recorded by the build jobs, and with the package lists
# read from the images (see packages), into the published catalog.json
# contract. An image that declares `packages` must have its list in
# packages-dir, as every image must have a digest: a release that lost one
# fails rather than publish an entry without it.
compose() {
    local tag="${1:?usage: catalog.sh compose <tag> <commit> <digest-dir> [packages-dir]}"
    local commit="${2:?commit required}"
    local dir="${3:?digest dir required}"
    local pdir="${4:-}" digests lists='{}' f
    digests=$(jq -s 'map({(.name): .digest}) | add // {}' "$dir"/*.json 2>/dev/null || echo '{}')
    if [[ -n "$pdir" ]]; then
        for f in "$pdir"/*.json; do
            [[ -e "$f" ]] || continue
            lists=$(jq --arg name "$(basename "$f" .json)" --slurpfile list "$f" \
                '. + {($name): $list[0]}' <<<"$lists")
        done
    fi
    json | jq --arg tag "$tag" --arg commit "$commit" \
              --arg repo "${GITHUB_REPOSITORY:-latere-ai/sandbox-images}" \
              --argjson digests "$digests" --argjson lists "$lists" '
        .registry as $reg
        | {version: 1,
           source: {repo: $repo, commit: $commit, tag: $tag},
           images: [.images[]
             | . as $i
             | ($digests[$i.name] // "") as $d
             | if $d == "" then error("missing digest for \($i.name)") else . end
             | if $i.packages and ($lists[$i.name] == null)
               then error("missing package list for \($i.name)") else . end
             | {name, ref: "\($reg)/\(.name):\($tag)", digest: $d,
                platforms, label, description}
               + (if $i.defaults then {defaults: $i.defaults} else {} end)
               + (if $i.packages then {packages: $lists[$i.name]} else {} end)]}'
}

# packages <digest-dir> <out-dir> — for every image that declares
# `packages`, copy that file out of the image at the digest this run
# recorded, into <out-dir>/<name>.json. The image is created, not run, for
# its first platform, so no emulation is needed for a platform the host
# lacks. The file must be one JSON object of package managers, each mapping
# a package name to its version, or the release fails here.
packages() {
    local dir="${1:?usage: catalog.sh packages <digest-dir> <out-dir>}"
    local out="${2:?out dir required}" reg entry name path platform digest id
    reg=$(json | jq -r '.registry')
    mkdir -p "$out"
    while read -r entry; do
        [[ -n "$entry" ]] || continue
        name=$(jq -r '.name' <<<"$entry")
        path=$(jq -r '.packages' <<<"$entry")
        platform=$(jq -r '.platforms[0]' <<<"$entry")
        digest=$(jq -r '.digest // ""' "$dir/$name.json" 2>/dev/null || echo "")
        if [[ -z "$digest" ]]; then
            echo "packages: no digest recorded for '$name'" >&2
            exit 1
        fi
        id=$($RUNTIME create --platform "$platform" "$reg/$name@$digest")
        if ! $RUNTIME cp "$id:$path" "$out/$name.json"; then
            $RUNTIME rm "$id" >/dev/null || true
            echo "packages: $name has no $path" >&2
            exit 1
        fi
        $RUNTIME rm "$id" >/dev/null
        jq -e 'type == "object" and all(.[]; type == "object" and all(.[]; type == "string"))' \
            "$out/$name.json" >/dev/null 2>&1 \
            || { echo "packages: $name's $path is not a JSON object of package managers to name-version maps" >&2; exit 1; }
        echo "packages: $name: $(jq -r 'to_entries | map("\(.key) \(.value | length)") | join(", ")' "$out/$name.json")"
    done < <(json | jq -c '.images[] | select(.packages != null)')
}

# baseref <from> <digest-dir> <require> — resolve the BASE_IMAGE a child
# build should use. A publishing run must build FROM the exact parent
# image it just pushed, so the parent is addressed by the digest that
# run recorded; :latest is mutable and a re-run, a newer release, or a
# concurrent dispatch can move it between the two jobs, silently rebasing
# a release image onto another base. When <require> is true a missing
# digest is fatal rather than a quiet fall back to :latest, so a dropped
# artifact fails the release instead of mispinning it. Non-publishing
# smoke builds pass require=false and resolve the published :latest.
baseref() {
    local from="${1:?usage: catalog.sh baseref <from> <digest-dir> <require>}"
    local dir="${2:?digest dir required}" require="${3:-false}" reg digest
    reg=$(json | jq -r '.registry')
    digest=$(jq -r '.digest // ""' "$dir/$from.json" 2>/dev/null || echo "")
    if [[ -n "$digest" ]]; then
        echo "$reg/$from@$digest"
    elif [[ "$require" == "true" ]]; then
        echo "baseref: no digest recorded for '$from'; refusing to build a published image FROM :latest" >&2
        exit 1
    else
        echo "$reg/$from:latest"
    fi
}

# build [context...] — local build via $RUNTIME, tagging <name>:latest and
# <registry>/<name>:latest. No args builds everything in catalog order;
# with args, each context's `from` chain builds first.
BUILT=" "
build_one() {
    local ctx="$1" entry name from args=()
    entry=$(json | jq -c ".images[] | select(.context == \"$ctx\")")
    [[ -n "$entry" ]] || { echo "build: unknown context '$ctx'" >&2; exit 1; }
    name=$(jq -r '.name' <<<"$entry")
    [[ "$BUILT" == *" $name "* ]] && return 0
    BUILT+="$name "
    from=$(jq -r '.from // ""' <<<"$entry")
    if [[ -n "$from" ]]; then
        build_one "$(json | jq -r ".images[] | select(.name == \"$from\") | .context")"
        args+=(--build-arg "BASE_IMAGE=$from:latest")
    fi
    local reg
    reg=$(json | jq -r '.registry')
    echo "build: $name ($ctx)"
    $RUNTIME build ${args[@]+"${args[@]}"} -t "$name:latest" -t "$reg/$name:latest" \
        -f "$ctx/Dockerfile" "$ctx/"
}

build() {
    if [[ $# -eq 0 ]]; then
        local ctx
        for ctx in $(json | jq -r '.images[].context'); do build_one "$ctx"; done
    else
        local c
        for c in "$@"; do build_one "$c"; done
    fi
}

clean() {
    local reg n
    reg=$(json | jq -r '.registry')
    for n in $(json | jq -r '.images[].name'); do
        $RUNTIME rmi "$n:latest" "$reg/$n:latest" 2>/dev/null || true
    done
}

cmd="${1:-}"
shift || true
case "$cmd" in
    lint)    lint "$@" ;;
    filters) filters ;;
    matrix)  matrix "$@" ;;
    compose) compose "$@" ;;
    packages) packages "$@" ;;
    baseref) baseref "$@" ;;
    build)   build "$@" ;;
    clean)   clean ;;
    *)       grep '^#' "$0" | sed -n '2,25p' >&2; exit 1 ;;
esac
