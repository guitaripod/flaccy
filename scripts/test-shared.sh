#!/usr/bin/env bash
# The two-language parity proof: FlaccyCore's XCTest cases and their Rust
# mirrors in linux/shared. Neither half is authoritative on its own — the load
# bar's weights, the enrichment backoff ladder and the surface routing are
# asserted twice, with the same numbers, so a change to one language that
# forgets the other fails here rather than in a user's library.
#
# Both suites always run, even when the first fails, and both counts are
# printed: a suite that silently executed zero tests is the failure mode this
# script exists to make visible.
#
#   scripts/test-shared.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SWIFT_LOG="$(mktemp -t flaccy-swift-tests)"
RUST_LOG="$(mktemp -t flaccy-rust-tests)"
trap 'rm -f "$SWIFT_LOG" "$RUST_LOG"' EXIT

echo "== swift test --package-path FlaccyCore"
swift test --package-path FlaccyCore 2>&1 | tee "$SWIFT_LOG"
swift_status=${PIPESTATUS[0]}

echo
echo "== cargo test -p flaccy-shared --manifest-path linux/Cargo.toml"
cargo test -p flaccy-shared --manifest-path linux/Cargo.toml 2>&1 | tee "$RUST_LOG"
rust_status=${PIPESTATUS[0]}

swift_count=$(grep -oE 'Executed [0-9]+ test' "$SWIFT_LOG" | tail -1 | grep -oE '[0-9]+' || true)
rust_count=$(grep -oE '^test result: [a-z]+\. [0-9]+ passed' "$RUST_LOG" |
    awk '{ total += $4 } END { print total + 0 }')

echo
echo "FlaccyCore  : ${swift_count:-0} tests, exit $swift_status"
echo "flaccy-shared: ${rust_count:-0} tests, exit $rust_status"

if [[ "$swift_status" -ne 0 || "$rust_status" -ne 0 ]]; then
    echo "** SHARED TESTS FAILED **"
    exit 1
fi
if [[ "${swift_count:-0}" -eq 0 || "${rust_count:-0}" -eq 0 ]]; then
    echo "** A SHARED SUITE RAN NO TESTS **"
    exit 1
fi
echo "** SHARED TESTS PASSED **"
