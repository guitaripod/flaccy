#!/usr/bin/env bash
set -euo pipefail

MACOS_TRIPLES=(aarch64-apple-darwin x86_64-apple-darwin)
IOS_DEVICE_TRIPLES=(aarch64-apple-ios)
IOS_SIMULATOR_TRIPLES=(aarch64-apple-ios-sim x86_64-apple-ios)
ALL_PLATFORMS="macos ios ios-simulator"

usage() {
    cat <<USAGE
usage: $(basename "$0") CRATE_DIR MODULE_NAME OUT_DIR

Builds the UniFFI crate in CRATE_DIR for macOS (arm64+x86_64), iOS device and iOS
simulator (arm64+x86_64), generates the Swift bindings in library mode, and writes
OUT_DIR/MODULE_NAMEFFI.xcframework and OUT_DIR/Generated/. Debug symbols are stripped
from the XCFramework slices; the bindings are generated from the unstripped host library.

The crate needs a uniffi-bindgen bin behind a "bindgen" feature (see server-core-ffi).
XCFRAMEWORK_PLATFORMS picks the slices, default "macos ios ios-simulator"; "macos" builds the macOS slice alone.
XCFRAMEWORK_HEADERS=0 leaves the headers out of the XCFramework, for a package that carries them in a C target:
two XCFrameworks that both ship a module.modulemap overwrite each other in an Xcode build's include folder.
XCFRAMEWORK_STRIP=0 keeps the debug symbols: Xcode 27's strip -S breaks relocations in some Rust archives.
Cargo profile overrides pass through the environment, for example
CARGO_PROFILE_RELEASE_OPT_LEVEL=z CARGO_PROFILE_RELEASE_LTO=true.
MACOSX_DEPLOYMENT_TARGET (default 26.0) and IPHONEOS_DEPLOYMENT_TARGET (default 18.6) match project.yml, so the linker does not warn that the Rust objects are newer than the app.
USAGE
}

fail() {
    echo "error: $*" >&2
    exit 1
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "missing tool: $1"
}

require_tools() {
    local tool
    for tool in cargo rustup rustc lipo strip xcodebuild python3; do
        require_tool "$tool"
    done
}

absolute_path() {
    (cd "$1" && pwd)
}

host_triple() {
    rustc -vV | sed -n 's/^host: //p'
}

wants_platform() {
    [[ " ${XCFRAMEWORK_PLATFORMS:-$ALL_PLATFORMS} " == *" $1 "* ]]
}

selected_triples() {
    wants_platform macos && printf '%s\n' "${MACOS_TRIPLES[@]}"
    wants_platform ios && printf '%s\n' "${IOS_DEVICE_TRIPLES[@]}"
    wants_platform ios-simulator && printf '%s\n' "${IOS_SIMULATOR_TRIPLES[@]}"
    return 0
}

ensure_rust_targets() {
    local installed triple
    installed=$(rustup target list --installed)
    for triple in "${MACOS_TRIPLES[@]}" $(selected_triples); do
        grep -qx "$triple" <<<"$installed" || rustup target add "$triple"
    done
}

static_library_name() {
    cargo metadata --no-deps --format-version 1 --manifest-path "$CRATE_DIR/Cargo.toml" |
        python3 -c '
import json, os, sys
manifest = os.path.realpath(sys.argv[1])
for package in json.load(sys.stdin)["packages"]:
    if os.path.realpath(package["manifest_path"]) != manifest:
        continue
    for target in package["targets"]:
        if "staticlib" in target["crate_types"]:
            print(target["name"])
            raise SystemExit
raise SystemExit("crate has no staticlib target")
' "$CRATE_DIR/Cargo.toml"
}

cargo_target_dir() {
    echo "$OUT_DIR/cargo-target"
}

build_triple() {
    MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}" IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-18.6}" \
        cargo build --release --target "$1" \
        --manifest-path "$CRATE_DIR/Cargo.toml" \
        --target-dir "$(cargo_target_dir)"
}

built_library() {
    echo "$(cargo_target_dir)/$1/release/lib$LIB_NAME.a"
}

build_all_triples() {
    local triple
    for triple in "${MACOS_TRIPLES[@]}" $(selected_triples); do
        build_triple "$triple"
    done
}

fat_library() {
    local output=$1
    shift
    local inputs=() triple
    for triple in "$@"; do
        inputs+=("$(built_library "$triple")")
    done
    mkdir -p "$(dirname "$output")"
    lipo -create "${inputs[@]}" -output "$output"
}

make_slice_libraries() {
    SLICES_DIR="$OUT_DIR/slices"
    rm -rf "$SLICES_DIR"
    fat_library "$SLICES_DIR/macos/lib$LIB_NAME.a" "${MACOS_TRIPLES[@]}"
    wants_platform ios && fat_library "$SLICES_DIR/ios/lib$LIB_NAME.a" "${IOS_DEVICE_TRIPLES[@]}"
    wants_platform ios-simulator && fat_library "$SLICES_DIR/ios-simulator/lib$LIB_NAME.a" "${IOS_SIMULATOR_TRIPLES[@]}"
    return 0
}

strip_slice_libraries() {
    local library
    [[ "${XCFRAMEWORK_STRIP:-1}" == 0 ]] && return 0
    for library in "$SLICES_DIR"/*/lib"$LIB_NAME".a; do
        strip -S "$library" 2> >(grep -v 'already stripped' >&2 || true)
    done
}

generate_bindings() {
    GENERATED_DIR="$OUT_DIR/Generated"
    rm -rf "$GENERATED_DIR"
    mkdir -p "$GENERATED_DIR"
    (
        cd "$CRATE_DIR"
        cargo run --release --quiet \
            --target-dir "$(cargo_target_dir)/host-tools" \
            --features bindgen --bin uniffi-bindgen -- \
            generate --library "$(built_library "$(host_triple)")" \
            --language swift --out-dir "$GENERATED_DIR"
    )
}

ffi_header_name() {
    basename "$(ls "$GENERATED_DIR"/*FFI.h)"
}

ffi_modulemap_name() {
    basename "$(ls "$GENERATED_DIR"/*FFI.modulemap)"
}

make_headers_dir() {
    HEADERS_DIR="$OUT_DIR/headers"
    rm -rf "$HEADERS_DIR"
    mkdir -p "$HEADERS_DIR"
    cp "$GENERATED_DIR/$(ffi_header_name)" "$HEADERS_DIR/"
    cp "$GENERATED_DIR/$(ffi_modulemap_name)" "$HEADERS_DIR/module.modulemap"
}

create_xcframework() {
    XCFRAMEWORK="$OUT_DIR/${MODULE_NAME}FFI.xcframework"
    rm -rf "$XCFRAMEWORK"
    local libraries=() slice
    for slice in macos ios ios-simulator; do
        [[ -f "$SLICES_DIR/$slice/lib$LIB_NAME.a" ]] || continue
        libraries+=(-library "$SLICES_DIR/$slice/lib$LIB_NAME.a")
        [[ "${XCFRAMEWORK_HEADERS:-1}" == 0 ]] || libraries+=(-headers "$HEADERS_DIR")
    done
    xcodebuild -create-xcframework "${libraries[@]}" -output "$XCFRAMEWORK"
}

parse_arguments() {
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    CRATE_DIR=$(absolute_path "$1")
    MODULE_NAME=$2
    mkdir -p "$3"
    OUT_DIR=$(absolute_path "$3")
}

main() {
    parse_arguments "$@"
    require_tools
    ensure_rust_targets
    LIB_NAME=$(static_library_name)
    build_all_triples
    make_slice_libraries
    generate_bindings
    strip_slice_libraries
    make_headers_dir
    create_xcframework
    echo "xcframework: $XCFRAMEWORK"
}

main "$@"
