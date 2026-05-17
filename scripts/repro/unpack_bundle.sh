#!/bin/bash
#
# unpack_bundle.sh — extract a volunteer bundle into a working directory
# and verify it against its MANIFEST.txt.
#
# Usage:
#   ./scripts/repro/unpack_bundle.sh path/to/volunteer_bundle_<hash>_<date>.tar.gz [out-dir]
#
# Default out-dir: ./repro/<bundle-stem>/
#

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
fail() { printf '\n[%s] ERROR: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 1; }

[ $# -ge 1 ] || fail "usage: $0 <bundle.tar.gz> [out-dir]"
BUNDLE="$1"
[ -f "$BUNDLE" ] || fail "bundle not found: $BUNDLE"

STEM="$(basename "$BUNDLE" .tar.gz)"
OUT_DIR="${2:-$(pwd)/repro/$STEM}"

if [ -e "$OUT_DIR" ]; then
    fail "out-dir already exists: $OUT_DIR (refusing to overwrite)"
fi

mkdir -p "$OUT_DIR"
echo "[$SCRIPT_NAME] Extracting $BUNDLE → $OUT_DIR ..."
tar -C "$OUT_DIR" -xzf "$BUNDLE" || fail "tar extraction failed"

MANIFEST="$OUT_DIR/MANIFEST.txt"
[ -f "$MANIFEST" ] || fail "bundle has no MANIFEST.txt — refusing to trust it"

echo "[$SCRIPT_NAME] Verifying sha256 sums against MANIFEST.txt ..."
fail_count=0
total=0
while IFS=$'\t' read -r expected_sum expected_size rel _rationale; do
    [ -n "$rel" ] || continue
    case "$expected_sum" in '#'*|'') continue ;; esac
    total=$((total + 1))
    abs="$OUT_DIR/$rel"
    if [ ! -f "$abs" ]; then
        echo "  MISSING : $rel"
        fail_count=$((fail_count + 1))
        continue
    fi
    actual_sum="$(sha256sum "$abs" | awk '{print $1}')"
    actual_size="$(stat -c%s "$abs" 2>/dev/null || stat -f%z "$abs")"
    if [ "$actual_sum" != "$expected_sum" ] || [ "$actual_size" != "$expected_size" ]; then
        echo "  MISMATCH: $rel"
        echo "    expected sha=$expected_sum size=$expected_size"
        echo "    actual   sha=$actual_sum size=$actual_size"
        fail_count=$((fail_count + 1))
    fi
done < "$MANIFEST"

if [ "$fail_count" -gt 0 ]; then
    fail "$fail_count / $total file(s) failed verification — bundle is corrupt or tampered"
fi

echo "[$SCRIPT_NAME] OK — $total files verified."
echo "[$SCRIPT_NAME] Bundle ready at: $OUT_DIR"

# Summary of what's inside.
echo ""
echo "Contents:"
for d in system kernel rootfs sb config; do
    if [ -d "$OUT_DIR/$d" ]; then
        count=$(find "$OUT_DIR/$d" -type f | wc -l | tr -d ' ')
        size=$(du -sh "$OUT_DIR/$d" 2>/dev/null | awk '{print $1}')
        printf '  %-10s  %s file(s), %s\n' "$d/" "$count" "$size"
    fi
done
