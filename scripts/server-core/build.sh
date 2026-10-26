#!/usr/bin/env bash
set -euo pipefail

MODULE_NAME=FlaccyServerCore
CRATE_PATH=linux/server-core-ffi
PACKAGE_PATH=Core/FlaccyServerCore
MAC_HOST=macbook
MAC_APP_DIR=Dev/builds/flaccy-server-core/app
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
    ssh "$MAC_HOST" "cd '$MAC_APP_DIR' && PATH=\"\$HOME/.cargo/bin:\$PATH\" scripts/server-core/build.sh"
}

pull_artifacts_from_mac() {
    local root
    root=$(app_root)
    mkdir -p "$root/$PACKAGE_PATH/Artifacts"
    rsync -a --delete "$MAC_HOST:$MAC_APP_DIR/$PACKAGE_PATH/Artifacts/" "$root/$PACKAGE_PATH/Artifacts/"
    rsync -a "$MAC_HOST:$MAC_APP_DIR/$PACKAGE_PATH/Sources/${MODULE_NAME}Bindings/" \
        "$root/$PACKAGE_PATH/Sources/${MODULE_NAME}Bindings/"
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
    local root=$1 out_dir=$2 package sources
    package="$root/$PACKAGE_PATH"
    sources="$package/Sources/${MODULE_NAME}Bindings"
    rm -rf "$package/Artifacts"
    mkdir -p "$package/Artifacts" "$sources"
    cp -R "$out_dir/${MODULE_NAME}FFI.xcframework" "$package/Artifacts/"
    rm -f "$sources"/*.swift
    cp "$out_dir"/Generated/*.swift "$sources/"
}

build_on_mac() {
    local root out_dir
    root=$(app_root)
    out_dir="${SERVER_CORE_BUILD_DIR:-$HOME/Dev/builds/flaccy-server-core/out}"
    export_release_profile
    "$root/scripts/server-core/build-xcframework.sh" "$root/$CRATE_PATH" "$MODULE_NAME" "$out_dir"
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
