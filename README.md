# Escaping UGREEN OS: Native UGREEN NAS Data Recovery for Standard Linux

A practical guide to recovering data from UGREEN NASync devices (DXP4800 Plus, DXP6800 Pro, DXP8800, etc.) when you've replaced UGREEN OS with a standard Linux distro (TrueNAS, Unraid, Debian, Ubuntu) — and discovered your existing UGREEN OS-formatted ext4 volumes refuse to mount.

## The Problem

UGREEN's UGREEN OS is Debian 12 + a custom Linux 6.12.30+ kernel that injects **undocumented incompat feature flags** into both `ext4` and `btrfs` volumes. Any vanilla Linux kernel will refuse to mount volumes formatted by UGREEN OS:

**ext4:**
```
EXT4-fs (dm-X): Couldn't mount because of unsupported optional features (20000000)
```

**btrfs:**
```
BTRFS: unsupported feature bits found: 0x4000000000000000
```

This is essentially vendor lock-in. 

### Why Hex-Editing the Superblock Fails
**ext4:** If you try to clear the `0x20000000` bit manually with a hex editor, ext4's `metadata_csum` safety feature will catch it. The checksum becomes invalid, and `e2fsck` will fail:
```
ext2fs_open2: Superblock checksum does not match superblock
```

**btrfs:** Similarly, BTRFS superblocks carry a CRC32C hash covering the entire 4 KiB block. Any raw edit to `incompat_flags` invalidates the checksum, and the kernel rejects the superblock entirely.

## The Solution: Native Patching

Instead of the tedious process of booting a virtual machine (QEMU) with the proprietary kernel, we have created native Linux utilities for both filesystems. These tools are designed defensively — read-only validation by default, COW-snapshot dry-runs before any disk write, per-mirror backups, and read-after-write verification — but they are not infallible. See `PRD_BUGS_BTRFS_PATCH.md` for the audit trail, including BUG-016, a critical CRC-polynomial defect that was found and fixed via static analysis of the UGOS kernel module. Always run `--check` (read-only), validate on a COW snapshot, and keep your backups before committing any permanent patch.

### ext4
We patch the standard Linux `e2fsprogs` toolkit to recognize the `0x20000000` flag (named `ugreen_proprietary`). The patched `tune2fs` strips the flag and correctly recalculates all ext4 CRC32c checksums, permanently converting your drive back into standard, mainline-compatible `ext4`.

### btrfs
We provide a standalone Python script (`patch_btrfs_ugos.py`) that directly manipulates the BTRFS superblocks. It clears the proprietary bit (`0x4000000000000000`), recalculates the CRC32C checksum, and writes the corrected superblock back to all mirror locations. Zero external dependencies — works with any Python 3 installation.

> **Status:** the BTRFS write path is currently **locked down** while the end-to-end recovery flow is being volunteer-validated. `patch_btrfs_ugos.py --check` and `--dump` (both read-only) work normally; `recover_btrfs.sh` runs the COW-snapshot dry-run and stops there; direct real-disk writes are refused (exit 3). See `PRD_BUGS_BTRFS_PATCH.md` §3 for the policy and the four conditions required to lift it. The ext4 path is unaffected.

### COW-Snapshot Validation (Dry-run before commit)
We do not touch your real data immediately. Our `recover.sh` and `recover_btrfs.sh` scripts utilize Linux Device Mapper (dm-snapshot) to create a RAM-backed Copy-on-Write (COW) overlay.
1. Reads come from your real disk.
2. Writes (the metadata patch) go to a temporary file in `/var/tmp`.
3. You get to mount the test volume and verify your files mathematically (`sha1sum`) before committing anything to the real disk.

This dry-run path is the **second** line of defence; the first is `--check`, which is read-only. Run `--check` first and only proceed if it reports the SBs as structurally valid. (Historical note: a wrong-polynomial CRC bug, since fixed and pinned in `tests/test_crc32c.py`, caused `--check` to false-positive against healthy filesystems for one release cycle. See BUG-016 in `PRD_BUGS_BTRFS_PATCH.md`.)

## Usage

**Prerequisites:** 
- Your NAS booted into standard Linux (Debian, Ubuntu, etc.)
- Basic build tools (`apt install build-essential git autoconf libtool pkg-config libfuse-dev libblkid-dev uuid-dev`)

### Step 1: Build the Patched Utilities
```bash
git clone <this-repo> ugreen_os-recovery
cd ugreen_os-recovery
sudo ./scripts/build_patched_e2fsprogs.sh
```

### Step 2: Assemble Your Disks
Make sure your RAID/LVM disks are assembled (`mdadm --assemble --scan`, `vgchange -ay`). Locate your target volume (e.g., `/dev/mapper/ug_A5AEB6_1767706191_pool1-volume1`).

### Step 3: Run the Safe Recovery Wizard
```bash
sudo ./scripts/recover.sh /dev/mapper/<your-volume>
```

The interactive script will:
1. Verify the `ugreen_proprietary` flag exists.
2. Provision a temporary COW snapshot.
3. Patch the snapshot's superblock and run `e2fsck`.
4. Mount the test snapshot for you to inspect.
5. Safely clean up the snapshot.
6. Ask for final confirmation before permanently fixing the real disk.

### Step 4: BTRFS Recovery (if your pool is btrfs)
If UGREEN OS formatted your pool as `btrfs`, use the Python-based recovery tool instead:

```bash
sudo ./scripts/recover_btrfs.sh /dev/mapper/<your-btrfs-volume>
```

The interactive script will:
1. Verify the proprietary `0x4000000000000000` flag exists in all BTRFS superblock mirrors.
2. Provision a temporary COW snapshot.
3. Patch the snapshot's superblocks and recalculate CRC32C checksums.
4. Mount the test snapshot for you to inspect.
5. Safely clean up the snapshot.
6. Ask for final confirmation before permanently fixing the real disk.

**Volunteer Testing:** If you are helping test BTRFS support on your UGREEN NAS, please follow the detailed guide in [`BTRFS_TESTING.md`](BTRFS_TESTING.md). It contains step-by-step read-only and COW-snapshot testing instructions, plus a comprehensive log-gathering checklist.

## Notes & Gotchas
* **ugacl_vfs Warning:** Once mounted on standard Linux, you may see `ugacl_vfs request_module failed` in `dmesg`. This is just Linux ignoring UGREEN's proprietary Access Control List (ACL) tags and safely falling back to standard POSIX permissions. It does not affect data integrity.
* **BTRFS Rollback:** The Python tool automatically backs up all valid superblock mirrors to a timestamped `.bin` file before patching. If anything goes wrong, you can restore with `dd` (see `PRD_UGREEN_OS_BTRFS_PATCH.md`).
* **Firmware Images:** UGREEN firmware `.img` files are actually POSIX tar archives, not bootable ISOs. Never `dd` them to your NVMe.
* **Post-Patch Verification:** You can use `./scripts/verify_hashes.sh` during the test phase to randomly hash 100 large files and compare them against your backups to prove mathematically that the filesystem layout is completely intact.
