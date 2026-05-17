#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /dev/mapper/<your-ugreen_os-btrfs-volume>"
    exit 1
fi

TARGET_DEV="$1"
if [ ! -b "$TARGET_DEV" ]; then
    echo "Error: Block device $TARGET_DEV not found."
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCHER="$REPO_ROOT/scripts/patch_btrfs_ugos.py"

if [ ! -x "$PATCHER" ]; then
    echo "Error: patch_btrfs_ugos.py not found or not executable."
    echo "Expected at: $PATCHER"
    exit 1
fi

# ── Pre-flight read-only validation ──
echo "=== Pre-flight: validating BTRFS superblocks (read-only) ==="
CHECK_RC=0
python3 "$PATCHER" --check "$TARGET_DEV" || CHECK_RC=$?
case "$CHECK_RC" in
    0)
        echo "Pre-flight passed: all mirrors are structurally valid."
        ;;
    2)
        echo "Pre-flight passed: mixed state detected (some mirrors need patching, some already clean)."
        echo "The COW test will patch only the mirrors that still need it."
        ;;
    1)
        echo ""
        echo "Error: $TARGET_DEV failed validation."
        echo "Either this is not a UGREEN OS BTRFS volume, it has already been patched,"
        echo "or a critical safety check (CRC / bytenr / csum_type) failed."
        exit 1
        ;;
    *)
        echo ""
        echo "Error: unexpected exit code $CHECK_RC from --check."
        exit 1
        ;;
esac

# ── BUG-011 fix: only apply tmpfs heuristic when COW_DIR is not user-provided ──
if [ -z "${COW_DIR:-}" ]; then
    if df --type=tmpfs /tmp >/dev/null 2>&1; then
        COW_DIR="/var/tmp"
        echo "Note: /tmp is tmpfs, using $COW_DIR for COW file"
    else
        COW_DIR="/tmp"
    fi
fi
echo "COW directory: $COW_DIR"

# ── BUG-015 fix: configurable COW size, default 4G ──
COW_SIZE="${COW_SIZE:-4G}"
echo "COW size: $COW_SIZE"

COW_IMG="$COW_DIR/ugreen_os_btrfs_cow_$$.img"
SNAP_NAME="ugos_btrfs_safe_test_$$"
MOUNT_POINT="/mnt/recovery_btrfs_test_$$"
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

echo ""
echo "=== [1/5] Setting up COW Snapshot ==="
echo "Target: $TARGET_DEV"
truncate -s "$COW_SIZE" "$COW_IMG"
LOOP_DEV=$(losetup --find --show "$COW_IMG")
SIZE=$(blockdev --getsz "$TARGET_DEV")

# BUG-008 fix: quote all variables passed to dmsetup
# Create snapshot: 0 <size> snapshot <origin> <cow> <persistent(P)/non-persistent(N)> <chunksize>
# chunk size 8 = 8 sectors = 4 KiB (matches typical BTRFS node size)
printf '%s\n' "0 $SIZE snapshot $TARGET_DEV $LOOP_DEV N 8" | dmsetup create "$SNAP_NAME"
SNAP_DEV="/dev/mapper/$SNAP_NAME"
echo "Created snapshot device: $SNAP_DEV"

echo "=== [2/5] Patching BTRFS superblocks (Safe Mode — COW snapshot only) ==="
python3 "$PATCHER" --yes "$SNAP_DEV"

echo "=== [3/5] Verifying filesystem integrity ==="
# Try a read-only mount first to validate the kernel accepts the patched superblock
mkdir -p "$MOUNT_POINT"
if ! mount -o ro "$SNAP_DEV" "$MOUNT_POINT" 2>/dev/null; then
    echo "ERROR: mount failed on the patched snapshot."
    echo "The kernel may still be rejecting the filesystem."
    echo "Do NOT proceed to permanent patching."
    exit 1
fi
umount "$MOUNT_POINT"

# ── BUG-015 fix: mount rw with noatime,nodiratime to minimize COW churn ──
echo "=== [4/5] Mounting read-write for verification (noatime,nodiratime) ==="
mount -o noatime,nodiratime "$SNAP_DEV" "$MOUNT_POINT"

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
echo "==========================================================="
echo " Validation Complete — and we stop here, on purpose."
echo "==========================================================="
echo ""
echo " The COW snapshot test above proves the patcher's logic"
echo " produces a kernel-mountable filesystem. Your real disk"
echo " ($TARGET_DEV) was never touched."
echo ""
echo " Permanent commit to the real disk is currently DISABLED"
echo " in this release. Even with full operator confirmation,"
echo " this wrapper will not write to $TARGET_DEV."
echo ""
echo " Why: the patcher's CRC routine was wrong for an entire"
echo " release cycle (BUG-016). It's been fixed and pinned by"
echo " tests, but the end-to-end flow has not yet been"
echo " volunteer-validated against the new collector bundles."
echo " Until it is, your NAS is not going to be the first"
echo " real-disk write site."
echo ""
echo " If you need to commit to the real disk anyway, that's a"
echo " conversation to have with the maintainers on the GitHub"
echo " issue tracker — not something to unlock locally."
echo ""
echo " See: PRD_BUGS_BTRFS_PATCH.md → real-disk-write lockdown"
echo "==========================================================="
