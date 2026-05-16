#!/bin/bash
#
# volunteer_validate.sh — read-only validator for the UGREEN OS BTRFS patcher.
#
# Works on:
#   * UGREEN OS (proprietary kernel — can mount the volume natively, so we can
#     also confirm file-level reads still work)
#   * Vanilla Linux (kernel rejects the volume — we confirm the rejection
#     and that --check identifies the UGREEN flag)
#
# This script ONLY runs the read-only subset of the toolchain:
#   patch_btrfs_ugos.py --check
#   patch_btrfs_ugos.py --dump --backup-dir <safe dir>
#
# It NEVER writes to the target device and NEVER invokes the patcher in
# write mode. The COW-snapshot recovery flow lives in recover_btrfs.sh and
# is intentionally NOT chained here, to keep this validator boring and safe.
#
# Usage:
#   sudo ./scripts/volunteer_validate.sh                  # auto-detect target
#   sudo ./scripts/volunteer_validate.sh /dev/mapper/ug_… # explicit target
#   sudo ./scripts/volunteer_validate.sh --os ugos /dev/mapper/ug_…
#   sudo ./scripts/volunteer_validate.sh --os vanilla /dev/sdb1
#
# Flags:
#   --os {ugos|vanilla|auto}   Force the environment classification. Useful
#                              when auto-detection misses (e.g. UGOS Pro on
#                              a kernel string the regex doesn't recognise).
#                              Default: auto.
#
# Output: a tarball at ./btrfs_volunteer_report_<timestamp>.tar.gz containing
#   * report.txt          — full transcript
#   * env.txt             — host / kernel / tool versions
#   * sb_backups/         — raw 4 KiB superblock dumps
#   * dmesg_btrfs.txt     — kernel BTRFS messages
#

set -uo pipefail

# ── Preamble ─────────────────────────────────────────────────────────────────

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo $0 ...)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCHER="$SCRIPT_DIR/patch_btrfs_ugos.py"

if [ ! -x "$PATCHER" ]; then
    echo "Error: $PATCHER not found or not executable." >&2
    echo "Run: chmod +x $PATCHER" >&2
    exit 1
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
WORKDIR="$(mktemp -d -t btrfs_volunteer_XXXXXX)"
REPORT="$WORKDIR/report.txt"
ENVFILE="$WORKDIR/env.txt"
SB_DIR="$WORKDIR/sb_backups"
DMESG_FILE="$WORKDIR/dmesg_btrfs.txt"
mkdir -p "$SB_DIR"

# Mirror everything to report.txt while still printing live
exec > >(tee -a "$REPORT") 2>&1

cleanup() {
    local rc=$?
    echo ""
    echo "=== Bundling report ==="
    local tarball="$REPO_ROOT/btrfs_volunteer_report_${TIMESTAMP}.tar.gz"
    tar czf "$tarball" -C "$WORKDIR" . 2>/dev/null || true
    if [ -f "$tarball" ]; then
        echo "Report saved to: $tarball"
        echo "Please attach this file to your issue/email."
    fi
    rm -rf "$WORKDIR"
    exit "$rc"
}
trap cleanup EXIT INT TERM HUP

echo "===== UGREEN OS BTRFS — Volunteer Validation ====="
echo "Started:   $(date)"
echo "Workdir:   $WORKDIR"
echo ""

# ── Environment detection ────────────────────────────────────────────────────

echo "===== Environment ====="
{
    echo "Date:       $(date)"
    echo "Host:       $(hostname)"
    echo "Kernel:     $(uname -a)"
    echo "Python:     $(python3 --version 2>&1)"
    echo "btrfs-prog: $(btrfs --version 2>/dev/null || echo 'not installed')"
} | tee "$ENVFILE"

IS_UGOS="no"
UGOS_HINTS=()
# 1. Release / version files
for f in /etc/ugreen-release /etc/ugos-release /etc/ugos_version \
         /etc/ugreen_version /etc/ugnas-release; do
    if [ -f "$f" ]; then
        IS_UGOS="yes"
        UGOS_HINTS+=("$f exists")
    fi
done
# 2. os-release ID/NAME fields
if [ -f /etc/os-release ] && grep -qiE '^(ID|NAME|PRETTY_NAME)=.*(ugreen|ugos)' /etc/os-release; then
    IS_UGOS="yes"
    UGOS_HINTS+=("/etc/os-release mentions ugreen/ugos")
fi
# 3. Kernel release / OS name (exclude hostname/nodename to avoid false
#    positives if a user named their machine "ugos-test" etc.)
if uname -r | grep -qiE 'ugreen|ugos|ugnas'; then
    IS_UGOS="yes"
    UGOS_HINTS+=("kernel release mentions ugreen/ugos")
fi
if uname -v | grep -qiE 'ugreen|ugos|ugnas'; then
    IS_UGOS="yes"
    UGOS_HINTS+=("kernel build string mentions ugreen/ugos")
fi
# 4. Userspace tooling and config dirs
for d in /etc/ugreen /etc/ugos /etc/ugnas /usr/lib/ugreen /usr/lib/ugos \
         /usr/share/ugreen /usr/share/ugos /var/lib/ugreen /var/lib/ugos; do
    if [ -d "$d" ]; then
        IS_UGOS="yes"
        UGOS_HINTS+=("$d directory present")
        break
    fi
done
if command -v ugreen-nas >/dev/null 2>&1 || command -v ugos-cli >/dev/null 2>&1; then
    IS_UGOS="yes"
    UGOS_HINTS+=("UGREEN userspace tooling on PATH")
fi
# 5. Live kernel evidence: dmesg announces UGACL on mount
if dmesg 2>/dev/null | grep -qE 'BTRFS.*UGACL|Set btrfs UGACL|btrfs.*ugacl|ugreen_proprietary'; then
    IS_UGOS="yes"
    UGOS_HINTS+=("dmesg shows UGACL/ugreen_proprietary")
fi
# 6. Device-mapper naming convention used by UGOS
if ls /dev/mapper/ug_* >/dev/null 2>&1; then
    IS_UGOS="yes"
    UGOS_HINTS+=("/dev/mapper/ug_* devices present")
fi

# ── Parse args (--os override + positional <device>) ─────────────────────────
OS_OVERRIDE="auto"
TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --os)
            shift
            case "${1:-}" in
                ugos|UGOS)        OS_OVERRIDE="ugos" ;;
                vanilla|VANILLA)  OS_OVERRIDE="vanilla" ;;
                auto|AUTO|"")     OS_OVERRIDE="auto" ;;
                *) echo "ERROR: --os must be ugos|vanilla|auto (got '$1')" >&2; exit 2 ;;
            esac
            shift
            ;;
        --os=*)
            v="${1#--os=}"
            case "$v" in
                ugos|UGOS)        OS_OVERRIDE="ugos" ;;
                vanilla|VANILLA)  OS_OVERRIDE="vanilla" ;;
                auto|AUTO)        OS_OVERRIDE="auto" ;;
                *) echo "ERROR: --os must be ugos|vanilla|auto (got '$v')" >&2; exit 2 ;;
            esac
            shift
            ;;
        -h|--help)
            sed -n '2,30p' "$0"; exit 0
            ;;
        --) shift; TARGET="${1:-}"; break ;;
        -*) echo "ERROR: unknown flag '$1'" >&2; exit 2 ;;
        *)  TARGET="$1"; shift ;;
    esac
done

DETECTED="$IS_UGOS"
case "$OS_OVERRIDE" in
    ugos)
        IS_UGOS="yes"
        UGOS_HINTS+=("--os ugos override (user-supplied)")
        ;;
    vanilla)
        IS_UGOS="no"
        UGOS_HINTS=("--os vanilla override (user-supplied)")
        ;;
    auto)
        : # keep auto-detection result
        ;;
esac

echo ""
if [ "$IS_UGOS" = "yes" ]; then
    echo "Environment: UGREEN OS (${UGOS_HINTS[*]})"
    echo "Native mount is expected to SUCCEED on this kernel."
else
    echo "Environment: vanilla Linux"
    echo "Native mount of an unpatched UGREEN volume is expected to FAIL."
fi
if [ "$OS_OVERRIDE" != "auto" ]; then
    echo "(auto-detect would have said: $([ "$DETECTED" = "yes" ] && echo UGOS || echo vanilla); overridden by --os $OS_OVERRIDE)"
fi
echo ""

list_candidates() {
    echo "Scanning for BTRFS volumes..."
    # /dev/mapper/ug_* is the typical UGREEN naming
    local ug_devs=()
    while IFS= read -r d; do
        [ -b "$d" ] && ug_devs+=("$d")
    done < <(ls /dev/mapper/ug_* 2>/dev/null)

    # All BTRFS-labelled devices per blkid
    local blkid_devs=()
    while IFS= read -r d; do
        [ -n "$d" ] && blkid_devs+=("$d")
    done < <(blkid -t TYPE=btrfs -o device 2>/dev/null)

    # Union, preserving order
    declare -A seen
    local out=()
    for d in "${ug_devs[@]}" "${blkid_devs[@]}"; do
        if [ -z "${seen[$d]:-}" ]; then
            seen[$d]=1
            out+=("$d")
        fi
    done
    printf '%s\n' "${out[@]}"
}

if [ -z "$TARGET" ]; then
    echo "===== Candidate devices ====="
    mapfile -t CANDIDATES < <(list_candidates)
    if [ "${#CANDIDATES[@]}" -eq 0 ]; then
        echo "No BTRFS or /dev/mapper/ug_* devices found." >&2
        echo "Re-run with an explicit path: $0 /dev/mapper/<volume>" >&2
        exit 1
    fi
    for i in "${!CANDIDATES[@]}"; do
        echo "  [$i] ${CANDIDATES[$i]}"
    done
    if [ "${#CANDIDATES[@]}" -eq 1 ]; then
        TARGET="${CANDIDATES[0]}"
        echo "Only one candidate found — using: $TARGET"
    else
        read -rp "Select index [0-$((${#CANDIDATES[@]}-1))]: " idx
        if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -ge "${#CANDIDATES[@]}" ]; then
            echo "Invalid selection." >&2
            exit 1
        fi
        TARGET="${CANDIDATES[$idx]}"
    fi
fi

if [ ! -b "$TARGET" ]; then
    echo "Error: '$TARGET' is not a block device." >&2
    exit 1
fi

echo ""
echo "Target: $TARGET"
echo ""

# ── 1. Device identification ─────────────────────────────────────────────────

echo "===== [1/6] Device identification ====="
ls -la "$TARGET" || true
file -s "$TARGET" 2>&1 || true
blkid "$TARGET" 2>&1 || true
echo ""

# ── 2. dmesg snapshot before any mount attempt ───────────────────────────────

echo "===== [2/6] Kernel log (pre-mount) ====="
dmesg --ctime 2>/dev/null | grep -iE 'btrfs|ugacl|incompat' | tail -n 50 | tee "$DMESG_FILE" || true
echo ""

# ── 3. Native mount probe ────────────────────────────────────────────────────
# On UGOS the proprietary kernel should accept the volume.
# On vanilla Linux it should reject with an "unsupported incompat feature" line.
# Either way we only do a read-only probe and immediately unmount.

echo "===== [3/6] Native mount probe (read-only) ====="
PROBE_MNT="$(mktemp -d -t btrfs_probe_XXXXXX)"
MOUNT_RC=0
# `mount -o ro` alone is NOT strictly read-only on btrfs: the kernel may
# replay the log tree, which is a write to the device. We add nologreplay
# and norecovery so the probe really is read-only, even on a healthy live
# pool. ext4 ignores these options harmlessly.
PROBE_OPTS="ro,nologreplay,norecovery,noload,noatime,nodiratime"
# Bracket the device with blockdev --setro for belt-and-braces — kernel
# will refuse any write attempt even if a mount option is misinterpreted.
RO_RESTORE=""
if blockdev --getro "$TARGET" 2>/dev/null | grep -q '^0$'; then
    if blockdev --setro "$TARGET" 2>/dev/null; then
        RO_RESTORE="yes"
        echo "(set $TARGET read-only at the block layer for probe)"
    fi
fi
mount -o "$PROBE_OPTS" "$TARGET" "$PROBE_MNT" 2>&1 || MOUNT_RC=$?
if [ "$MOUNT_RC" -eq 0 ]; then
    echo "Mount succeeded (rc=0)."
    echo "Top-level entries:"
    ls -la "$PROBE_MNT" 2>&1 | head -n 20 || true
    if [ "$IS_UGOS" = "yes" ]; then
        echo "EXPECTED on UGREEN OS — your proprietary kernel groks the flag."
    else
        echo "UNEXPECTED on vanilla Linux — please report this."
    fi
    umount "$PROBE_MNT" || true
else
    echo "Mount failed (rc=$MOUNT_RC)."
    if [ "$IS_UGOS" = "yes" ]; then
        echo "UNEXPECTED on UGREEN OS — please report this."
    else
        echo "EXPECTED on vanilla Linux — the kernel rejects the UGREEN flag."
    fi
    echo "Kernel messages from the failed mount:"
    dmesg --ctime 2>/dev/null | grep -iE 'btrfs|ugacl|incompat' | tail -n 20 || true
fi
rmdir "$PROBE_MNT" 2>/dev/null || true
# Restore the block-layer read-write state if we changed it.
if [ "$RO_RESTORE" = "yes" ]; then
    blockdev --setrw "$TARGET" 2>/dev/null || true
    echo "(restored $TARGET to read-write at the block layer)"
fi
echo ""

# ── 4. patch_btrfs_ugos.py --check ───────────────────────────────────────────

echo "===== [4/6] Patcher --check (read-only) ====="
CHECK_RC=0
python3 "$PATCHER" --check "$TARGET" || CHECK_RC=$?
echo "Exit code: $CHECK_RC"
case "$CHECK_RC" in
    0)  echo "Interpretation: structurally valid; either all mirrors need patching"
        echo "                or all are already clean (see stdout above)." ;;
    1)  echo "Interpretation: validation error (CRC / bytenr / csum_type)."
        echo "                STOP. Do not proceed. Send this report to the maintainers." ;;
    2)  echo "Interpretation: MIXED state — partial prior patch detected. Resume possible." ;;
    *)  echo "Interpretation: unexpected exit code. Send this report to the maintainers." ;;
esac
echo ""

# ── 5. patch_btrfs_ugos.py --dump (read-only superblock backup) ──────────────

echo "===== [5/6] Patcher --dump (read-only backup) ====="
DUMP_RC=0
python3 "$PATCHER" --dump --backup-dir "$SB_DIR" "$TARGET" || DUMP_RC=$?
echo "Exit code: $DUMP_RC"
if [ "$DUMP_RC" -eq 0 ]; then
    echo "Backups produced:"
    ls -la "$SB_DIR"
    echo ""
    echo "SHA-256:"
    (cd "$SB_DIR" && sha256sum ./*.bin 2>/dev/null) || true
else
    echo "Dump failed. The --check output above explains why."
fi
echo ""

# ── 6. Summary ───────────────────────────────────────────────────────────────

echo "===== [6/6] Summary ====="
echo "Environment:       $([ "$IS_UGOS" = "yes" ] && echo "UGREEN OS" || echo "Vanilla Linux")"
echo "Target device:     $TARGET"
echo "Native mount:      $([ "$MOUNT_RC" -eq 0 ] && echo "succeeded" || echo "failed (rc=$MOUNT_RC)")"
echo "Patcher --check:   exit $CHECK_RC"
echo "Patcher --dump:    exit $DUMP_RC ($(ls "$SB_DIR"/*.bin 2>/dev/null | wc -l) mirror(s) saved)"
echo ""

# Verdict
echo "===== Verdict ====="
ok=1
if [ "$IS_UGOS" = "yes" ]; then
    [ "$MOUNT_RC" -eq 0 ] || { echo "❌ Native mount failed on UGOS — unexpected."; ok=0; }
else
    [ "$MOUNT_RC" -ne 0 ] || { echo "❌ Native mount succeeded on vanilla Linux — unexpected."; ok=0; }
fi
case "$CHECK_RC" in
    0|2) ;;
    *)   echo "❌ Patcher --check returned $CHECK_RC."; ok=0 ;;
esac
[ "$DUMP_RC" -eq 0 ] || { echo "❌ Patcher --dump failed (rc=$DUMP_RC)."; ok=0; }

if [ "$ok" -eq 1 ]; then
    echo "✅ All read-only checks behaved as expected for this environment."
    echo ""
    echo "Next step (OPTIONAL, still safe — uses a COW snapshot, no writes to $TARGET):"
    echo "    sudo $SCRIPT_DIR/recover_btrfs.sh $TARGET"
    echo "When recover_btrfs.sh asks 'Are you ready to permanently patch?' — answer N."
else
    echo "⚠️  At least one check did not match expectations. Send the report tarball"
    echo "    to the maintainers BEFORE running recover_btrfs.sh or any write operation."
fi

echo ""
echo "Finished: $(date)"
