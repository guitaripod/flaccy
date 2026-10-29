#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LINUX_DIR="$(cd "$SCRIPT_DIR/../linux" && pwd)"
readonly DEFAULT_MINUTES=30
readonly DEFAULT_CLIENTS=4
readonly DEFAULT_SEED=1

usage() {
    echo "usage: server-soak.sh [--minutes N] [--clients K] [--seed S] [--release] [--keep] [--server-bin PATH]"
    echo "defaults: --minutes $DEFAULT_MINUTES --clients $DEFAULT_CLIENTS --seed $DEFAULT_SEED"
}

target_dir() {
    echo "${CARGO_TARGET_DIR:-$LINUX_DIR/target}"
}

build_profile_flag() {
    local release="$1"
    if [[ "$release" == "yes" ]]; then
        echo "--release"
    fi
}

build_binaries() {
    local release="$1"
    local flag
    flag="$(build_profile_flag "$release")"
    cargo build ${flag:+"$flag"} -p flaccy-soak -p flaccy-server --manifest-path "$LINUX_DIR/Cargo.toml"
}

soak_binary() {
    local release="$1"
    local profile="debug"
    if [[ "$release" == "yes" ]]; then
        profile="release"
    fi
    echo "$(target_dir)/$profile/flaccy-soak"
}

main() {
    local minutes="$DEFAULT_MINUTES"
    local clients="$DEFAULT_CLIENTS"
    local seed="$DEFAULT_SEED"
    local release="no"
    local passthrough=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --minutes) minutes="$2"; shift 2 ;;
            --clients) clients="$2"; shift 2 ;;
            --seed) seed="$2"; shift 2 ;;
            --release) release="yes"; shift ;;
            --keep) passthrough+=("--keep"); shift ;;
            --server-bin) passthrough+=("--server-bin" "$2"); shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; exit 2 ;;
        esac
    done
    build_binaries "$release"
    local release_flag=()
    if [[ "$release" == "yes" ]]; then
        release_flag=("--release")
    fi
    exec "$(soak_binary "$release")" run --minutes "$minutes" --clients "$clients" --seed "$seed" "${release_flag[@]}" "${passthrough[@]}"
}

main "$@"
