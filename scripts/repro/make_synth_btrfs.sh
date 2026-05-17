#!/bin/bash
#
# make_synth_btrfs.sh — synthesise a small btrfs filesystem with the
# UGACL incompat bit set, suitable for exercising patch_btrfs_ugos.py.
#
# Strategy:
#   1. Create a 256 MiB sparse file and mkfs.btrfs onto it.
#   2. Read the freshly-written superblock from offset 64 KiB.
#   3. Set bit 62 (0x4000000000000000) in incompat_flags at offset 0xBC.
#   4. Recompute crc32c over bytes 0x20..0xFFF (our current model — the
#      whole point is to see whether this matches a UGACL-aware oracle).
#   5. Write the patched SB back to all three mirror offsets that fit.
#
# Output: synth_btrfs.img in the chosen dir.
#
# Usage:
#   sudo ./scripts/repro/make_synth_btrfs.sh [--out vm/synth_btrfs.img]
#
# Notes:
#   - Requires root (loop device + mkfs).
#   - Uses standard btrfs-progs; result is a btrfs that *our* current
#     CRC routine considers valid. Whether the kernel agrees is the
#     entire question we're trying to answer with the repro harness.
#

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
fail() { printf '\n[%s] ERROR: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 1; }
note() { printf '[%s] %s\n' "$SCRIPT_NAME" "$1"; }

OUT="vm/synth_btrfs.img"
SIZE_MIB=256

while [ $# -gt 0 ]; do
    case "$1" in
        --out=*)  OUT="${1#--out=}" ;;
        --out)    shift; OUT="${1:-$OUT}" ;;
        --size=*) SIZE_MIB="${1#--size=}" ;;
        --size)   shift; SIZE_MIB="${1:-$SIZE_MIB}" ;;
        -h|--help)
            sed -n '2,28p' "$0"; exit 0
            ;;
        *) fail "unknown arg '$1'" ;;
    esac
    shift
done

[ "${EUID:-$(id -u)}" -eq 0 ] || fail "must run as root (need loop device + mkfs.btrfs)"
command -v mkfs.btrfs >/dev/null || fail "mkfs.btrfs not found. Install btrfs-progs."
command -v python3    >/dev/null || fail "python3 not found"

mkdir -p "$(dirname "$OUT")"
note "Creating $SIZE_MIB MiB sparse image at $OUT ..."
truncate -s "${SIZE_MIB}M" "$OUT" || fail "truncate failed"

note "mkfs.btrfs ..."
mkfs.btrfs -f -L synthugos "$OUT" >/dev/null || fail "mkfs.btrfs failed"

note "Setting UGACL incompat bit (0x4000000000000000) on all SB mirrors ..."
python3 - "$OUT" <<'PY' || fail "SB patch script failed"
import struct, sys, zlib

# crc32c via Python's standard zlib only gives crc32 (poly 0xEDB88320),
# not crc32c (poly 0x1EDC6F41). Use the btrfs-style crc32c implementation
# matching what patch_btrfs_ugos.py uses today.
def crc32c(data, init=0):
    # Software crc32c, Castagnoli polynomial. Slow but correct, fine for 4 KiB.
    #
    # NOTE: the polynomial below is the REFLECTED form (0x82F63B78), which is
    # what the LSB-first (right-shift) loop here requires. The FORWARD form is
    # 0x1EDC6F41 and pairs with an MSB-first (left-shift) loop. Mixing the two
    # is the bug that produced wrongly-computed superblock CRCs in
    # patch_btrfs_ugos.py for an entire release cycle — see issue #1 and
    # tests/test_crc32c.py. If you're copying this routine, KEEP the reflected
    # polynomial paired with the right-shift loop, or use the forward poly with
    # a left-shift loop. Validated against RFC 3720 test vectors.
    crc = init ^ 0xFFFFFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ (0x82F63B78 & -(crc & 1))
    return crc ^ 0xFFFFFFFF

path = sys.argv[1]
SB_OFFSETS = [0x10000, 0x4000000, 0x4000000000]   # 64 KiB, 64 MiB, 256 GiB
UGACL = 0x4000000000000000

size = 0
with open(path, "rb") as fh:
    fh.seek(0, 2); size = fh.tell()

with open(path, "r+b") as fh:
    for off in SB_OFFSETS:
        if off + 4096 > size:
            print(f"  skip mirror at 0x{off:x} (past EOF for {size}-byte image)")
            continue
        fh.seek(off)
        sb = bytearray(fh.read(4096))
        if sb[0x40:0x48] != b"_BHRfS_M":
            print(f"  skip mirror at 0x{off:x} (no _BHRfS_M magic)")
            continue
        # incompat_flags is u64 LE at offset 0xBC.
        flags = struct.unpack_from("<Q", sb, 0xBC)[0]
        new_flags = flags | UGACL
        struct.pack_into("<Q", sb, 0xBC, new_flags)
        # Recompute crc32c over bytes 0x20..0xFFF, store as u32 LE at 0x00.
        # First 32 bytes are the checksum field (zeroed for the hash input).
        zero_csum = bytearray(sb)
        for i in range(0x20):
            zero_csum[i] = 0
        new_crc = crc32c(bytes(zero_csum[0x20:0x1000]))
        # Wait — btrfs hashes the WHOLE 4 KiB but zeroes the first 32 bytes
        # of the checksum field. Confirm the exact range against btrfs source.
        # For now: hash 0x20..0xFFF (per PRD §2). This is the very thing
        # the repro harness is meant to test against the kernel's view.
        struct.pack_into("<I", sb, 0x00, new_crc & 0xFFFFFFFF)
        fh.seek(off)
        fh.write(sb)
        print(f"  patched mirror at 0x{off:x}: flags 0x{flags:x} → 0x{new_flags:x}, crc=0x{new_crc:08x}")
PY

note "Synth btrfs image ready: $OUT"
note "Sanity-check with: btrfs inspect-internal dump-super -fa $OUT"
