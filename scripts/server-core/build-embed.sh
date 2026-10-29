#!/usr/bin/env bash
set -euo pipefail

MODULE_NAME=FlaccyServerEmbed
CRATE_PATH=linux/server-embed-ffi
PACKAGE_PATH=Core/FlaccyServerEmbed
HEADERS_TARGET=flaccy_server_embed_ffiFFI
MAC_HOST=macbook
MAC_APP_DIR=Dev/builds/flaccy-server-embed/app
SYNCED_PATHS=(linux scripts/server-core "$PACKAGE_PATH")
RSYNC_EXCLUDES=(--exclude=target --exclude=.build --exclude=.swiftpm --exclude=Artifacts)

fail() {
    echo "error: $*" >&2
    exit 1
}

app_root() {
    (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
}

push_sources_to_mac() {
    ssh "$MAC_HOST" "mkdir -p '$MAC_APP_DIR'"
    (cd "$(app_root)" && rsync -aR --delete "${RSYNC_EXCLUDES[@]}" "${SYNCED_PATHS[@]}" "$MAC_HOST:$MAC_APP_DIR/")
}

run_on_mac() {
    ssh "$MAC_HOST" "cd '$MAC_APP_DIR' && PATH=\"\$HOME/.cargo/bin:\$PATH\" scripts/server-core/build-embed.sh"
}

pull_artifacts_from_mac() {
    local root
    root=$(app_root)
    mkdir -p "$root/$PACKAGE_PATH/Artifacts"
    rsync -a --delete "$MAC_HOST:$MAC_APP_DIR/$PACKAGE_PATH/Artifacts/" "$root/$PACKAGE_PATH/Artifacts/"
    rsync -a "$MAC_HOST:$MAC_APP_DIR/$PACKAGE_PATH/Sources/${MODULE_NAME}Bindings/" \
        "$root/$PACKAGE_PATH/Sources/${MODULE_NAME}Bindings/"
    rsync -a "$MAC_HOST:$MAC_APP_DIR/$PACKAGE_PATH/Sources/$HEADERS_TARGET/include/" \
        "$root/$PACKAGE_PATH/Sources/$HEADERS_TARGET/include/"
}

build_on_arch() {
    push_sources_to_mac
    run_on_mac
    pull_artifacts_from_mac
}

export_release_profile() {
    export CARGO_PROFILE_RELEASE_OPT_LEVEL=3
    export CARGO_PROFILE_RELEASE_LTO=false
    export CARGO_PROFILE_RELEASE_STRIP=none
    export CARGO_PROFILE_RELEASE_PANIC=unwind
    export CARGO_PROFILE_RELEASE_DEBUG=0
}

install_artifacts() {
    local root=$1 out_dir=$2 package sources headers
    package="$root/$PACKAGE_PATH"
    sources="$package/Sources/${MODULE_NAME}Bindings"
    headers="$package/Sources/$HEADERS_TARGET/include"
    rm -rf "$package/Artifacts"
    mkdir -p "$package/Artifacts" "$sources" "$headers"
    cp -R "$out_dir/${MODULE_NAME}FFI.xcframework" "$package/Artifacts/"
    rm -f "$sources"/*.swift "$headers"/*.h
    cp "$out_dir"/Generated/*.swift "$sources/"
    cp "$out_dir"/Generated/*.h "$headers/"
}

build_on_mac() {
    local root out_dir
    root=$(app_root)
    out_dir="${SERVER_EMBED_BUILD_DIR:-$HOME/Dev/builds/flaccy-server-embed/out}"
    export_release_profile
    XCFRAMEWORK_PLATFORMS=macos XCFRAMEWORK_STRIP=0 XCFRAMEWORK_HEADERS=0 "$root/scripts/server-core/build-xcframework.sh" "$root/$CRATE_PATH" "$MODULE_NAME" "$out_dir"
    install_artifacts "$root" "$out_dir"
    du -sh "$root/$PACKAGE_PATH/Artifacts"
}

main() {
    [[ $# -eq 0 ]] || fail "takes no arguments"
    case "$(uname -s)" in
        Darwin) build_on_mac ;;
        Linux) build_on_arch ;;
        *) fail "unsupported host $(uname -s)" ;;
    esac
}

main "$@"
