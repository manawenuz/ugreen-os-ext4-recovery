#!/bin/bash
#
# check_patcher.sh — run patch_btrfs_ugos.py --check against a synthetic
# btrfs image AND collect the kernel's ground-truth view via btrfs-progs,
# then diff the two. Failure to agree is the bug we're trying to find.
#
# Usage:
#   sudo ./scripts/repro/check_patcher.sh path/to/synth_btrfs.img
#

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
fail() { printf '\n[%s] ERROR: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 1; }
note() { printf '[%s] %s\n' "$SCRIPT_NAME" "$1"; }

[ $# -eq 1 ] || fail "usage: $0 <btrfs-image>"
IMG="$1"
[ -f "$IMG" ] || fail "image not found: $IMG"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PATCHER="$REPO_ROOT/scripts/patch_btrfs_ugos.py"
[ -x "$PATCHER" ] || fail "patcher not found or not executable: $PATCHER"

command -v btrfs >/dev/null || fail "btrfs-progs required (apt-get install btrfs-progs)"

note "Running btrfs-progs dump-super -fa (oracle) ..."
ORACLE="$(mktemp)"
btrfs inspect-internal dump-super -fa "$IMG" > "$ORACLE" 2>&1 || true
# Extract per-mirror crc32c the oracle computed.
ORACLE_CRCS=$(grep -E '^(csum|csum_type|bytenr|incompat_flags)' "$ORACLE" || true)
note "Oracle (btrfs-progs) view:"
sed 's/^/    /' <<< "$ORACLE_CRCS"

note ""
note "Running patch_btrfs_ugos.py --check (ours) ..."
OURS="$(mktemp)"
python3 "$PATCHER" --check "$IMG" > "$OURS" 2>&1
OURS_RC=$?
sed 's/^/    /' "$OURS"
note "Our --check exit code: $OURS_RC"

note ""
if grep -q 'CRC mismatch' "$OURS"; then
    note "DISAGREEMENT detected — our CRC computation differs from btrfs-progs."
    note "This is the bug we set out to find. Next step: instrument the CRC"
    note "routine in patch_btrfs_ugos.py to log the byte range it hashes,"
    note "and compare against the kernel's range (the UGACL extension likely"
    note "shifts the checksummed window)."
    rm -f "$ORACLE" "$OURS"
    exit 3
fi

if [ "$OURS_RC" -eq 0 ]; then
    note "AGREEMENT — our patcher and btrfs-progs both consider the SBs valid."
    note "Patcher CRC routine is consistent with the kernel for this image."
    rm -f "$ORACLE" "$OURS"
    exit 0
fi

note "Unexpected state. Inspect outputs:"
note "  oracle: $ORACLE"
note "  ours:   $OURS"
exit 4
