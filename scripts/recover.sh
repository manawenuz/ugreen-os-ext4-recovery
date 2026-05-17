#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /dev/mapper/<your-ugreen_os-volume>"
    exit 1
fi

TARGET_DEV="$1"
if [ ! -b "$TARGET_DEV" ]; then
    echo "Error: Block device $TARGET_DEV not found."
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TUNE2FS="$REPO_ROOT/build/e2fsprogs/misc/tune2fs"
E2FSCK="$REPO_ROOT/build/e2fsprogs/e2fsck/e2fsck"

if [ ! -x "$TUNE2FS" ] || [ ! -x "$E2FSCK" ]; then
    echo "Error: Patched binaries not found."
    echo "Please run ./scripts/build_patched_e2fsprogs.sh first."
    exit 1
fi

if ! "$TUNE2FS" -l "$TARGET_DEV" 2>/dev/null | grep -q 'ugreen_proprietary'; then
    echo "Error: $TARGET_DEV does not have the ugreen_proprietary flag set."
    echo "Either this is not a UGREEN OS volume, or it has already been patched."
    exit 1
fi

# BUG-EXT4-001: COW directory selection logic.
# Intent: keep the COW image off tmpfs so it can grow to 1 GiB without
# OOMing memory-constrained systems. The previous code inverted this —
# when /tmp was tmpfs it OVERRODE the safe /var/tmp default with /tmp.
# Same anti-pattern as BTRFS BUG-011.
if [ -z "${COW_DIR:-}" ]; then
    if df --type=tmpfs /tmp >/dev/null 2>&1; then
        COW_DIR="/var/tmp"
        echo "Note: /tmp is tmpfs, using $COW_DIR for COW file"
    else
        COW_DIR="/tmp"
    fi
fi
echo "COW directory: $COW_DIR"
COW_IMG="$COW_DIR/ugreen_os_cow_writes_$$.img"
SNAP_NAME="ugreen_os_safe_test_$$"
MOUNT_POINT="/mnt/recovery_test_$$"
LOOP_DEV=""

cleanup() {
    echo "=== Tearing down snapshot environment ==="
    set +e
    if mountpoint -q "$MOUNT_POINT"; then
        umount "$MOUNT_POINT"
    fi
    rmdir "$MOUNT_POINT" 2>/dev/null
    if dmsetup status "$SNAP_NAME" >/dev/null 2>&1; then
        dmsetup remove "$SNAP_NAME"
    fi
    if [ -n "$LOOP_DEV" ]; then
        losetup -d "$LOOP_DEV"
    fi
    rm -f "$COW_IMG"
    set -e
    echo "Teardown complete. Original disk ($TARGET_DEV) was untouched."
}

trap cleanup EXIT INT TERM HUP

echo "=== [1/5] Setting up COW Snapshot ==="
echo "Target: $TARGET_DEV"
truncate -s 1G "$COW_IMG"
LOOP_DEV=$(losetup --find --show "$COW_IMG")
SIZE=$(blockdev --getsz "$TARGET_DEV")

# Create snapshot: 0 <size> snapshot <origin> <cow> <persistent(P)/non-persistent(N)> <chunksize>
echo "0 $SIZE snapshot $TARGET_DEV $LOOP_DEV N 8" | dmsetup create "$SNAP_NAME"
SNAP_DEV="/dev/mapper/$SNAP_NAME"
echo "Created snapshot device: $SNAP_DEV"

echo "=== [2/5] Stripping ugreen_proprietary flag (Safe Mode) ==="
"$TUNE2FS" -O ^ugreen_proprietary "$SNAP_DEV"

echo "=== [3/5] Verifying filesystem integrity ==="
# -f forces check, -n opens read-only/answers no.
# Capture the exit code (don't swallow it). e2fsck exit codes:
#   0  = clean
#   1  = errors corrected (cannot happen in -n mode)
#   2  = errors corrected, reboot needed (cannot happen in -n mode)
#   4  = errors LEFT UNCORRECTED  — the real-disk gate must block this
#   8  = operational error
#   16 = usage error
#   32 = cancelled by user
# Anything &ge; 4 means the COW-snapshot filesystem is unhealthy after the
# strip; the volunteer must NOT proceed to a real-disk write.
set +e
"$E2FSCK" -fn "$SNAP_DEV"
COW_FSCK_RC=$?
set -e
case "$COW_FSCK_RC" in
    0) echo "  e2fsck on COW snapshot: clean (rc=0)" ;;
    *) echo "  e2fsck on COW snapshot exited rc=$COW_FSCK_RC — gate will block real-disk patch" ;;
esac

echo "=== [4/5] Mounting for verification ==="
mkdir -p "$MOUNT_POINT"
mount "$SNAP_DEV" "$MOUNT_POINT"

echo ""
echo "==========================================================="
echo " SUCCESS! The patched volume is mounted at:"
echo " $MOUNT_POINT"
echo "==========================================================="
echo "Open another terminal to inspect your files."
echo "Reads are coming from the real disk, writes went to RAM/tmp."
echo "No data has been modified on $TARGET_DEV."
echo ""
read -p "Press [Enter] when you are done inspecting to tear down the test environment..."

# Call cleanup explicitly and disable the trap so it doesn't run again on normal exit
trap - EXIT INT TERM HUP
cleanup

echo ""
echo "=== Validation Complete ==="

# EXT4-S2 gate: if e2fsck on the COW snapshot found uncorrectable errors,
# the patcher logic produced an unhealthy filesystem. Refuse the real-disk
# write entirely.
if [ "$COW_FSCK_RC" -ne 0 ]; then
    echo "" >&2
    echo "Refusing to commit to real disk: e2fsck on the COW snapshot returned" >&2
    echo "exit code $COW_FSCK_RC (anything non-zero in -n mode = uncorrectable" >&2
    echo "or operational error). Do NOT proceed. Send the recover.sh output" >&2
    echo "to the maintainers." >&2
    exit 1
fi

read -p "Did the test succeed? Are you ready to permanently patch $TARGET_DEV? (y/N) " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    # Tightened confirmation: require the volunteer to retype the device
    # basename, not just press 'y'. Industry standard for destructive ops.
    target_basename="$(basename "$TARGET_DEV")"
    echo ""
    echo "About to PERMANENTLY MODIFY: $TARGET_DEV"
    echo "Type the device basename exactly to confirm: $target_basename"
    read -rp "> " typed
    if [ "$typed" != "$target_basename" ]; then
        echo "Confirmation did not match '$target_basename' — aborted." >&2
        exit 1
    fi

    # EXT4-S3: widened mount/holder check.
    # findmnt -n catches mountpoint-style use. We also check:
    #   - swap (swapon --show)
    #   - holders (LVM/md/dm stacked above this device)
    if findmnt -n "$TARGET_DEV" >/dev/null 2>&1; then
        echo "Error: $TARGET_DEV is currently mounted. Unmount before patching." >&2
        exit 1
    fi
    if command -v swapon >/dev/null 2>&1; then
        if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$TARGET_DEV"; then
            echo "Error: $TARGET_DEV is in use as swap. Disable swap before patching." >&2
            exit 1
        fi
    fi
    holders_dir="/sys/block/$(basename "$(readlink -f "$TARGET_DEV")")/holders"
    if [ -d "$holders_dir" ] && [ -n "$(ls -A "$holders_dir" 2>/dev/null)" ]; then
        echo "Error: $TARGET_DEV has active holders ($holders_dir):" >&2
        ls -la "$holders_dir" >&2 || true
        echo "Disable the stacked devices (LVM/md/dm) before patching." >&2
        exit 1
    fi

    # EXT4-S5: take a 4 KiB primary-SB backup before any write, into a
    # timestamped + PID-suffixed file in $REPO_ROOT (alongside the patched
    # binaries; assumed to be on a different physical disk than $TARGET_DEV).
    SB_BACKUP="$REPO_ROOT/ext4_sb_backup_$(basename "$TARGET_DEV")_$(date +%s)_pid$$.bin"
    echo "Backing up primary superblock to: $SB_BACKUP"
    if ! dd if="$TARGET_DEV" of="$SB_BACKUP" bs=4096 count=1 skip=0 status=none 2>/dev/null; then
        echo "Error: failed to back up primary superblock. Aborting." >&2
        exit 1
    fi
    chmod 600 "$SB_BACKUP" 2>/dev/null || true
    echo "  ✓ 4 KiB primary superblock backed up ($(stat -c%s "$SB_BACKUP" 2>/dev/null || stat -f%z "$SB_BACKUP") bytes)"
    echo "  Rollback (only if patching corrupts the disk):"
    echo "    dd if='$SB_BACKUP' of='$TARGET_DEV' bs=4096 count=1 seek=0"
    echo ""

    echo "Permanently patching $TARGET_DEV..."
    "$TUNE2FS" -O ^ugreen_proprietary "$TARGET_DEV"

    echo "=== Verifying permanent patch ==="
    if "$E2FSCK" -fn "$TARGET_DEV"; then
        echo "Done! e2fsck reports clean filesystem."
        echo "You can now natively mount $TARGET_DEV."
        echo ""
        echo "The SB backup at $SB_BACKUP can be deleted once you're"
        echo "satisfied the filesystem mounts correctly under a vanilla kernel."
    else
        echo "WARNING: e2fsck reported errors after patching!" >&2
        echo "Do NOT attempt to mount. Investigate before proceeding." >&2
        echo "Rollback the primary superblock with:" >&2
        echo "  dd if='$SB_BACKUP' of='$TARGET_DEV' bs=4096 count=1 seek=0" >&2
        exit 1
    fi
else
    echo "Aborted permanent patch."
fi
