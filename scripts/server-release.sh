#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$HERE")"
LINUX_DIR="$APP_DIR/linux"
SERVER_DIR="$LINUX_DIR/server"
PACKAGING_DIR="$SERVER_DIR/packaging"
DOCKERFILE="$PACKAGING_DIR/docker/Dockerfile"
IMAGE="ghcr.io/guitaripod/flaccy-server"
ARCHES=(x86_64 aarch64)
MAC_HOST="${FLACCY_SERVER_MAC_HOST:-macbook}"
readonly MAC_BUILD_DIR="Dev/builds/flaccy-server-release"
MAC_TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
MIRROR_REPO="guitaripod/flaccy"
MIRROR_URL="git@github.com:$MIRROR_REPO.git"
TAP_REPO="guitaripod/homebrew-tap"
TAP_URL="git@github.com:$TAP_REPO.git"
AUR_URL="ssh://aur@aur.archlinux.org/flaccy-server-bin.git"
STEPS=(verify-tree verify-artifacts release-notes push-monorepo push-subtree github-release homebrew-tap aur docker verify-release)
CHECK_STEPS=(verify-tree verify-artifacts release-notes verify-release)
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=20"
TOOLCHAIN="${FLACCY_SERVER_TOOLCHAIN:-stable}"
RELEASE_ROOT="${FLACCY_SERVER_RELEASE_DIR:-$HOME/.cache/flaccy-server-release}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$RELEASE_ROOT/target}"

ALLOW_DIRTY=0
PUBLISH=0
PUSH=0
DRY_RUN=0
DOCKER_FALLBACK=0
ONLY=""
VERSION=""
OUT_DIR=""
SUBCOMMAND=""
WORK_DIR=""
MAC_STAGED=0
SPLIT_SHA=""
PROBLEMS=()

usage() {
    cat <<'EOF'
Usage: scripts/server-release.sh <command> [options]

Commands:
  build      Static musl tarballs for x86_64 and aarch64, each with a .sha256 file
  macos      Runs the Rust tests on the Mac, then release binaries for aarch64 and x86_64 macOS, built over ssh,
             ad-hoc signed, packed as flaccy-server-<version>-macos-{arm64,x86_64}.tar.gz
  docker     Build ghcr.io/guitaripod/flaccy-server:<version> and :latest
  deb        .deb packages for x86_64 and aarch64
  rpm        .rpm packages for x86_64 and aarch64
  checksums  SHA256SUMS, plus the PKGBUILD and Homebrew formula filled in with the release
  all        build, deb, rpm, docker, checksums (run macos first when the formula is needed)
  publish    The whole release: --version X.Y.Z [--publish | --dry-run] [--only STEP]
             [--docker-fallback]. Dry-run is the default and changes nothing anywhere.
             Steps: verify-tree verify-artifacts release-notes push-monorepo push-subtree
             github-release homebrew-tap aur docker verify-release (and docker-tarball
             for --only). Progress is kept in <release dir>/publish.state.

Options:
  --allow-dirty      Build although the working tree has uncommitted changes
  --push             With docker: push both tags (also needs --publish)
  --publish          Allow pushing and publishing. Nothing is ever pushed without it
  --dry-run          With publish: print what each step would do (the default)
  --version V        With publish: the release to publish
  --only STEP        With publish: run one step again, ignoring publish.state
  --docker-fallback  With publish: when the token cannot push to ghcr.io, attach the
                     image to the GitHub release as a tarball instead of failing

Output goes to ~/.cache/flaccy-server-release/<version>/ (FLACCY_SERVER_RELEASE_DIR
moves the root). The version comes from linux/server/Cargo.toml. FLACCY_SERVER_MAC_HOST
names the Mac (default macbook).
EOF
}

die() {
    echo "error: $1" >&2
    exit 1
}

say() {
    echo "==> $1"
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is not installed. $2"
}

manifest_version() {
    local version
    version="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$SERVER_DIR/Cargo.toml" | head -n 1)"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || die "could not read a version from $SERVER_DIR/Cargo.toml"
    echo "$version"
}

require_clean_tree() {
    [[ "$ALLOW_DIRTY" == 1 ]] && return
    local changes
    changes="$(git -C "$APP_DIR" status --porcelain -- .)"
    [[ -z "$changes" ]] || die "the working tree has uncommitted changes; commit them or pass --allow-dirty:
$changes"
}

triple_for() {
    echo "$1-unknown-linux-musl"
}

deb_arch_for() {
    case "$1" in
        x86_64) echo amd64 ;;
        aarch64) echo arm64 ;;
        *) die "no Debian architecture for $1" ;;
    esac
}

binary_path() {
    echo "$CARGO_TARGET_DIR/$(triple_for "$1")/release/flaccy-server"
}

tarball_name() {
    echo "flaccy-server-$VERSION-linux-$1"
}

require_cargo_subcommand() {
    cargo "$1" --help >/dev/null 2>&1 || die "cargo $1 is not installed. Run: cargo install cargo-$1 --locked"
}

prepare_toolchain() {
    require_tool cargo "Install Rust from https://rustup.rs."
    require_tool zig "Install it with your package manager (pacman -S zig)."
    require_cargo_subcommand zigbuild
    if command -v rustup >/dev/null 2>&1; then
        export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-$TOOLCHAIN}"
        local arch
        for arch in "${ARCHES[@]}"; do
            rustup -q target add --toolchain "$RUSTUP_TOOLCHAIN" "$(triple_for "$arch")"
        done
    fi
}

check_glibc_floor() {
    "$LINUX_DIR/check-glibc-floor.sh" "$1"
}

verify_binary() {
    local binary="$1" arch="$2" described
    described="$(file -b "$binary")"
    if [[ "$described" == *"statically linked"* || "$described" == *"static-pie linked"* ]]; then
        say "$arch binary is static, so it has no glibc floor"
    else
        check_glibc_floor "$binary"
    fi
    run_version_check "$binary" "$arch"
}

run_version_check() {
    local binary="$1" arch="$2"
    if [[ "$arch" == "$(uname -m)" ]]; then
        "$binary" --version
    elif command -v "qemu-$arch" >/dev/null 2>&1; then
        "qemu-$arch" "$binary" --version
    else
        say "cannot run the $arch binary on this machine; checked with file only"
    fi
}

build_binary() {
    local arch="$1"
    say "building the static $arch binary"
    (cd "$LINUX_DIR" && cargo zigbuild --release --locked -p flaccy-server --target "$(triple_for "$arch")")
    verify_binary "$(binary_path "$arch")" "$arch"
}

write_tarball() {
    local name="$1" binary="$2" stage
    shift 2
    stage="$(mktemp -d)"
    mkdir "$stage/$name"
    cp "$binary" "$stage/$name/flaccy-server"
    cp "$@" "$stage/$name/"
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$(git -C "$APP_DIR" log -1 --format=%ct)" \
        -C "$stage" -cf - "$name" | gzip -n -9 > "$OUT_DIR/$name.tar.gz"
    rm -rf "$stage"
    (cd "$OUT_DIR" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
}

stage_tarball() {
    local arch="$1"
    write_tarball "$(tarball_name "$arch")" "$(binary_path "$arch")" \
        "$SERVER_DIR/flaccy-server.service" "$SERVER_DIR/README.md" "$LINUX_DIR/LICENSE"
}

app_prefix() {
    local prefix
    prefix="$(git -C "$APP_DIR" rev-parse --show-prefix)"
    echo "${prefix%/}"
}

source_tree() {
    git -C "$APP_DIR" rev-parse "HEAD:$(app_prefix)/linux" 2>/dev/null || git -C "$APP_DIR" rev-parse "HEAD:linux"
}

recorded_source_tree() {
    awk -v kind="$1" '$1 == kind { tree = $2 } END { print tree }' "$OUT_DIR/built-from" 2>/dev/null || true
}

record_built_from() {
    local kind="$1" tree remaining="$OUT_DIR/built-from.new"
    tree="$(source_tree)"
    [[ -z "$(git -C "$APP_DIR" status --porcelain -- "$LINUX_DIR")" ]] || tree="dirty"
    touch "$OUT_DIR/built-from"
    grep -v "^$kind " "$OUT_DIR/built-from" > "$remaining" || true
    echo "$kind $tree" >> "$remaining"
    mv "$remaining" "$OUT_DIR/built-from"
}

mac_ssh() {
    ssh -o BatchMode=yes -o ConnectTimeout=15 "$MAC_HOST" "$@"
}

mac_arch_name() {
    case "$1" in
        aarch64-apple-darwin) echo arm64 ;;
        x86_64-apple-darwin) echo x86_64 ;;
        *) die "no macOS archive name for $1" ;;
    esac
}

macos_archive_name() {
    echo "flaccy-server-$VERSION-macos-$(mac_arch_name "$1")"
}

mac_build_script() {
    cat <<'EOF'
set -euo pipefail
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
dir="$HOME/$1"
version="$2"
shift 2
export CARGO_TARGET_DIR="$dir/target"
export MACOSX_DEPLOYMENT_TARGET=11.0
cd "$dir/linux"
cargo test --locked -p flaccy-server -p flaccy-server-core -p flaccy-library -p flaccy-soak
for target in "$@"; do
    rustup target list --installed | grep -qx "$target" || rustup target add "$target"
    cargo build --release --locked -p flaccy-server --target "$target"
    binary="$CARGO_TARGET_DIR/$target/release/flaccy-server"
    strip "$binary"
    codesign -s - --force "$binary"
    echo "$target: $(lipo -info "$binary")"
    echo "$target: $(codesign -dv "$binary" 2>&1 | grep -E 'Signature|Identifier' | tr '\n' ' ')"
done
native="$CARGO_TARGET_DIR/aarch64-apple-darwin/release/flaccy-server"
reported="$("$native" --version)"
echo "arm64 on the Mac: $reported"
[[ "$reported" == *"$version"* ]] || { echo "the arm64 binary reports '$reported', not $version" >&2; exit 1; }
intel="$CARGO_TARGET_DIR/x86_64-apple-darwin/release/flaccy-server"
if arch -x86_64 /usr/bin/true 2>/dev/null; then
    echo "x86_64 under Rosetta: $(arch -x86_64 "$intel" --version)"
else
    echo "x86_64 not run: Rosetta is not installed on this Mac"
fi
EOF
}

sync_tree_to_mac() {
    say "copying linux/ to $MAC_HOST:~/$MAC_BUILD_DIR"
    mac_ssh "mkdir -p \"\$HOME/$MAC_BUILD_DIR/linux\""
    MAC_STAGED=1
    rsync -a --delete -e "ssh -o BatchMode=yes -o ConnectTimeout=15" \
        --exclude target --exclude build --exclude .build --exclude DerivedData --exclude .git \
        "$LINUX_DIR/" "$MAC_HOST:$MAC_BUILD_DIR/linux/"
}

build_on_mac() {
    say "building ${MAC_TARGETS[*]} on $MAC_HOST"
    mac_build_script | mac_ssh bash -s -- "$MAC_BUILD_DIR" "$VERSION" "${MAC_TARGETS[@]}"
}

pull_mac_binary() {
    local target="$1" destination="$2" described
    mkdir -p "$(dirname "$destination")"
    rsync -a -e "ssh -o BatchMode=yes -o ConnectTimeout=15" \
        "$MAC_HOST:$MAC_BUILD_DIR/target/$target/release/flaccy-server" "$destination"
    described="$(file -b "$destination")"
    [[ "$described" == *Mach-O* ]] || die "$target binary is not a Mach-O file: $described"
    say "$target: $described"
}

clean_mac_build_dir() {
    [[ "$MAC_STAGED" == 1 ]] || return 0
    say "removing ~/$MAC_BUILD_DIR on $MAC_HOST"
    mac_ssh "rm -rf \"\$HOME/$MAC_BUILD_DIR\"" || echo "warning: could not remove ~/$MAC_BUILD_DIR on $MAC_HOST" >&2
    MAC_STAGED=0
}

cmd_macos() {
    require_tool rsync "Install rsync."
    require_tool ssh "Install OpenSSH."
    local stage target
    stage="$(work_dir)/macos"
    sync_tree_to_mac
    build_on_mac
    for target in "${MAC_TARGETS[@]}"; do
        pull_mac_binary "$target" "$stage/$target/flaccy-server"
    done
    clean_mac_build_dir
    for target in "${MAC_TARGETS[@]}"; do
        write_tarball "$(macos_archive_name "$target")" "$stage/$target/flaccy-server" "$SERVER_DIR/README.md" "$LINUX_DIR/LICENSE"
        cat "$OUT_DIR/$(macos_archive_name "$target").tar.gz.sha256"
    done
    record_built_from macos
}

cmd_build() {
    prepare_toolchain
    local arch
    for arch in "${ARCHES[@]}"; do
        build_binary "$arch"
        stage_tarball "$arch"
    done
    record_built_from build
}

cmd_deb() {
    require_cargo_subcommand deb
    prepare_toolchain
    local arch
    for arch in "${ARCHES[@]}"; do
        build_binary "$arch"
        say "packaging the $arch .deb"
        (cd "$LINUX_DIR" && cargo deb -p flaccy-server --no-build --no-strip --target "$(triple_for "$arch")" -o "$OUT_DIR/")
    done
    record_built_from deb
}

cmd_rpm() {
    require_cargo_subcommand generate-rpm
    prepare_toolchain
    local arch
    for arch in "${ARCHES[@]}"; do
        build_binary "$arch"
        say "packaging the $arch .rpm"
        (cd "$LINUX_DIR" && cargo generate-rpm -p server --target "$(triple_for "$arch")" -a "$arch" -o "$OUT_DIR/")
    done
    record_built_from rpm
}

cmd_docker() {
    require_tool docker "Install Docker."
    say "building $IMAGE:$VERSION"
    docker build -f "$DOCKERFILE" -t "$IMAGE:$VERSION" -t "$IMAGE:latest" "$LINUX_DIR"
    [[ "$PUSH" == 1 ]] || return 0
    docker push "$IMAGE:$VERSION"
    docker push "$IMAGE:latest"
}

sha_of() {
    local file="$OUT_DIR/$1"
    [[ -f "$file" ]] || return 1
    sha256sum "$file" | cut -d ' ' -f 1
}

fill_placeholder() {
    local file="$1" token="$2" archive="$3" sha
    if sha="$(sha_of "$archive")"; then
        sed -i "s|@$token@|$sha|" "$file"
    else
        say "no $archive in $OUT_DIR; @$token@ stays a placeholder in $(basename "$file")"
    fi
}

render_template() {
    local template="$1" rendered="$OUT_DIR/packaging/$(basename "$1")"
    mkdir -p "$OUT_DIR/packaging"
    sed "s|@VERSION@|$VERSION|g" "$template" > "$rendered"
    fill_placeholder "$rendered" SHA256_LINUX_X86_64 "$(tarball_name x86_64).tar.gz"
    fill_placeholder "$rendered" SHA256_LINUX_AARCH64 "$(tarball_name aarch64).tar.gz"
    fill_placeholder "$rendered" SHA256_MACOS_ARM64 "flaccy-server-$VERSION-macos-arm64.tar.gz"
    fill_placeholder "$rendered" SHA256_MACOS_X86_64 "flaccy-server-$VERSION-macos-x86_64.tar.gz"
}

cmd_checksums() {
    (cd "$OUT_DIR" && sha256sum -- *.tar.gz *.deb *.rpm 2>/dev/null > SHA256SUMS) || true
    [[ -s "$OUT_DIR/SHA256SUMS" ]] || die "no artifacts in $OUT_DIR to checksum; run build first"
    render_template "$PACKAGING_DIR/PKGBUILD"
    render_template "$PACKAGING_DIR/homebrew/flaccy-server.rb"
    cat "$OUT_DIR/SHA256SUMS"
}

cmd_all() {
    cmd_build
    cmd_deb
    cmd_rpm
    cmd_docker
    cmd_checksums
}

prepare_work_dir() {
    mkdir -p "$RELEASE_ROOT"
    WORK_DIR="$(mktemp -d "$RELEASE_ROOT/work.XXXXXX")"
}

work_dir() {
    echo "$WORK_DIR"
}

cleanup_on_exit() {
    clean_mac_build_dir
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}

is_dry_run() {
    [[ "$PUBLISH" == 0 ]]
}

act() {
    if is_dry_run; then
        echo "    would run: $*"
        return 0
    fi
    "$@"
}

detail() {
    echo "    $1"
}

problem() {
    if is_dry_run; then
        PROBLEMS+=("$1")
        echo "    BLOCKS PUBLISH: $1"
        return 0
    fi
    die "$1"
}

state_file() {
    echo "$OUT_DIR/publish.state"
}

step_recorded() {
    grep -qx "step $1" "$(state_file)" 2>/dev/null
}

record_step() {
    mkdir -p "$OUT_DIR"
    echo "step $1" >> "$(state_file)"
}

record_value() {
    is_dry_run && return 0
    mkdir -p "$OUT_DIR"
    echo "value $1 $2" >> "$(state_file)"
}

recorded_value() {
    awk -v key="$1" '$1 == "value" && $2 == key { found = $3 } END { print found }' "$(state_file)" 2>/dev/null || true
}

is_check_step() {
    [[ " ${CHECK_STEPS[*]} " == *" $1 "* ]]
}

release_tag() {
    echo "server-v$VERSION"
}

release_notes_path() {
    echo "$APP_DIR/docs/server/RELEASE-NOTES-$VERSION.md"
}

release_asset_names() {
    local arch
    for arch in "${ARCHES[@]}"; do
        echo "$(tarball_name "$arch").tar.gz"
    done
    for arch in arm64 x86_64; do
        echo "flaccy-server-$VERSION-macos-$arch.tar.gz"
    done
    for arch in amd64 arm64; do
        echo "flaccy-server_${VERSION}-1_$arch.deb"
    done
    for arch in "${ARCHES[@]}"; do
        echo "flaccy-server-$VERSION-1.$arch.rpm"
    done
    echo SHA256SUMS
}

docker_tarball_path() {
    echo "$OUT_DIR/docker/flaccy-server-$VERSION-docker-amd64.tar.gz"
}

remote_head_of() {
    git ls-remote "$1" "$2" | cut -f 1
}

release_exists() {
    gh release view "$(release_tag)" -R "$MIRROR_REPO" >/dev/null 2>&1
}

release_asset_list() {
    gh release view "$(release_tag)" -R "$MIRROR_REPO" --json assets --jq '.assets[].name'
}

has_release_asset() {
    release_exists && release_asset_list | grep -qx "$1"
}

check_publish_tools() {
    local tool
    for tool in git gh curl sha256sum ruby makepkg git-lfs; do
        command -v "$tool" >/dev/null 2>&1 || problem "$tool is not installed"
    done
    [[ -x "$(git --exec-path)/git-subtree" ]] || problem "git subtree is not installed"
    local login
    if login="$(gh api user --jq .login 2>/dev/null)"; then
        detail "gh is signed in as $login"
    else
        problem "gh cannot reach GitHub; run: gh auth login"
    fi
}

step_verify_tree() {
    local branch changes remote_head head ahead
    branch="$(git -C "$APP_DIR" rev-parse --abbrev-ref HEAD)"
    [[ "$branch" == master ]] || problem "release from master; this checkout is on $branch"
    changes="$(git -C "$APP_DIR" status --porcelain -- .)"
    [[ -z "$changes" ]] || problem "$(wc -l <<< "$changes") uncommitted changes under $APP_DIR; commit them first"
    [[ "$(manifest_version)" == "$VERSION" ]] \
        || problem "linux/server/Cargo.toml says $(manifest_version), not $VERSION; bump it in a commit"
    head="$(git -C "$APP_DIR" rev-parse HEAD)"
    remote_head="$(remote_head_of origin refs/heads/master)" || { problem "cannot read origin"; return 0; }
    if [[ "$remote_head" == "$head" ]]; then
        detail "HEAD ${head:0:12} is on origin/master"
    elif git -C "$APP_DIR" cat-file -e "$remote_head^{commit}" 2>/dev/null; then
        ahead="$(git -C "$APP_DIR" rev-list --count "$remote_head..HEAD")"
        detail "HEAD is $ahead commit(s) ahead of origin/master; push-monorepo pushes them"
    else
        problem "origin/master (${remote_head:0:12}) has commits this checkout lacks; pull first"
    fi
}

check_built_from() {
    local tree kind recorded
    tree="$(source_tree)"
    for kind in build deb rpm macos; do
        recorded="$(recorded_source_tree "$kind")"
        [[ "$recorded" == "$tree" ]] || problem "$kind artifacts were built from ${recorded:-an unknown tree}, linux/ at HEAD is ${tree:0:12}; rebuild from the release commit"
    done
}

check_rendered_templates() {
    local rendered archive template_sha
    for rendered in PKGBUILD flaccy-server.rb; do
        [[ -f "$OUT_DIR/packaging/$rendered" ]] || { problem "$OUT_DIR/packaging/$rendered is missing; run: scripts/server-release.sh checksums"; continue; }
        if grep -Eq '@[A-Z0-9_]+@' "$OUT_DIR/packaging/$rendered"; then
            problem "packaging/$rendered still has @PLACEHOLDER@ values; run: scripts/server-release.sh checksums"
        fi
    done
    for archive in "$(tarball_name x86_64)" "$(tarball_name aarch64)"; do
        template_sha="$(sha_of "$archive.tar.gz" 2>/dev/null || true)"
        [[ -n "$template_sha" ]] && grep -q "$template_sha" "$OUT_DIR/packaging/PKGBUILD" 2>/dev/null \
            || problem "packaging/PKGBUILD does not carry the sha256 of $archive.tar.gz"
    done
    for archive in flaccy-server-$VERSION-macos-arm64 flaccy-server-$VERSION-macos-x86_64; do
        template_sha="$(sha_of "$archive.tar.gz" 2>/dev/null || true)"
        [[ -n "$template_sha" ]] && grep -q "$template_sha" "$OUT_DIR/packaging/flaccy-server.rb" 2>/dev/null \
            || problem "packaging/flaccy-server.rb does not carry the sha256 of $archive.tar.gz"
    done
}

step_verify_artifacts() {
    local name missing=0
    while read -r name; do
        if [[ -f "$OUT_DIR/$name" ]]; then
            detail "found $name"
        else
            problem "missing $OUT_DIR/$name"
            missing=1
        fi
    done < <(release_asset_names)
    [[ "$missing" == 0 ]] || return 0
    (cd "$OUT_DIR" && sha256sum --check --quiet SHA256SUMS) || problem "SHA256SUMS does not match the files in $OUT_DIR"
    check_built_from
    check_rendered_templates
}

step_release_notes() {
    local notes
    notes="$(release_notes_path)"
    if [[ ! -s "$notes" ]]; then
        problem "write $notes (docs/server/RELEASE-NOTES-1.0.0.md is the template)"
    elif grep -q 'DRAFT:' "$notes"; then
        problem "$notes still has its DRAFT marker; edit the notes and delete that line"
    else
        detail "release notes: $notes ($(wc -l < "$notes") lines)"
    fi
}

ensure_split_sha() {
    [[ -n "$SPLIT_SHA" ]] && return 0
    detail "splitting $(app_prefix) out of the monorepo history"
    SPLIT_SHA="$(git -C "$(git -C "$APP_DIR" rev-parse --show-toplevel)" subtree split -q --prefix="$(app_prefix)" HEAD)" \
        || { problem "git subtree split failed"; return 1; }
}

step_push_monorepo() {
    local head remote_head
    head="$(git -C "$APP_DIR" rev-parse HEAD)"
    remote_head="$(remote_head_of origin refs/heads/master)" || { problem "cannot read origin"; return 0; }
    if [[ "$remote_head" == "$head" ]]; then
        detail "origin/master already is ${head:0:12}"
        return 0
    fi
    git -C "$APP_DIR" merge-base --is-ancestor "$remote_head" "$head" 2>/dev/null \
        || { problem "origin/master (${remote_head:0:12}) is not an ancestor of HEAD; pull first"; return 0; }
    act git -C "$APP_DIR" push origin master
}

step_push_subtree() {
    local mirror_head
    ensure_split_sha || return 0
    detail "split commit ${SPLIT_SHA:0:12}"
    mirror_head="$(remote_head_of "$MIRROR_URL" refs/heads/master)" || { problem "cannot read $MIRROR_URL"; return 0; }
    if [[ "$mirror_head" == "$SPLIT_SHA" ]]; then
        detail "$MIRROR_REPO master already is ${SPLIT_SHA:0:12}"
        return 0
    fi
    git -C "$APP_DIR" fetch --quiet --no-tags "$MIRROR_URL" master || { problem "cannot fetch $MIRROR_REPO master"; return 0; }
    git -C "$APP_DIR" merge-base --is-ancestor "$mirror_head" "$SPLIT_SHA" \
        || { problem "$MIRROR_REPO master (${mirror_head:0:12}) is not an ancestor of the split; the mirror has diverged"; return 0; }
    act git -C "$APP_DIR" push "$MIRROR_URL" "$SPLIT_SHA:refs/heads/master"
}

step_github_release() {
    local tag name existing flags=() paths=()
    tag="$(release_tag)"
    ensure_split_sha || return 0
    if release_exists; then
        existing="$(release_asset_list)"
        if [[ -n "$existing" ]] && ! release_asset_names | grep -qxF -f <(echo "$existing"); then
            problem "$tag already exists with unrelated assets (${existing//$'\n'/, }); publish a new version instead of adding to it"
            return 0
        fi
        while read -r name; do
            if grep -qx "$name" <<< "$existing"; then
                detail "release already has $name"
            else
                act gh release upload "$tag" "$OUT_DIR/$name" -R "$MIRROR_REPO"
            fi
        done < <(release_asset_names)
        return 0
    fi
    while read -r name; do
        paths+=("$OUT_DIR/$name")
    done < <(release_asset_names)
    flags=(--target "$SPLIT_SHA" --title "Flaccy Server $VERSION" --notes-file "$(release_notes_path)" --latest=false)
    [[ "$VERSION" != *-* ]] || flags+=(--prerelease)
    detail "creating $tag on $MIRROR_REPO at ${SPLIT_SHA:0:12}, not marked latest (get-flaccy.sh reads releases/latest), with ${#paths[@]} assets:"
    if is_dry_run; then
        printf '      %s\n' "${paths[@]##*/}"
        detail "would run: gh release create $tag <${#paths[@]} assets> -R $MIRROR_REPO ${flags[*]}"
        return 0
    fi
    gh release create "$tag" "${paths[@]}" -R "$MIRROR_REPO" "${flags[@]}"
}

step_homebrew_tap() {
    local formula="$OUT_DIR/packaging/flaccy-server.rb" tap message
    [[ -f "$formula" ]] || { problem "$formula is missing; run: scripts/server-release.sh checksums"; return 0; }
    ruby -c "$formula" >/dev/null || { problem "$formula has a Ruby syntax error"; return 0; }
    tap="$(work_dir)/tap"
    git clone --quiet --depth 1 "$TAP_URL" "$tap" || { problem "cannot clone $TAP_URL"; return 0; }
    message="Update flaccy-server to $VERSION"
    [[ -f "$tap/Formula/flaccy-server.rb" ]] || message="Add flaccy-server $VERSION"
    if cmp -s "$formula" "$tap/Formula/flaccy-server.rb"; then
        detail "$TAP_REPO already has this formula"
        return 0
    fi
    mkdir -p "$tap/Formula"
    cp "$formula" "$tap/Formula/flaccy-server.rb"
    git -C "$tap" add Formula/flaccy-server.rb
    git -C "$tap" diff --cached --stat | sed 's/^/    /'
    act git -C "$tap" commit --quiet -m "$message"
    act git -C "$tap" push --quiet origin HEAD
}

verify_aur_source() {
    local aur="$1"
    if ! release_exists; then
        is_dry_run && { detail "would run makepkg --verifysource against the live assets once $(release_tag) exists"; return 0; }
        die "$(release_tag) does not exist on $MIRROR_REPO; run the github-release step first"
    fi
    if ! (cd "$aur" && SRCDEST="$aur/.sources" makepkg --verifysource --nocolor 2>&1 | grep -v -E '^ +(%|Dload|[0-9]+ +[0-9]+)' | sed 's/^/    /'); then
        problem "makepkg --verifysource failed against the live release assets of $(release_tag)"
    fi
}

step_aur() {
    local pkgbuild="$OUT_DIR/packaging/PKGBUILD" aur message
    [[ -f "$pkgbuild" ]] || { problem "$pkgbuild is missing; run: scripts/server-release.sh checksums"; return 0; }
    aur="$(work_dir)/aur"
    git clone --quiet "$AUR_URL" "$aur" 2>/dev/null || { problem "cannot clone $AUR_URL; check the AUR ssh key"; return 0; }
    message="Update to $VERSION"
    git -C "$aur" rev-parse --verify --quiet HEAD >/dev/null || message="Add flaccy-server-bin $VERSION"
    cp "$pkgbuild" "$aur/PKGBUILD"
    (cd "$aur" && makepkg --printsrcinfo > .SRCINFO) || { problem "makepkg cannot read the PKGBUILD"; return 0; }
    git -C "$aur" add PKGBUILD .SRCINFO
    if git -C "$aur" diff --cached --quiet; then
        detail "the AUR repo already has this PKGBUILD"
        return 0
    fi
    git -C "$aur" diff --cached --stat | sed 's/^/    /'
    verify_aur_source "$aur"
    act git -C "$aur" commit --quiet -m "$message"
    act git -C "$aur" push --quiet origin HEAD:refs/heads/master
    is_dry_run || record_value aur_commit "$(git -C "$aur" rev-parse HEAD)"
}

granted_token_scopes() {
    gh api -i /user 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1) == "x-oauth-scopes" { gsub(/ /, "", $2); print $2 }'
}

can_push_to_ghcr() {
    [[ ",$(granted_token_scopes)," == *,write:packages,* ]]
}

ensure_image() {
    docker image inspect "$IMAGE:$VERSION" >/dev/null 2>&1 && return 0
    say "$IMAGE:$VERSION is not built yet; building it"
    cmd_docker
}

image_architecture() {
    docker image inspect --format '{{.Architecture}}' "$IMAGE:$VERSION"
}

push_image_to_ghcr() {
    local login config
    if is_dry_run; then
        detail "would log in to ghcr.io with the gh token (a throwaway docker config), then push $IMAGE:$VERSION and $IMAGE:latest"
        return 0
    fi
    ensure_image
    config="$(work_dir)/docker-config"
    mkdir -p "$config"
    login="$(gh api user --jq .login)"
    gh auth token | DOCKER_CONFIG="$config" docker login ghcr.io -u "$login" --password-stdin >/dev/null
    DOCKER_CONFIG="$config" docker push "$IMAGE:$VERSION"
    DOCKER_CONFIG="$config" docker push "$IMAGE:latest"
    record_value docker ghcr
}

step_docker() {
    if can_push_to_ghcr; then
        detail "the token has write:packages"
        push_image_to_ghcr
    elif [[ "$DOCKER_FALLBACK" == 1 ]]; then
        detail "the token lacks write:packages; attaching the image to the release instead (later, to use ghcr.io: gh auth refresh -s write:packages)"
        step_docker_tarball
    else
        problem "the GitHub token cannot push to ghcr.io (no write:packages scope). Run:
gh auth refresh -s write:packages
then rerun with --only docker, or pass --docker-fallback to attach the image to the release as a tarball"
    fi
}

step_docker_tarball() {
    local tarball name
    tarball="$(docker_tarball_path)"
    name="$(basename "$tarball")"
    if has_release_asset "$name"; then
        detail "release already has $name"
        return 0
    fi
    if is_dry_run; then
        detail "would run: docker save $IMAGE:$VERSION | gzip -n -9 > $tarball (amd64 only), then gh release upload $(release_tag) $name"
        return 0
    fi
    release_exists || die "$(release_tag) does not exist on $MIRROR_REPO; run the github-release step first"
    ensure_image
    [[ "$(image_architecture)" == amd64 ]] || die "$IMAGE:$VERSION is $(image_architecture), not amd64"
    mkdir -p "$(dirname "$tarball")"
    [[ -f "$tarball" ]] || docker save "$IMAGE:$VERSION" | gzip -n -9 > "$tarball"
    (cd "$(dirname "$tarball")" && sha256sum "$name" > "$name.sha256")
    gh release upload "$(release_tag)" "$tarball" -R "$MIRROR_REPO"
    record_value docker tarball
}

latest_release_tag() {
    gh api "repos/$MIRROR_REPO/releases/latest" --jq .tag_name 2>/dev/null || true
}

verify_asset_download() {
    local name="$1" expected="$2" file actual
    file="$(work_dir)/verify/$name"
    mkdir -p "$(dirname "$file")"
    curl -fsSL --retry 3 -o "$file" "https://github.com/$MIRROR_REPO/releases/download/$(release_tag)/$name" 2>/dev/null \
        || { problem "cannot download $name from the release"; return 0; }
    actual="$(sha256sum "$file" | cut -d ' ' -f 1)"
    if [[ "$actual" == "$expected" ]]; then
        detail "ok $name"
    else
        problem "$name on the release has sha256 ${actual:0:12}..., expected ${expected:0:12}..."
    fi
    rm -f "$file"
}

verify_published_assets() {
    local expected name docker_sum
    while read -r expected name; do
        verify_asset_download "$name" "$expected"
    done < "$OUT_DIR/SHA256SUMS"
    verify_asset_download SHA256SUMS "$(sha_of SHA256SUMS)"
    if has_release_asset "$(basename "$(docker_tarball_path)")" && [[ -f "$(docker_tarball_path).sha256" ]]; then
        docker_sum="$(cut -d ' ' -f 1 "$(docker_tarball_path).sha256")"
        verify_asset_download "$(basename "$(docker_tarball_path)")" "$docker_sum"
    fi
}

verify_tap_formula() {
    local content formula sha
    content="$(gh api "repos/$TAP_REPO/contents/Formula/flaccy-server.rb" --jq .content 2>/dev/null)" \
        || { problem "$TAP_REPO has no Formula/flaccy-server.rb"; return 0; }
    formula="$(base64 -d <<< "$content")"
    grep -q "server-v$VERSION/" <<< "$formula" || problem "the tap formula does not point at $(release_tag)"
    for sha in "$(sha_of "flaccy-server-$VERSION-macos-arm64.tar.gz")" "$(sha_of "flaccy-server-$VERSION-macos-x86_64.tar.gz")"; do
        grep -q "$sha" <<< "$formula" || problem "the tap formula lacks sha256 ${sha:0:12}..."
    done
    detail "ok the tap formula points at $(release_tag) with both macOS checksums"
}

verify_aur_head() {
    local head expected
    head="$(remote_head_of "$AUR_URL" refs/heads/master)" || { problem "cannot read $AUR_URL"; return 0; }
    expected="$(recorded_value aur_commit)"
    if [[ -z "$head" ]]; then
        problem "the AUR repo has no master branch"
    elif [[ -z "$expected" ]]; then
        detail "AUR master is ${head:0:12} (no pushed commit recorded to compare)"
    elif [[ "$head" == "$expected" ]]; then
        detail "ok AUR master is the commit this script pushed (${head:0:12})"
    else
        problem "AUR master is ${head:0:12}, the script pushed ${expected:0:12}"
    fi
}

verify_container() {
    case "$(recorded_value docker)" in
        ghcr) docker manifest inspect "$IMAGE:$VERSION" >/dev/null 2>&1 && detail "ok $IMAGE:$VERSION is on ghcr.io" || problem "$IMAGE:$VERSION is not on ghcr.io" ;;
        tarball) detail "image attached to the release as a tarball (checked with the assets)" ;;
        *) detail "no container publish recorded" ;;
    esac
}

step_verify_release() {
    local latest
    if ! release_exists; then
        is_dry_run && { detail "$(release_tag) does not exist yet; after publishing this step downloads every asset and compares its sha256, checks it is not releases/latest, reads the tap formula and git ls-remotes the AUR repo"; return 0; }
        die "$(release_tag) does not exist on $MIRROR_REPO"
    fi
    latest="$(latest_release_tag)"
    [[ "$latest" != "$(release_tag)" ]] || problem "$(release_tag) is marked latest; get-flaccy.sh would download it. Run: gh release edit $latest -R $MIRROR_REPO --latest"
    verify_published_assets
    verify_tap_formula
    verify_aur_head
    verify_container
}

run_step() {
    local step="$1"
    if [[ -z "$ONLY" ]] && ! is_check_step "$step" && step_recorded "$step"; then
        say "$step: done earlier (publish.state)"
        return 0
    fi
    say "$step"
    "step_${step//-/_}"
    if ! is_dry_run && ! is_check_step "$step"; then
        record_step "$step"
    fi
}

cmd_publish() {
    local step
    if is_dry_run; then
        say "dry run for $VERSION: nothing is pushed, created, uploaded or committed anywhere"
    else
        say "PUBLISHING $VERSION"
    fi
    check_publish_tools
    if [[ -n "$ONLY" ]]; then
        run_step "$ONLY"
    else
        for step in "${STEPS[@]}"; do
            run_step "$step"
        done
    fi
    if is_dry_run; then
        summarize_dry_run
    else
        say "published $VERSION"
    fi
}

summarize_dry_run() {
    local problem
    if ((${#PROBLEMS[@]} == 0)); then
        say "dry run clean for ${ONLY:-every step}: a real run with --publish would go ahead"
        return 0
    fi
    say "dry run found ${#PROBLEMS[@]} blocking problem(s); a real run would stop at the first"
    for problem in "${PROBLEMS[@]}"; do
        echo "  - ${problem//$'\n'/ }"
    done
}

known_publish_step() {
    [[ " ${STEPS[*]} docker-tarball " == *" $1 "* ]]
}

require_option_value() {
    (($# >= 2)) && [[ -n "$2" ]] || die "$1 needs a value"
}

parse_options() {
    while (($#)); do
        case "$1" in
            --allow-dirty) ALLOW_DIRTY=1 ;;
            --publish) PUBLISH=1 ;;
            --push) PUSH=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --docker-fallback) DOCKER_FALLBACK=1 ;;
            --version) require_option_value "$@"; VERSION="$2"; shift ;;
            --only) require_option_value "$@"; ONLY="$2"; shift ;;
            *) usage >&2; die "unknown option $1" ;;
        esac
        shift
    done
    [[ "$PUSH" == 0 || "$PUBLISH" == 1 ]] || die "--push needs --publish as well; nothing is pushed without it"
    [[ "$DRY_RUN" == 0 || "$PUBLISH" == 0 ]] || die "--dry-run and --publish exclude each other"
    if [[ "$PUBLISH" == 1 && "$SUBCOMMAND" == all ]]; then
        PUSH=1
    fi
    validate_publish_options
}

validate_publish_options() {
    if [[ "$SUBCOMMAND" != publish ]]; then
        [[ -z "$VERSION$ONLY" && "$DRY_RUN" == 0 && "$DOCKER_FALLBACK" == 0 ]] || die "--version, --only, --dry-run and --docker-fallback belong to the publish command"
        return 0
    fi
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || die "publish needs --version X.Y.Z"
    [[ -z "$ONLY" ]] || known_publish_step "$ONLY" || die "unknown step $ONLY; steps: ${STEPS[*]} docker-tarball"
}

main() {
    [[ $# -ge 1 ]] || { usage >&2; exit 2; }
    SUBCOMMAND="$1"
    shift
    case "$SUBCOMMAND" in
        -h | --help | help) usage; exit 0 ;;
        build | macos | docker | deb | rpm | checksums | all | publish) ;;
        *) usage >&2; die "unknown command $SUBCOMMAND" ;;
    esac
    parse_options "$@"
    prepare_work_dir
    trap cleanup_on_exit EXIT
    if [[ "$SUBCOMMAND" == publish ]]; then
        OUT_DIR="$RELEASE_ROOT/$VERSION"
        cmd_publish
        return 0
    fi
    VERSION="$(manifest_version)"
    OUT_DIR="$RELEASE_ROOT/$VERSION"
    mkdir -p "$OUT_DIR"
    [[ "$SUBCOMMAND" == checksums ]] || require_clean_tree
    "cmd_$SUBCOMMAND"
}

main "$@"
