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
TOOLCHAIN="${FLACCY_SERVER_TOOLCHAIN:-stable}"
RELEASE_ROOT="${FLACCY_SERVER_RELEASE_DIR:-$HOME/.cache/flaccy-server-release}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$RELEASE_ROOT/target}"

ALLOW_DIRTY=0
PUBLISH=0
PUSH=0
VERSION=""
OUT_DIR=""
SUBCOMMAND=""

usage() {
    cat <<'EOF'
Usage: scripts/server-release.sh <command> [--allow-dirty] [--publish] [--push]

Commands:
  build      Static musl tarballs for x86_64 and aarch64, each with a .sha256 file
  docker     Build ghcr.io/guitaripod/flaccy-server:<version> and :latest
  deb        .deb packages for x86_64 and aarch64
  rpm        .rpm packages for x86_64 and aarch64
  checksums  SHA256SUMS, plus the PKGBUILD and Homebrew formula filled in with the release
  all        build, deb, rpm, docker, checksums

Options:
  --allow-dirty  Build although the working tree has uncommitted changes
  --push         With docker: push both tags (also needs --publish)
  --publish      Allow pushing. Nothing is ever pushed or published without it

Output goes to ~/.cache/flaccy-server-release/<version>/ (FLACCY_SERVER_RELEASE_DIR
moves the root). The version comes from linux/server/Cargo.toml. Release tarballs for
macOS (flaccy-server-<version>-macos-{arm64,x86_64}.tar.gz) built on a Mac and copied
into that directory are picked up by checksums.
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

stage_tarball() {
    local arch="$1" name stage
    name="$(tarball_name "$arch")"
    stage="$(mktemp -d)"
    mkdir "$stage/$name"
    cp "$(binary_path "$arch")" "$stage/$name/flaccy-server"
    cp "$SERVER_DIR/flaccy-server.service" "$SERVER_DIR/README.md" "$LINUX_DIR/LICENSE" "$stage/$name/"
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$(git -C "$APP_DIR" log -1 --format=%ct)" \
        -C "$stage" -cf - "$name" | gzip -n -9 > "$OUT_DIR/$name.tar.gz"
    rm -rf "$stage"
    (cd "$OUT_DIR" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
}

cmd_build() {
    prepare_toolchain
    local arch
    for arch in "${ARCHES[@]}"; do
        build_binary "$arch"
        stage_tarball "$arch"
    done
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

parse_options() {
    while (($#)); do
        case "$1" in
            --allow-dirty) ALLOW_DIRTY=1 ;;
            --publish) PUBLISH=1 ;;
            --push) PUSH=1 ;;
            *) usage >&2; die "unknown option $1" ;;
        esac
        shift
    done
    [[ "$PUSH" == 0 || "$PUBLISH" == 1 ]] || die "--push needs --publish as well; nothing is pushed without it"
    if [[ "$PUBLISH" == 1 && "$SUBCOMMAND" == all ]]; then
        PUSH=1
    fi
}

main() {
    [[ $# -ge 1 ]] || { usage >&2; exit 2; }
    SUBCOMMAND="$1"
    shift
    case "$SUBCOMMAND" in
        -h | --help | help) usage; exit 0 ;;
        build | docker | deb | rpm | checksums | all) ;;
        *) usage >&2; die "unknown command $SUBCOMMAND" ;;
    esac
    parse_options "$@"
    VERSION="$(manifest_version)"
    OUT_DIR="$RELEASE_ROOT/$VERSION"
    mkdir -p "$OUT_DIR"
    [[ "$SUBCOMMAND" == checksums ]] || require_clean_tree
    "cmd_$SUBCOMMAND"
}

main "$@"
