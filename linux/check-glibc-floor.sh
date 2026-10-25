#!/usr/bin/env bash
# Fails when a release binary needs a newer glibc than the floor the README promises.
#   ./check-glibc-floor.sh target/release/flaccy [2.39]
set -euo pipefail
BINARY=$1
FLOOR=${2:-2.39}
needed=$(objdump -T "$BINARY" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/GLIBC_//' | sort -Vu | tail -1)
if [[ "$(printf '%s\n%s\n' "$FLOOR" "$needed" | sort -V | tail -1)" != "$FLOOR" ]]; then
    echo "error: $BINARY needs glibc $needed, above the $FLOOR floor:" >&2
    objdump -T "$BINARY" | grep -E "GLIBC_$needed" >&2
    exit 1
fi
echo "glibc floor ok: needs $needed (floor $FLOOR)"
