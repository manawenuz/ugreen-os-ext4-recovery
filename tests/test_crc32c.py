#!/usr/bin/env python3
"""
Regression test for patch_btrfs_ugos.crc32c.

**DO NOT REMOVE.** This is the regression guard for BUG-016, the worst
defect in the project's history (latent disk-corruption defect that
would have been triggered by anyone running recover_btrfs.sh on a real
device). See:
  - PRD_BUGS_BTRFS_PATCH.md → BUG-016
  - PRD_AUDIT_PATCHER_CRC_FIX.md
  - https://github.com/manawenuz/ugreen-os-ext4-recovery/issues/1

Summary of the bug: _build_crc32c_table used the FORWARD Castagnoli
polynomial (0x1EDC6F41) in an LSB-first (right-shift) table builder,
which requires the REFLECTED polynomial (0x82F63B78). The result was a
CRC that looked plausible on glance but disagreed with the kernel on
every non-trivial input.

This file pins:
  * 5 standard crc32c vectors (RFC 3720, iSCSI, well-known)
  * the structure of _CRC32C_TABLE itself (T[0]=0, T[1]=0xF26B8303,
    T[255]=0xAD7D5351, len=256) — catches subtle table-walker
    regressions that all-input vectors might miss
  * a patch_superblock → verify_superblock_crc round-trip on a
    synthetic 4 KiB SB — catches desync between patch-side and
    verify-side range/seed/table

If this file fails: STOP. Do not ship. The patcher will compute wrong
checksums; recover_btrfs.sh in write-mode will corrupt the target's
superblock.
"""
import os
import sys
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(REPO_ROOT, "scripts"))

from patch_btrfs_ugos import crc32c  # noqa: E402


class CRC32CStandardVectors(unittest.TestCase):
    """Known-answer tests from RFC 3720 §B.4 and adjacent references."""

    def test_rfc3720_check_value(self):
        self.assertEqual(crc32c(b"123456789"), 0xE3069283)

    def test_all_zero_32(self):
        self.assertEqual(crc32c(b"\x00" * 32), 0x8A9136AA)

    def test_all_ones_32(self):
        self.assertEqual(crc32c(b"\xff" * 32), 0x62A8AB43)

    def test_a_times_100(self):
        # Cross-validated against a manual reflected-poly implementation
        # and the `crc32c` PyPI package.
        self.assertEqual(crc32c(b"a" * 100), 0x5EA3AD99)

    def test_quick_brown_fox(self):
        self.assertEqual(
            crc32c(b"The quick brown fox jumps over the lazy dog"),
            0x22620404,
        )


class CRC32COnVolunteerSuperblocks(unittest.TestCase):
    """Validate against the SB dumps captured in issue #1.

    Each 4 KiB dump contains a btrfs superblock whose first 4 bytes are
    the kernel-computed crc32c over bytes 0x20..0x1000. Our crc32c must
    reproduce that value exactly.

    Skipped if the local dumps aren't present (CI etc.).
    """

    DUMP_DIR = os.path.expanduser(
        "~/Downloads/Download 2026-05-17T11-17-51-675Z/sbdumps/sb-dumps"
    )

    def setUp(self):
        if not os.path.isdir(self.DUMP_DIR):
            self.skipTest("volunteer SB dumps not present locally")

    def _check_mirror(self, name):
        import struct
        with open(os.path.join(self.DUMP_DIR, name), "rb") as fh:
            sb = fh.read(4096)
        self.assertEqual(len(sb), 4096, "SB dump must be exactly 4 KiB")
        self.assertEqual(sb[0x40:0x48], b"_BHRfS_M", "magic mismatch")
        on_disk = struct.unpack("<I", sb[0:4])[0]
        computed = crc32c(sb[0x20:0x1000])
        self.assertEqual(
            computed, on_disk,
            f"{name}: computed=0x{computed:08x} on_disk=0x{on_disk:08x}",
        )

    def test_pool1_mirror0(self):
        self._check_mirror("pool1_mirror0.bin")

    def test_pool1_mirror1(self):
        self._check_mirror("pool1_mirror1.bin")

    def test_pool1_mirror2(self):
        self._check_mirror("pool1_mirror2.bin")


class CRC32CTableStructure(unittest.TestCase):
    """Pin the structure of _CRC32C_TABLE itself.

    The original bug was 'right polynomial form, wrong table-build', and the
    standard test vectors above would catch it for sure. But a more subtle
    regression — e.g. someone swaps to an MSB-first table walker while
    keeping the LSB-first polynomial — could still pass on small inputs and
    fail on the 4064-byte SB body. Pinning two well-known entries gives us
    a direct check on the table itself.
    """

    def test_table_size(self):
        from patch_btrfs_ugos import _CRC32C_TABLE
        self.assertEqual(len(_CRC32C_TABLE), 256)

    def test_table_zero_entry(self):
        from patch_btrfs_ugos import _CRC32C_TABLE
        # T[0] is always 0 for any LFSR table build.
        self.assertEqual(_CRC32C_TABLE[0], 0)

    def test_table_one_entry(self):
        from patch_btrfs_ugos import _CRC32C_TABLE
        # Standard reflected Castagnoli T[1] is 0xF26B8303 (verified against
        # public references). If you regressed the polynomial form, you'd
        # land somewhere else here.
        self.assertEqual(_CRC32C_TABLE[1], 0xF26B8303)

    def test_table_last_entry(self):
        from patch_btrfs_ugos import _CRC32C_TABLE
        # Standard reflected Castagnoli T[255] is 0xAD7D5351.
        self.assertEqual(_CRC32C_TABLE[255], 0xAD7D5351)


class PatcherRoundTrip(unittest.TestCase):
    """Synthetic-block round-trip: patch_superblock then verify_superblock_crc.

    A future refactor that decouples the byte range, seed, or table walker
    between patch_superblock and verify_superblock_crc would be invisible to
    every other test but caught here.
    """

    def _make_synthetic_sb_with_ugacl(self):
        # Build a 4 KiB SB-shaped buffer with magic, valid csum_type, the
        # UGREEN bit set, and an initially-valid CRC.
        import struct
        from patch_btrfs_ugos import (
            BTRFS_SUPER_INFO_SIZE, BTRFS_SUPER_MAGIC,
            OFF_MAGIC, OFF_CSUM_TYPE, OFF_INCOMPAT_FLAGS,
            UGREEN_PROPRIETARY_BIT, crc32c,
        )
        block = bytearray(BTRFS_SUPER_INFO_SIZE)
        # Fill with deterministic non-zero noise so the CRC actually exercises bits.
        for i in range(BTRFS_SUPER_INFO_SIZE):
            block[i] = (i * 7 + 13) & 0xFF
        block[OFF_MAGIC:OFF_MAGIC + 8] = BTRFS_SUPER_MAGIC
        struct.pack_into("<H", block, OFF_CSUM_TYPE, 0)  # crc32c
        # Set UGREEN bit so patch_superblock has work to do.
        flags = struct.unpack_from("<Q", block, OFF_INCOMPAT_FLAGS)[0]
        flags |= UGREEN_PROPRIETARY_BIT
        struct.pack_into("<Q", block, OFF_INCOMPAT_FLAGS, flags)
        # Lay down a valid CRC for the pre-patch state.
        new_crc = crc32c(bytes(block[0x20:BTRFS_SUPER_INFO_SIZE]))
        struct.pack_into("<I", block, 0, new_crc)
        return block

    def test_patch_then_verify_passes(self):
        from patch_btrfs_ugos import (
            patch_superblock, verify_superblock_crc, verify_ugreen_flag_set,
        )
        block = self._make_synthetic_sb_with_ugacl()
        self.assertTrue(verify_ugreen_flag_set(block), "pre-condition: UGACL set")
        patch_superblock(block)
        self.assertFalse(verify_ugreen_flag_set(block), "UGACL must be cleared")
        ok, stored, computed = verify_superblock_crc(block)
        self.assertTrue(
            ok,
            f"post-patch CRC must validate: stored=0x{stored:08x} computed=0x{computed:08x}",
        )


if __name__ == "__main__":
    unittest.main()
