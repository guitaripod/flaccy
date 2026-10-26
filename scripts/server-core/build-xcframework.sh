#!/usr/bin/env bash
set -euo pipefail

MACOS_TRIPLES=(aarch64-apple-darwin x86_64-apple-darwin)
IOS_DEVICE_TRIPLES=(aarch64-apple-ios)
IOS_SIMULATOR_TRIPLES=(aarch64-apple-ios-sim x86_64-apple-ios)

usage() {
    cat <<USAGE
usage: $(basename "$0") CRATE_DIR MODULE_NAME OUT_DIR [--package-template DIR] [--test]

Builds the UniFFI crate in CRATE_DIR for macOS (arm64+x86_64), iOS device and iOS
simulator (arm64+x86_64), generates the Swift bindings in library mode, and writes
OUT_DIR/MODULE_NAMEFFI.xcframework and OUT_DIR/Generated/.
With --package-template the template is copied to OUT_DIR/Package, the XCFramework
and the generated Swift file are placed in it, and --test runs swift test there.

The crate needs a uniffi-bindgen bin behind a "bindgen" feature (see toy-core).
Cargo profile overrides pass through the environment, for example
CARGO_PROFILE_RELEASE_OPT_LEVEL=z CARGO_PROFILE_RELEASE_LTO=true.
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
    for tool in cargo rustup rustc lipo xcodebuild python3 swift; do
        require_tool "$tool"
    done
}

absolute_path() {
    (cd "$1" && pwd)
}

host_triple() {
    rustc -vV | sed -n 's/^host: //p'
}

ensure_rust_targets() {
    local installed triple
    installed=$(rustup target list --installed)
    for triple in "${MACOS_TRIPLES[@]}" "${IOS_DEVICE_TRIPLES[@]}" "${IOS_SIMULATOR_TRIPLES[@]}"; do
        grep -qx "$triple" <<<"$installed" || rustup target add "$triple"
    done
}

static_library_name() {
    cargo metadata --no-deps --format-version 1 --manifest-path "$CRATE_DIR/Cargo.toml" |
        python3 -c '
import json, sys
for package in json.load(sys.stdin)["packages"]:
    for target in package["targets"]:
        if "staticlib" in target["crate_types"]:
            print(target["name"])
            raise SystemExit
raise SystemExit("crate has no staticlib target")
'
}

cargo_target_dir() {
    echo "$OUT_DIR/cargo-target"
}

build_triple() {
    cargo build --release --target "$1" \
        --manifest-path "$CRATE_DIR/Cargo.toml" \
        --target-dir "$(cargo_target_dir)"
}

built_library() {
    echo "$(cargo_target_dir)/$1/release/lib$LIB_NAME.a"
}

build_all_triples() {
    local triple
    for triple in "${MACOS_TRIPLES[@]}" "${IOS_DEVICE_TRIPLES[@]}" "${IOS_SIMULATOR_TRIPLES[@]}"; do
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
    fat_library "$SLICES_DIR/ios/lib$LIB_NAME.a" "${IOS_DEVICE_TRIPLES[@]}"
    fat_library "$SLICES_DIR/ios-simulator/lib$LIB_NAME.a" "${IOS_SIMULATOR_TRIPLES[@]}"
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
    xcodebuild -create-xcframework \
        -library "$SLICES_DIR/macos/lib$LIB_NAME.a" -headers "$HEADERS_DIR" \
        -library "$SLICES_DIR/ios/lib$LIB_NAME.a" -headers "$HEADERS_DIR" \
        -library "$SLICES_DIR/ios-simulator/lib$LIB_NAME.a" -headers "$HEADERS_DIR" \
        -output "$XCFRAMEWORK"
}

substitute_xcframework_path() {
    local manifest="$1/Package.swift" content
    content=$(<"$manifest")
    printf '%s\n' "${content//__XCFRAMEWORK_PATH__/${MODULE_NAME}FFI.xcframework}" >"$manifest"
}

assemble_package() {
    PACKAGE_DIR="$OUT_DIR/Package"
    rm -rf "$PACKAGE_DIR"
    cp -R "$PACKAGE_TEMPLATE" "$PACKAGE_DIR"
    substitute_xcframework_path "$PACKAGE_DIR"
    cp -R "$XCFRAMEWORK" "$PACKAGE_DIR/"
    rm -f "$PACKAGE_DIR/Sources/${MODULE_NAME}Bindings"/*.swift "$PACKAGE_DIR/Sources/${MODULE_NAME}Bindings/README.txt"
    mkdir -p "$PACKAGE_DIR/Sources/${MODULE_NAME}Bindings"
    cp "$GENERATED_DIR"/*.swift "$PACKAGE_DIR/Sources/${MODULE_NAME}Bindings/"
}

run_package_tests() {
    (cd "$PACKAGE_DIR" && swift test)
}

parse_arguments() {
    [[ $# -ge 3 ]] || { usage >&2; exit 2; }
    CRATE_DIR=$(absolute_path "$1")
    MODULE_NAME=$2
    mkdir -p "$3"
    OUT_DIR=$(absolute_path "$3")
    shift 3
    PACKAGE_TEMPLATE=""
    RUN_TESTS=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --package-template) PACKAGE_TEMPLATE=$(absolute_path "$2"); shift 2 ;;
            --test) RUN_TESTS=1; shift ;;
            *) usage >&2; exit 2 ;;
        esac
    done
    [[ $RUN_TESTS -eq 0 || -n $PACKAGE_TEMPLATE ]] || fail "--test needs --package-template"
}

main() {
    parse_arguments "$@"
    require_tools
    ensure_rust_targets
    LIB_NAME=$(static_library_name)
    build_all_triples
    make_slice_libraries
    generate_bindings
    make_headers_dir
    create_xcframework
    if [[ -n $PACKAGE_TEMPLATE ]]; then
        assemble_package
        [[ $RUN_TESTS -eq 0 ]] || run_package_tests
    fi
    echo "xcframework: $XCFRAMEWORK"
}

main "$@"
