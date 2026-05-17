#!/usr/bin/env python3
"""
patch_btrfs_ugos.py

Directly manipulates BTRFS superblocks on a target block device to clear
the proprietary UGREEN OS 'ugacl' incompatible feature flag (bit 62,
0x4000000000000000) and recalculate the CRC32C checksum.

Usage:
    # Read-only verification
    sudo ./patch_btrfs_ugos.py --check /dev/mapper/<your-btrfs-volume>

    # Dump superblocks for offline analysis (read-only)
    sudo ./patch_btrfs_ugos.py --dump /dev/mapper/<your-btrfs-volume>

    # Patch (DANGEROUS — only run on COW snapshots or after validation)
    sudo ./patch_btrfs_ugos.py --yes /dev/mapper/<your-btrfs-volume>

    # Patch with backups to a safe directory
    sudo ./patch_btrfs_ugos.py --yes --backup-dir /mnt/other-disk/backups /dev/mapper/...

See recover_btrfs.sh for the safe COW-snapshot recovery flow.
"""

import argparse
import os
import stat
import struct
import subprocess
import sys
import time
from pathlib import Path

# ── BTRFS superblock constants ───────────────────────────────────────────────
# Verified against linux/include/uapi/linux/btrfs_tree.h (kernel 6.x)
BTRFS_SUPER_MAGIC = b"_BHRfS_M"
BTRFS_SUPER_INFO_SIZE = 4096
BTRFS_CSUM_SIZE = 32

# Standard mirror locations per kernel source fs/btrfs/disk-io.c
BTRFS_SUPER_OFFSETS = [
    64 * 1024,                # 64 KiB
    64 * 1024 * 1024,         # 64 MiB
    256 * 1024 * 1024 * 1024, # 256 GiB
]

# ── Field offsets within struct btrfs_super_block ────────────────────────────
# struct btrfs_super_block is __packed__; these are exact byte offsets.
OFF_CSUM = 0x00          # 32 bytes (first N are actual checksum)
OFF_CSUM_DATA_START = 0x20  # CRC covers everything from here to end
OFF_FSID = 0x20          # 16 bytes
OFF_BYTENR = 0x30        # 8 bytes — MUST match physical mirror offset
OFF_FLAGS = 0x38         # 8 bytes
OFF_MAGIC = 0x40         # 8 bytes — '_BHRfS_M'
OFF_GENERATION = 0x48    # 8 bytes
OFF_INCOMPAT_FLAGS = 0xBC  # 8 bytes — THIS IS THE TARGET FIELD
OFF_CSUM_TYPE = 0xC4     # 2 bytes — must be 0 (CRC32C)

# UGREEN proprietary incompatible feature flag (bit 62)
UGREEN_PROPRIETARY_BIT = 0x4000000000000000


# ── CRC32C (Castagnoli) implementation ───────────────────────────────────────

def _build_crc32c_table():
    # Castagnoli polynomial.
    #   Forward form (MSB-first):   0x1EDC6F41
    #   Reflected form (LSB-first): 0x82F63B78
    # This table-build is LSB-first (we right-shift `crc` below), so we MUST
    # use the reflected polynomial. Using the forward form here silently
    # produces a CRC that LOOKS like crc32c on cursory inspection but
    # disagrees with the kernel on every non-trivial input — which is
    # exactly the bug we hunted via the volunteer report in issue #1.
    # Validated against RFC 3720 test vectors.
    poly = 0x82F63B78
    table = []
    for i in range(256):
        crc = i
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ poly
            else:
                crc >>= 1
        table.append(crc & 0xFFFFFFFF)
    return table


_CRC32C_TABLE = _build_crc32c_table()


def crc32c(data: bytes, seed: int = 0xFFFFFFFF) -> int:
    """Compute CRC32C (Castagnoli) over `data`."""
    crc = seed
    for byte in data:
        crc = (crc >> 8) ^ _CRC32C_TABLE[(crc ^ byte) & 0xFF]
    return crc ^ 0xFFFFFFFF


# ── Core helpers ─────────────────────────────────────────────────────────────

def find_valid_superblocks(device_path: str):
    """
    Read superblocks from all known mirror offsets.
    Returns a list of (offset, bytearray) tuples for blocks with valid magic.
    """
    valid = []
    with open(device_path, "rb") as f:
        for offset in BTRFS_SUPER_OFFSETS:
            f.seek(offset)
            block = bytearray(f.read(BTRFS_SUPER_INFO_SIZE))
            if len(block) != BTRFS_SUPER_INFO_SIZE:
                continue  # Device smaller than this offset
            magic = bytes(block[OFF_MAGIC:OFF_MAGIC + 8])
            if magic == BTRFS_SUPER_MAGIC:
                valid.append((offset, block))
    return valid


def verify_superblock_crc(block: bytearray) -> tuple[bool, int, int]:
    """
    Verify the stored CRC32C against the block body.
    Returns (ok, stored_crc, computed_crc).
    """
    stored_crc = struct.unpack("<I", block[OFF_CSUM:OFF_CSUM + 4])[0]
    # Zero out checksum area, compute CRC over the remainder
    saved_csum = block[OFF_CSUM:OFF_CSUM + BTRFS_CSUM_SIZE]
    block[OFF_CSUM:OFF_CSUM + BTRFS_CSUM_SIZE] = b"\x00" * BTRFS_CSUM_SIZE
    computed_crc = crc32c(block[OFF_CSUM_DATA_START:BTRFS_SUPER_INFO_SIZE])
    block[OFF_CSUM:OFF_CSUM + BTRFS_CSUM_SIZE] = saved_csum
    return (stored_crc == computed_crc, stored_crc, computed_crc)


def verify_bytenr_matches(offset: int, block: bytearray) -> bool:
    """
    The bytenr field at 0x30 must equal the physical offset where we read
    the block. This confirms we are correctly aligned.
    """
    bytenr = struct.unpack("<Q", block[OFF_BYTENR:OFF_BYTENR + 8])[0]
    return bytenr == offset


def verify_csum_type_crc32c(block: bytearray) -> bool:
    """Return True if csum_type is 0 (CRC32C), which is what we support."""
    csum_type = struct.unpack("<H", block[OFF_CSUM_TYPE:OFF_CSUM_TYPE + 2])[0]
    return csum_type == 0


def verify_ugreen_flag_set(block: bytearray) -> bool:
    """Return True if the UGREEN proprietary bit is present in incompat_flags."""
    flags = struct.unpack("<Q", block[OFF_INCOMPAT_FLAGS:OFF_INCOMPAT_FLAGS + 8])[0]
    return bool(flags & UGREEN_PROPRIETARY_BIT)


def patch_superblock(block: bytearray) -> None:
    """
    Clear the UGREEN proprietary bit and recalculate the CRC32C checksum.
    Modifies `block` in place.
    """
    # 1. Clear the proprietary bit
    flags = struct.unpack("<Q", block[OFF_INCOMPAT_FLAGS:OFF_INCOMPAT_FLAGS + 8])[0]
    flags &= ~UGREEN_PROPRIETARY_BIT
    block[OFF_INCOMPAT_FLAGS:OFF_INCOMPAT_FLAGS + 8] = struct.pack("<Q", flags)

    # 2. Recalculate CRC32C over bytes 0x20 .. 0xFFF
    # Zero out the entire checksum area first
    block[OFF_CSUM:OFF_CSUM + BTRFS_CSUM_SIZE] = b"\x00" * BTRFS_CSUM_SIZE
    new_crc = crc32c(block[OFF_CSUM_DATA_START:BTRFS_SUPER_INFO_SIZE])

    # Write the 4-byte CRC32C digest back to offset 0x00 (little-endian)
    block[OFF_CSUM:OFF_CSUM + 4] = struct.pack("<I", new_crc)


# ── Backup helpers ───────────────────────────────────────────────────────────

def _check_backup_dir_safe(backup_dir: str, device_path: str) -> bool:
    """
    Return True if backup_dir is NOT on the same underlying block device
    as device_path. Uses findmnt when available.
    """
    backup_dir = os.path.realpath(backup_dir)
    device_path = os.path.realpath(device_path)

    # If findmnt is available, ask what block device backs backup_dir
    try:
        result = subprocess.run(
            ["findmnt", "-n", "-o", "SOURCE", "--target", backup_dir],
            capture_output=True, text=True, check=True,
        )
        backing = result.stdout.strip().split("\n")[0]
        if backing:
            backing_real = os.path.realpath(backing) if os.path.exists(backing) else backing
            device_real = os.path.realpath(device_path)
            if backing_real == device_real:
                return False
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass

    return True


def classify_target(device_path: str) -> str:
    """
    Classify a write target so the patcher knows whether it's safe to
    operate on. Returns one of:

      "file"        — a regular file (e.g. test fixture / .img). Safe to
                      write to without further ceremony.
      "loop"        — a /dev/loop* block device. Backed by a file; safe.
      "snapshot"    — a dm-mapper device whose dmsetup table type is
                      "snapshot" or "snapshot-origin". Writes here go to
                      the COW overlay, not the underlying real disk.
      "real"        — anything else: a physical block device, a partition,
                      a non-snapshot dm-linear (e.g. UGOS's /dev/mapper/ug_*
                      pool volumes), an md device. Writing here modifies
                      the user's real data.

    The patcher's safety posture (see BUG-016 audit and the lockdown
    decision recorded in PRD_BUGS_BTRFS_PATCH.md) refuses to write to
    "real" targets unless a maintainer-approval flag is passed.
    """
    import subprocess
    try:
        real = os.path.realpath(device_path)
    except OSError:
        return "real"  # fail-closed: treat unknown as real

    if os.path.isfile(real):
        return "file"
    if not os.path.exists(real):
        return "real"

    # /dev/loop* is unambiguous.
    name = os.path.basename(real)
    if name.startswith("loop"):
        return "loop"

    # dm-* devices: ask dmsetup what their table type is.
    if name.startswith("dm-") or real.startswith("/dev/mapper/"):
        try:
            out = subprocess.run(
                ["dmsetup", "table", real],
                capture_output=True, text=True, timeout=5,
            )
            if out.returncode == 0:
                # Table line: "<start> <length> <target-type> ..."
                parts = out.stdout.strip().split()
                if len(parts) >= 3:
                    ttype = parts[2]
                    if ttype in ("snapshot", "snapshot-origin"):
                        return "snapshot"
        except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
            pass
        # dm-linear, dm-crypt, dm-raid, etc. → not a snapshot → real.
        return "real"

    # Anything else (sd*, nvme*, md*, hd*, partitions) is a real device.
    return "real"


def is_device_mounted_rw(device_path: str) -> bool:
    """
    Return True if `device_path` (or any partition mapped from it) appears in
    /proc/self/mountinfo with rw mount options. Returns False if we can't
    determine state (caller should treat as safe-fail).

    Used to refuse write-path operations against a live filesystem without
    explicit operator acknowledgement.
    """
    try:
        real = os.path.realpath(device_path)
    except OSError:
        return False
    try:
        with open("/proc/self/mountinfo", "r") as fh:
            for line in fh:
                parts = line.split()
                # mountinfo: id parent_id maj:min root mountpoint options ...
                if len(parts) < 6:
                    continue
                source = parts[len(parts) - 2] if "-" in parts else ""
                # mountinfo field layout: source is after the "-" separator.
                # Simpler: parse via the standard '-' delimiter.
                try:
                    dash = parts.index("-")
                    source = parts[dash + 2]
                except (ValueError, IndexError):
                    continue
                try:
                    source_real = os.path.realpath(source)
                except OSError:
                    continue
                if source_real == real:
                    opts = parts[5]
                    if "rw" in opts.split(","):
                        return True
    except OSError:
        return False
    return False


def write_backups(valid_blocks, device_path: str, backup_dir: str) -> list:
    """
    Write each valid superblock to its own raw backup file under backup_dir.
    Returns a list of (offset, filepath) tuples.
    """
    backup_dir = os.path.realpath(backup_dir)
    os.makedirs(backup_dir, exist_ok=True)

    # Nanosecond timestamp + PID makes sub-second re-runs unique, and binds
    # the backup to the process that produced it. Combined with device basename
    # this is enough disambiguation in practice.
    ns_ts = time.time_ns()
    pid = os.getpid()
    safe_name = Path(device_path).name.replace("/", "_")
    backups = []

    for offset, block in valid_blocks:
        backup_name = (
            f"btrfs_sb_backup_{safe_name}_offset_{offset:08X}_{ns_ts}_pid{pid}.bin"
        )
        backup_path = Path(backup_dir) / backup_name
        with open(backup_path, "wb") as f:
            f.write(block)
        # Verify what we wrote
        written_size = backup_path.stat().st_size
        if written_size != BTRFS_SUPER_INFO_SIZE:
            raise RuntimeError(
                f"Backup verification failed: {backup_path} has size {written_size}, "
                f"expected {BTRFS_SUPER_INFO_SIZE}"
            )
        backups.append((offset, str(backup_path)))

    return backups


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Clear UGREEN OS proprietary BTRFS incompatible feature flag."
    )
    parser.add_argument("device", help="Target block device (e.g. /dev/sda1)")
    parser.add_argument(
        "--yes",
        action="store_true",
        help="Skip interactive confirmation (DANGEROUS — only for COW snapshots)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Read-only check: verify BTRFS magic, CRC, bytenr, csum_type, and UGREEN flag.",
    )
    parser.add_argument(
        "--dump",
        action="store_true",
        help="Read-only dump: save all valid superblocks to timestamped .bin files.",
    )
    parser.add_argument(
        "--backup-dir",
        dest="backup_dir",
        default=".",
        help="Directory for superblock backups (default: current directory). "
             "Should be on a different physical disk than the target device.",
    )
    parser.add_argument(
        "--allow-mounted",
        action="store_true",
        help="Allow writing to a mounted-rw device. DANGEROUS — typically "
             "you want to unmount first, or operate on a dmsetup COW snapshot. "
             "Has no effect for --check / --dump (those are read-only).",
    )
    # Maintainer-approval flag for real-disk writes. NOT shown in --help on
    # purpose: this is a deliberately verbose, hard-to-type incantation
    # whose existence the volunteer is not meant to discover by reading
    # `--help`. See PRD_BUGS_BTRFS_PATCH.md (real-disk-write lockdown).
    # Renaming or hiding this further requires updating both
    # PRD_BUGS_BTRFS_PATCH.md and the test that documents the lockdown.
    parser.add_argument(
        "--really-write-to-real-block-device-i-have-maintainer-approval",
        dest="commit_real_disk",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    args = parser.parse_args()

    device = args.device
    if not os.path.exists(device):
        print(f"Error: device '{device}' does not exist.", file=sys.stderr)
        sys.exit(1)

    read_only_mode = args.check or args.dump

    # For read-only modes we only need read access
    if read_only_mode:
        if not os.access(device, os.R_OK):
            print(f"Error: cannot read '{device}'. Try sudo?", file=sys.stderr)
            sys.exit(1)
    else:
        if not os.access(device, os.R_OK | os.W_OK):
            print(f"Error: cannot read/write '{device}'. Try sudo?", file=sys.stderr)
            sys.exit(1)

    # ── Read valid superblocks ──
    valid_blocks = find_valid_superblocks(device)
    if not valid_blocks:
        print(
            f"Error: no valid BTRFS superblocks found on '{device}'. "
            "Is this really a BTRFS filesystem?",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"Found {len(valid_blocks)} valid BTRFS superblock mirror(s):")
    for offset, _ in valid_blocks:
        print(f"  - 0x{offset:08X} ({offset} bytes, {offset / 1024:.1f} KiB)")

    # ── Validate each mirror and classify ──
    # Per-mirror classification: error | needs_patch | already_clean
    mirror_states = {}  # offset -> state
    has_error = False
    needs_patch_count = 0
    already_clean_count = 0

    for offset, block in valid_blocks:
        errors = []

        # 1. CRC validation (BUG-010)
        crc_ok, stored_crc, computed_crc = verify_superblock_crc(block)
        if not crc_ok:
            errors.append(
                f"CRC mismatch at mirror 0x{offset:08X} "
                f"(stored=0x{stored_crc:08X}, computed=0x{computed_crc:08X})"
            )

        # 2. Bytenr must match physical offset
        if not verify_bytenr_matches(offset, block):
            bytenr = struct.unpack("<Q", block[OFF_BYTENR:OFF_BYTENR + 8])[0]
            errors.append(
                f"bytenr mismatch at mirror 0x{offset:08X} "
                f"(expected=0x{offset:08X}, found=0x{bytenr:08X})"
            )

        # 3. csum_type must be CRC32C (0)
        if not verify_csum_type_crc32c(block):
            csum_type = struct.unpack("<H", block[OFF_CSUM_TYPE:OFF_CSUM_TYPE + 2])[0]
            errors.append(
                f"unsupported csum_type={csum_type} at mirror 0x{offset:08X} "
                f"(only CRC32C/0 is supported)"
            )

        # 4. UGREEN flag state
        ugreen_set = verify_ugreen_flag_set(block)

        if errors:
            has_error = True
            mirror_states[offset] = "error"
            for e in errors:
                print(f"  ERROR: {e}", file=sys.stderr)
        elif ugreen_set:
            mirror_states[offset] = "needs_patch"
            needs_patch_count += 1
        else:
            mirror_states[offset] = "already_clean"
            already_clean_count += 1
            print(
                f"  Info: mirror 0x{offset:08X} is already clean "
                "(UGREEN flag not set)."
            )

    # ── Handle error state ──
    if has_error:
        print(
            "\nValidation failed due to errors above. Aborting to avoid data corruption.",
            file=sys.stderr,
        )
        sys.exit(1)

    # ── Handle all-clean state ──
    if needs_patch_count == 0:
        if already_clean_count > 0:
            print("\nAll mirrors are already clean. Nothing to patch.")
            sys.exit(0)
        else:
            # Should not reach here (no valid blocks caught earlier)
            print("\nNo actionable mirrors found.", file=sys.stderr)
            sys.exit(1)

    # ── Read-only modes ──
    if args.dump:
        backups = write_backups(valid_blocks, device, args.backup_dir)
        print("\nDump complete. Superblock backups saved (read-only, originals untouched):")
        for offset, path in backups:
            print(f"  0x{offset:08X} -> {path}")
        sys.exit(0)

    if args.check:
        if already_clean_count > 0:
            print(
                f"\nCheck: mixed state detected ({needs_patch_count} need patching, "
                f"{already_clean_count} already clean). A resume is possible.",
                file=sys.stderr,
            )
            sys.exit(2)  # distinct exit code for mixed/resume state
        else:
            print("\nCheck passed: all mirrors need patching and are structurally valid.")
            print("  - CRC32C checksums verified")
            print("  - bytenr matches physical offset")
            print("  - csum_type = CRC32C (0)")
            print("  - UGREEN proprietary flag (0x4000000000000000) is present")
            sys.exit(0)

    # ── Patch mode: check backup-dir safety (BUG-012) ──
    if not _check_backup_dir_safe(args.backup_dir, device):
        print(
            f"\nError: backup directory '{args.backup_dir}' appears to be on the same "
            f"physical device as '{device}'.",
            file=sys.stderr,
        )
        print(
            "Writing backups to the device being mutated destroys the rollback path. "
            "Use --backup-dir pointing to a different disk.",
            file=sys.stderr,
        )
        sys.exit(1)

    # ── Backup before writing ──
    print("\nCreating backups before patching...")
    backups = write_backups(valid_blocks, device, args.backup_dir)
    for offset, path in backups:
        print(f"  0x{offset:08X} -> {path}")

    # ── Interactive confirmation ──
    # ── Real-disk-write lockdown ─────────────────────────────────────────
    # The patcher's write path is currently NOT cleared to touch real
    # block devices. Even recover_btrfs.sh, which sets up a COW snapshot
    # for dry-run testing, no longer commits to the real disk at the end
    # of its flow. Until BTRFS recovery is volunteer-validated end-to-end
    # against the new collector bundles, writes only land on:
    #   - regular files (.img test fixtures),
    #   - /dev/loop* devices,
    #   - dm-snapshot devices (the COW path).
    # Anything else is a "real" target and is refused. See
    # PRD_BUGS_BTRFS_PATCH.md → real-disk-write lockdown.
    target_kind = classify_target(device)
    if target_kind == "real" and not args.commit_real_disk:
        print(
            f"\nError: '{device}' looks like a real block device "
            f"(classified: {target_kind}).\n"
            "\n"
            "Direct writes to real disks are currently disabled in this\n"
            "release. Even recover_btrfs.sh no longer commits to the real\n"
            "disk — it runs the COW-snapshot dry-run and stops there. This\n"
            "is deliberate: the patcher has not yet been validated\n"
            "end-to-end against a new volunteer bundle, and we don't want\n"
            "anyone's NAS to be the first real-disk write site.\n"
            "\n"
            "What you can still do safely:\n"
            "  - python3 patch_btrfs_ugos.py --check  <device>   (read-only)\n"
            "  - python3 patch_btrfs_ugos.py --dump   <device>   (read-only backup)\n"
            "  - sudo recover_btrfs.sh <device>                  (COW dry-run only)\n"
            "  - patch a /dev/loop* device or an .img file       (sandbox)\n"
            "\n"
            "The lockdown will be lifted by an explicit maintainer release once\n"
            "the volunteer flow is proven. See PRD_BUGS_BTRFS_PATCH.md.\n",
            file=sys.stderr,
        )
        sys.exit(3)
    if target_kind == "real" and args.commit_real_disk:
        # The user invoked the deliberately-verbose maintainer-approval flag.
        # Print a very loud warning and proceed; the read-after-write
        # verification still applies.
        print(
            f"\n!! REAL-DISK WRITE UNLOCKED for '{device}' via maintainer flag.\n"
            "!! This is a manual override. Make sure you have backups.\n",
            file=sys.stderr,
        )

    # Refuse to write to a mounted-rw device unless explicitly allowed.
    # The volunteer collector applies the same gate; we mirror it here so
    # that recover_btrfs.sh isn't the only thing standing between a typo
    # and a live filesystem.
    if is_device_mounted_rw(device):
        if not args.allow_mounted:
            print(
                f"\nError: '{device}' is currently mounted read-write.\n"
                "Writing to a mounted btrfs filesystem under the kernel's feet "
                "can corrupt it.\n\n"
                "Either:\n"
                "  1. Unmount the filesystem first, OR\n"
                "  2. Operate on a dmsetup COW snapshot (see recover_btrfs.sh), OR\n"
                "  3. Re-run with --allow-mounted if you really know what you're doing.\n",
                file=sys.stderr,
            )
            sys.exit(2)
        else:
            print(
                f"\nWARNING: '{device}' is mounted read-write and --allow-mounted "
                "was passed. Proceeding under operator override.",
                file=sys.stderr,
            )

    if not args.yes:
        print(
            "\nWARNING: This will PERMANENTLY modify the BTRFS superblocks on "
            f"{device}."
        )
        print("Make sure you have validated this on a COW snapshot first.")
        if already_clean_count > 0:
            print(
                f"Note: {already_clean_count} mirror(s) are already clean and will be skipped."
            )
        confirm = input("Proceed? [y/N]: ").strip().lower()
        if confirm != "y":
            print("Aborted.")
            sys.exit(0)

    # ── Patch and write back (BUG-013: skip already_clean) ──
    print("\nPatching superblocks...")
    with open(device, "r+b") as f:
        for offset, block in valid_blocks:
            if mirror_states[offset] == "already_clean":
                print(f"  Skipping already-clean mirror 0x{offset:08X}")
                continue

            patch_superblock(block)

            # Post-patch sanity checks
            magic = bytes(block[OFF_MAGIC:OFF_MAGIC + 8])
            if magic != BTRFS_SUPER_MAGIC:
                print(
                    f"  FATAL: magic corrupted at mirror 0x{offset:08X}! "
                    "Aborting remaining writes.",
                    file=sys.stderr,
                )
                sys.exit(1)

            if not verify_bytenr_matches(offset, block):
                print(
                    f"  FATAL: bytenr corrupted at mirror 0x{offset:08X}! "
                    "Aborting remaining writes.",
                    file=sys.stderr,
                )
                sys.exit(1)

            if not verify_csum_type_crc32c(block):
                print(
                    f"  FATAL: csum_type corrupted at mirror 0x{offset:08X}! "
                    "Aborting remaining writes.",
                    file=sys.stderr,
                )
                sys.exit(1)

            # Commit to disk
            f.seek(offset)
            f.write(block)
            f.flush()
            os.fsync(f.fileno())

            # Read-after-write verification. The CRC bug that motivated this
            # entire audit cycle (issue #1) was undetectable for an entire
            # release cycle precisely because nothing re-read the disk after
            # writing. If the patcher's CRC routine ever regresses again, the
            # in-memory `block` will look fine but what landed on disk will
            # be wrong. Catch that here, while we still have the original
            # backups within arm's reach.
            f.seek(offset)
            written = bytearray(f.read(BTRFS_SUPER_INFO_SIZE))
            if len(written) != BTRFS_SUPER_INFO_SIZE:
                print(
                    f"  FATAL: short read after write at mirror 0x{offset:08X} "
                    f"(got {len(written)} bytes). DO NOT proceed; restore from backup.",
                    file=sys.stderr,
                )
                sys.exit(1)
            ok, stored, computed = verify_superblock_crc(written)
            if not ok:
                print(
                    f"  FATAL: post-write CRC mismatch at mirror 0x{offset:08X} "
                    f"(stored=0x{stored:08X}, computed=0x{computed:08X}).\n"
                    "  This means either the write didn't land correctly or our "
                    "CRC routine regressed. Restore IMMEDIATELY from the backup "
                    "file listed above; do not let any further writes happen.",
                    file=sys.stderr,
                )
                sys.exit(1)
            if verify_ugreen_flag_set(written):
                print(
                    f"  FATAL: post-write read still shows UGREEN flag set at "
                    f"mirror 0x{offset:08X}. Restore from backup.",
                    file=sys.stderr,
                )
                sys.exit(1)
            print(f"  Patched and verified (read-back) mirror 0x{offset:08X}")

    print("\nDone! The UGREEN proprietary flag has been cleared.")
    print(
        "You should now be able to mount this volume with a standard Linux kernel."
    )
    print(f"\nRollback: restore from the backup files above if needed.")
    print("Example (for a single mirror):")
    for offset, path in backups:
        seek_4k = offset // 4096
        print(f"  dd if={path} of={device} bs=4K count=1 seek={seek_4k}")
        break  # Only show one example


if __name__ == "__main__":
    main()
