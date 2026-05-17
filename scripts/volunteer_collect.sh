#!/bin/bash
#
# volunteer_collect.sh — read-only artefact collector for UGOS BTRFS debugging.
#
# Captures the kernel side (vmlinuz, initrd, modules), the userland side
# (squashfs images, factory partition), and on-disk metadata (full 64 KiB
# superblock regions, partition/RAID/LVM headers, dmesg) so maintainers
# can reconstruct a near-identical UGOS environment in a VM and debug
# their own tooling — without ever touching the volunteer's disks again.
#
# Specification: PRD_VOLUNTEER_COLLECTOR.md in this repo.
# Audit findings:  PRD_AUDIT_VOLUNTEER_COLLECTOR.md
#
# HARD RULES (enforced in code, not in docs):
#   1. Read-only. No `mount`, no `mkfs`, no `dd of=<block-device>`, no
#      `blockdev --setrw`, no `dmsetup create`. Only `dd if=<device>`,
#      file copies, and read-only tool invocations.
#   2. No --write / --patch / --fix / --repair flag exists. A typo
#      cannot escalate the script. It is a *collector*, full stop.
#   3. Dry-run is the default. First invocation prints what would be
#      captured + estimated size and exits. Pass --confirm to capture.
#   4. Refuses to operate on mounted-rw targets unless --allow-mounted.
#   5. Size-capped (default 2 GiB, hard ceiling 20 GiB).
#   6. Every captured file is sha256'd into MANIFEST.txt with a
#      "why captured" rationale.
#   7. Bundle never lands inside a known volunteer-data filesystem.
#   8. Sanitisation failure is fatal — no bundle ships unsanitised.
#
# Usage:
#   sudo ./scripts/volunteer_collect.sh                      # dry-run
#   sudo ./scripts/volunteer_collect.sh --confirm            # capture
#   sudo ./scripts/volunteer_collect.sh --confirm --out-dir /tmp
#   sudo ./scripts/volunteer_collect.sh --confirm --pool /dev/mapper/ug_…
#
# Output:
#   ./volunteer_bundle_<host-hash>_<UTC-date>.tar.gz
#

set -uo pipefail

# ─── Constants ──────────────────────────────────────────────────────────────

VERSION="0.2.0"
SCRIPT_NAME="volunteer_collect.sh"
DEFAULT_CAP_GIB=2
MAX_CAP_GIB=20    # hard upper bound even with --allow-large
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Filesystems we refuse to write the bundle into (volunteer data).
FORBIDDEN_OUT_PREFIXES=(/volume /home /overlay /rootfs /mnt/factory /root /var/lib)

# ─── Pretty printing ────────────────────────────────────────────────────────

step_total=0
step_idx=0
step() {
    step_idx=$((step_idx + 1))
    printf '\n[step %d/%d] %s\n' "$step_idx" "$step_total" "$1"
    if [ $# -ge 2 ]; then
        printf '          why: %s\n' "$2"
    fi
}
note() { printf '          %s\n' "$1"; }
fail() {
    printf '\n[%s] ERROR: %s\n' "$SCRIPT_NAME" "$1" >&2
    printf '[%s] If unexpected, paste the last ~30 lines into the GitHub issue.\n' "$SCRIPT_NAME" >&2
    exit 1
}

# Human-readable size. Falls back to raw bytes if numfmt is missing.
hsize() {
    local b="${1:-0}"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B --format='%.1f' "$b" 2>/dev/null || echo "${b}B"
    else
        echo "${b}B"
    fi
}

# ─── Pre-flight: args, root, tools ──────────────────────────────────────────

# Handle --help / --version BEFORE the root check so users can read help
# without sudo.
for a in "$@"; do
    case "$a" in
        -h|--help)    : ;;   # will be handled in main parse below
        --version)    echo "$SCRIPT_NAME $VERSION"; exit 0 ;;
    esac
done
case "${1:-}" in
    -h|--help)
        # Inline help path so root isn't required.
        cat <<HELP
$SCRIPT_NAME v$VERSION — read-only artefact collector for UGOS BTRFS debugging.

Usage:
  sudo $0                         dry-run (prints plan, captures nothing)
  sudo $0 --confirm               actually capture
  sudo $0 --confirm [flags...]

Flags:
  --confirm              Actually capture. Without this, only a plan is printed.
  --allow-mounted        Acknowledge that pools are mounted read-write
                         (we still only do reads).
  --allow-large=N        Raise the size cap to N GiB (default 2, max $MAX_CAP_GIB).
  --out-dir DIR          Write the bundle into DIR (default: current dir).
                         Bundle is REFUSED inside /volume*, /home, /overlay,
                         /rootfs, /mnt/factory, /root, /var/lib.
  --pool /dev/<device>   Restrict capture to a specific pool. Repeatable.
  --include-config       Also capture /etc/ugreen, /etc/ugos (small text trees).
  --version              Print version and exit.
  -h, --help             This help.

This script will NEVER accept --write, --patch, --fix, --repair, --apply,
--commit. It is a read-only collector; if you want recovery, that's a
different conversation (and a different script: recover_btrfs.sh, only
after maintainers have approved it for your specific case).

Bundle contents are described in scripts/VOLUNTEER_COLLECT_README.md.
HELP
        exit 0
        ;;
esac

CONFIRM=0
ALLOW_MOUNTED=0
ALLOW_LARGE_GIB=0
OUT_DIR_RAW=""
declare -a EXPLICIT_POOLS=()
INCLUDE_CONFIG=0   # /etc/ugreen, /etc/ugos — small but flag-gated

print_help() {
    cat <<HELP
$SCRIPT_NAME v$VERSION — read-only artefact collector for UGOS BTRFS debugging.

Usage:
  sudo $0                         dry-run (prints plan, captures nothing)
  sudo $0 --confirm               actually capture
  sudo $0 --confirm [flags...]

Flags:
  --confirm              Actually capture. Without this, only a plan is printed.
  --allow-mounted        Acknowledge that pools are mounted read-write
                         (we still only do reads).
  --allow-large=N        Raise the size cap to N GiB (default 2, max $MAX_CAP_GIB).
  --out-dir DIR          Write the bundle into DIR (default: current dir).
                         Bundle is REFUSED inside /volume*, /home, /overlay,
                         /rootfs, /mnt/factory, /root, /var/lib.
  --pool /dev/<device>   Restrict capture to a specific pool. Repeatable.
  --include-config       Also capture /etc/ugreen, /etc/ugos (small text trees).
  --version              Print version and exit.
  -h, --help             This help.

This script will NEVER accept --write, --patch, --fix, --repair, --apply,
--commit. It is a read-only collector; if you want recovery, that's a
different conversation (and a different script: recover_btrfs.sh, only
after maintainers have approved it for your specific case).

Bundle contents are described in scripts/VOLUNTEER_COLLECT_README.md.
HELP
    exit 0
}

# Snapshot raw args so the re-invocation hint only echoes what the user passed.
declare -a USER_ARGS=("$@")

while [ $# -gt 0 ]; do
    case "$1" in
        --confirm)         CONFIRM=1 ;;
        --allow-mounted)   ALLOW_MOUNTED=1 ;;
        --allow-large=*)   ALLOW_LARGE_GIB="${1#--allow-large=}" ;;
        --allow-large)     shift; ALLOW_LARGE_GIB="${1:-}" ;;
        --out-dir=*)       OUT_DIR_RAW="${1#--out-dir=}" ;;
        --out-dir)         shift; OUT_DIR_RAW="${1:-}" ;;
        --pool=*)
            p="${1#--pool=}"
            [ -n "$p" ] || fail "--pool requires a non-empty device path"
            EXPLICIT_POOLS+=("$p")
            ;;
        --pool)
            shift
            [ -n "${1:-}" ] || fail "--pool requires a non-empty device path"
            EXPLICIT_POOLS+=("$1")
            ;;
        --include-config)  INCLUDE_CONFIG=1 ;;
        --version)         echo "$SCRIPT_NAME $VERSION"; exit 0 ;;
        -h|--help)         print_help ;;
        --write|--patch|--fix|--repair|--apply|--commit)
            fail "this script is a read-only collector; '$1' is not a real flag (and never will be). For recovery, see recover_btrfs.sh — and only run that after maintainers have approved it for your specific case."
            ;;
        --*) fail "unknown flag '$1'. See --help." ;;
        *)   fail "positional arguments not accepted (got '$1'). Use --pool to restrict to specific devices. See --help." ;;
    esac
    shift
done

# Validate cap.
if ! [[ "$ALLOW_LARGE_GIB" =~ ^[0-9]+$ ]]; then
    fail "--allow-large must be a non-negative integer (GiB), got '$ALLOW_LARGE_GIB'"
fi
CAP_GIB=$DEFAULT_CAP_GIB
if [ "$ALLOW_LARGE_GIB" -gt 0 ]; then
    if [ "$ALLOW_LARGE_GIB" -gt "$MAX_CAP_GIB" ]; then
        fail "--allow-large=$ALLOW_LARGE_GIB exceeds hard ceiling of ${MAX_CAP_GIB} GiB"
    fi
    CAP_GIB="$ALLOW_LARGE_GIB"
fi
CAP_BYTES=$(( CAP_GIB * 1024 * 1024 * 1024 ))

# Root check happens AFTER arg parsing so --help / --version / --write
# rejection all work without sudo.
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    fail "must run as root (sudo $0 ...)"
fi

# Canonicalise --out-dir and refuse if it resolves under a volunteer-data prefix.
OUT_DIR="${OUT_DIR_RAW:-$PWD}"
[ -d "$OUT_DIR" ] || fail "--out-dir '$OUT_DIR' does not exist"
[ -w "$OUT_DIR" ] || fail "--out-dir '$OUT_DIR' not writable"
if command -v readlink >/dev/null 2>&1; then
    OUT_DIR_CANON="$(readlink -f "$OUT_DIR" 2>/dev/null || echo "$OUT_DIR")"
else
    OUT_DIR_CANON="$OUT_DIR"
fi
for prefix in "${FORBIDDEN_OUT_PREFIXES[@]}"; do
    case "$OUT_DIR_CANON" in
        "$prefix"|"$prefix"/*)
            fail "--out-dir '$OUT_DIR' resolves to '$OUT_DIR_CANON', which is under '$prefix'. Bundles must not be written into volunteer-data filesystems. Use --out-dir /tmp or your home dir."
            ;;
    esac
done

# Required tools. Missing tools produce an actionable hint.
require_tool() {
    local bin="$1" pkg="$2"
    if ! command -v "$bin" >/dev/null 2>&1; then
        fail "'$bin' not found. Install with: apt-get install $pkg"
    fi
}
require_tool dd                  coreutils
require_tool sha256sum           coreutils
require_tool tar                 tar
require_tool gzip                gzip
require_tool blkid               util-linux
require_tool lsblk               util-linux
require_tool findmnt             util-linux
require_tool dmsetup             dmsetup
require_tool blockdev            util-linux
require_tool python3             python3   # used for sanitisation; fatal if missing
# Soft-required (degrade with note):
have_btrfs=0;   command -v btrfs   >/dev/null 2>&1 && have_btrfs=1
have_mdadm=0;   command -v mdadm   >/dev/null 2>&1 && have_mdadm=1
have_pvs=0;     command -v pvs     >/dev/null 2>&1 && have_pvs=1
have_modinfo=0; command -v modinfo >/dev/null 2>&1 && have_modinfo=1

# ─── Work directory (alongside OUT_DIR so cap applies to its filesystem) ────

UTC_DATE="$(date -u +%Y%m%dT%H%M%SZ)"
HOST_HASH="$(printf '%s' "$(hostname)" | sha256sum | cut -c1-8)"
BUNDLE_NAME="volunteer_bundle_${HOST_HASH}_${UTC_DATE}"
WORKDIR="$(mktemp -d "${OUT_DIR_CANON}/.${BUNDLE_NAME}.XXXXXX")"
chmod 700 "$WORKDIR"

# Manifest captured incrementally. TAB-separated to avoid space-parsing bugs.
MANIFEST="$WORKDIR/MANIFEST.txt"
MANIFEST_HEADER_LINES=6
{
    echo "# volunteer_collect.sh v$VERSION manifest"
    echo "# bundle: $BUNDLE_NAME"
    echo "# captured (UTC): $UTC_DATE"
    echo "#"
    echo "# Columns (TAB-separated): sha256 size_bytes path rationale"
    echo "#"
} > "$MANIFEST"

# Cleanup: on any non-success exit (signal, fail, error), remove WORKDIR
# entirely so no half-captured artefacts linger anywhere.
INTERRUPTED=0
cleanup() {
    local rc=$?
    # Tar succeeded means we have the bundle outside WORKDIR; safe to drop WORKDIR.
    # Anything else: remove WORKDIR so no partial captures hang around.
    if [ -d "$WORKDIR" ]; then
        rm -rf "$WORKDIR"
    fi
    if [ "$INTERRUPTED" -eq 1 ]; then
        printf '\n[%s] interrupted; no partial files left behind.\n' "$SCRIPT_NAME" >&2
        exit 130
    fi
    exit "$rc"
}
on_signal() { INTERRUPTED=1; exit 130; }
trap cleanup EXIT
trap on_signal INT TERM HUP

# Record a file in the manifest. Uses TAB separator.
record() {
    local rel="$1" rationale="$2"
    local abs="$WORKDIR/$rel"
    [ -f "$abs" ] || return 0
    local sum size
    sum="$(sha256sum "$abs" | awk '{print $1}')"
    size="$(stat -c%s "$abs" 2>/dev/null || stat -f%z "$abs")"
    printf '%s\t%s\t%s\t%s\n' "$sum" "$size" "$rel" "$rationale" >> "$MANIFEST"
}

current_size_bytes() {
    du -sb "$WORKDIR" 2>/dev/null | awk '{print $1}'
}

check_cap() {
    local now
    now="$(current_size_bytes)"
    if [ "$now" -gt "$CAP_BYTES" ]; then
        fail "captured size $(hsize "$now") exceeds cap $(hsize "$CAP_BYTES"). Re-run with --allow-large=N (max ${MAX_CAP_GIB})."
    fi
}

# ─── Pool discovery ─────────────────────────────────────────────────────────

discover_pools() {
    # If user gave explicit --pool, just validate those.
    if [ "${#EXPLICIT_POOLS[@]}" -gt 0 ]; then
        for p in "${EXPLICIT_POOLS[@]}"; do
            [ -b "$p" ] || fail "explicit --pool '$p' is not a block device"
            printf '%s\n' "$p"
        done
        return
    fi
    # Otherwise: every btrfs-labelled block device, preferring UGOS-style
    # /dev/mapper/ug_* names. Use a glob (NOT $(ls ...)) so word-splitting
    # doesn't break on space-bearing device names.
    declare -A seen
    shopt -s nullglob
    local d
    for d in /dev/mapper/ug_*; do
        if [ -b "$d" ] && blkid -p -s TYPE "$d" 2>/dev/null | grep -q 'TYPE="btrfs"'; then
            if [ -z "${seen[$d]:-}" ]; then
                seen[$d]=1
                printf '%s\n' "$d"
            fi
        fi
    done
    shopt -u nullglob
    while IFS= read -r d; do
        [ -n "$d" ] && [ -z "${seen[$d]:-}" ] && { seen[$d]=1; printf '%s\n' "$d"; }
    done < <(blkid -t TYPE=btrfs -o device 2>/dev/null)
}

# Use OPTIONS column alone (not parsing two columns) to avoid space-in-SOURCE
# breaking column alignment.
is_mounted_rw() {
    local dev="$1" opts
    opts="$(findmnt -nro OPTIONS --source "$dev" 2>/dev/null | head -1)"
    [ -n "$opts" ] || return 1
    case ",$opts," in
        *,rw,*) return 0 ;;
        *)      return 1 ;;
    esac
}

# ─── Capture plan (dry-run shows this and stops) ────────────────────────────

mapfile -t POOLS < <(discover_pools)
if [ "${#POOLS[@]}" -eq 0 ]; then
    fail "no BTRFS pools detected. Pass --pool /dev/<device> to override."
fi

# Sanity: refuse mounted-rw unless explicitly allowed.
MOUNTED_POOLS=()
for p in "${POOLS[@]}"; do
    if is_mounted_rw "$p"; then
        MOUNTED_POOLS+=("$p")
    fi
done
if [ "${#MOUNTED_POOLS[@]}" -gt 0 ] && [ "$ALLOW_MOUNTED" -ne 1 ]; then
    {
        echo "The following pool(s) are mounted read-write:"
        printf '  %s\n' "${MOUNTED_POOLS[@]}"
        echo ""
        echo "This is a safety checkpoint, not an error. We read these devices"
        echo "block-by-block with 'dd if=<device>' — read-side only — which is"
        echo "safe even while UGOS is using them. We just want you to consciously"
        echo "acknowledge that we'll be reading from a live filesystem."
        echo ""
        echo "Re-run with --allow-mounted to proceed."
    } >&2
    exit 2
fi

# Estimate bundle size from the pools and rootfs paths we plan to capture.
estimate_capture_bytes() {
    local total=0
    # Kernel + initrd (small).
    for f in /boot/vmlinuz /boot/boot/vmlinuz /boot/initrd.img /boot/boot/initrd.img \
             /boot/boot/vmlinuz2 /boot/boot/initrd2.img; do
        if [ -f "$f" ]; then
            total=$(( total + $(stat -c%s "$f" 2>/dev/null || echo 0) ))
        fi
    done
    # Module tree, factory partition, squashfs files.
    local KREL
    KREL="$(uname -r)"
    if [ -d "/lib/modules/$KREL" ]; then
        total=$(( total + $(du -sb "/lib/modules/$KREL" 2>/dev/null | awk '{print $1}') ))
    fi
    for sub in base kernel apt fw oem; do
        if mountpoint -q "/rootfs/$sub" 2>/dev/null; then
            local src
            src="$(findmnt -nro SOURCE "/rootfs/$sub" 2>/dev/null)"
            local sqfs
            sqfs="$(losetup -nO BACK-FILE "$src" 2>/dev/null || true)"
            if [ -n "$sqfs" ] && [ -f "$sqfs" ]; then
                total=$(( total + $(stat -c%s "$sqfs" 2>/dev/null || echo 0) ))
            fi
        fi
    done
    # SB regions: 64 KiB × 3 mirrors × pools, plus 1 MiB first-region.
    total=$(( total + ${#POOLS[@]} * (3 * 65536 + 1048576) ))
    # gzip compression: assume ~30%.
    echo $(( total * 7 / 10 ))
}
EST_BYTES="$(estimate_capture_bytes)"

# ── Print plan ──────────────────────────────────────────────────────────────

echo "============================================================"
echo " $SCRIPT_NAME v$VERSION — $([ "$CONFIRM" -eq 1 ] && echo "CAPTURE" || echo "DRY RUN")"
echo "============================================================"
echo "Bundle name      : $BUNDLE_NAME.tar.gz"
echo "Output dir       : $OUT_DIR_CANON"
echo "Size cap         : ${CAP_GIB} GiB"
echo "Estimated bundle : $(hsize "$EST_BYTES")  (rough; final size after gzip will vary)"
echo "Pools            :"
for p in "${POOLS[@]}"; do
    sz="$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)"
    mnt="$(findmnt -nro TARGET --source "$p" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
    printf '    %s   size=%s   mounted=%s\n' "$p" "$(hsize "$sz")" "${mnt:-no}"
done
echo ""
echo "Will capture:"
echo "  system/        uname, lsblk -J, blkid, mdadm, lvm, dmsetup, findmnt, dmesg(btrfs)"
echo "  kernel/        vmlinuz + initrd from /boot, /lib/modules/\$(uname -r) tarred, EFI dir"
echo "  rootfs/        squashfs images mounted at /rootfs/* (UGOS userland) + factory partition"
echo "  sb/            full 64 KiB superblock regions × 3 mirrors × N pools, btrfs dump-super"
echo "  sb/            first 1 MiB of each pool device (partition/RAID/LVM headers)"
if [ "$INCLUDE_CONFIG" -eq 1 ]; then
    echo "  config/        /etc/ugreen, /etc/ugos (text only, sanitised)"
fi
echo ""
echo "Will NOT capture (ever):"
echo "  /volume*, /home, /overlay, /root  — your user data is off-limits"
echo "  /etc/shadow, ssh keys, network config files"
echo "  full disk images"
echo ""
echo "Tools this script will INVOKE (all read-only):"
echo "  dd if=<device> …    blkid    lsblk    findmnt    dmsetup table/info"
echo "  blockdev --getsize64    mdadm --detail    pvs/vgs/lvs    btrfs --version"
echo "  btrfs inspect-internal dump-super -fa    cp -a    tar -c    gzip -c"
echo ""
echo "Tools this script will NEVER invoke:"
echo "  mount    mkfs.*    dd of=<device>    blockdev --setrw    dmsetup create"
echo "  btrfstune    btrfs check --repair    rm on anything outside the work dir"
echo "  (grep this file for those names — you will find them only in this list)"
echo ""

if [ "$CONFIRM" -ne 1 ]; then
    echo "This was a dry run. To actually capture, re-run with --confirm:"
    echo ""
    # Only echo flags the user actually passed (avoids cluttering the hint
    # with --out-dir=$PWD that the user never set).
    printf '    sudo %s --confirm' "$0"
    for arg in "${USER_ARGS[@]}"; do
        case "$arg" in
            --confirm) ;;  # already added
            *) printf ' %q' "$arg" ;;
        esac
    done
    printf '\n\n'
    exit 0
fi

# ─── Actual capture ─────────────────────────────────────────────────────────

step_total=8

# ── Step 1: system geometry ────────────────────────────────────────────────
step "Recording system geometry" \
     "we need lsblk/blkid/mdadm/lvm/dmsetup output to reconstruct the dm-mapper stack in a VM"
mkdir -p "$WORKDIR/system"
uname -a                                    > "$WORKDIR/system/uname.txt"      2>&1 || true
cat /proc/cmdline                           > "$WORKDIR/system/cmdline.txt"    2>&1 || true
lsblk -J -O                                 > "$WORKDIR/system/lsblk.json"     2>&1 || true
blkid                                       > "$WORKDIR/system/blkid.txt"      2>&1 || true
findmnt -J                                  > "$WORKDIR/system/findmnt.json"   2>&1 || true

# Aggregate dmsetup into a single file (PRD §4.1).
{
    echo "## dmsetup table"
    dmsetup table 2>&1 || true
    echo ""
    echo "## dmsetup info"
    dmsetup info 2>&1 || true
} > "$WORKDIR/system/dmsetup.txt"

# Aggregate mdadm into a single file (PRD §4.1).
if [ "$have_mdadm" -eq 1 ]; then
    {
        echo "## mdadm --detail --scan"
        mdadm --detail --scan 2>&1 || true
        echo ""
        for m in /dev/md[0-9]*; do
            [ -b "$m" ] || continue
            echo "## mdadm --detail $m"
            mdadm --detail "$m" 2>&1 || true
            echo ""
        done
    } > "$WORKDIR/system/mdadm.txt"
fi

# Aggregate lvm into a single file (PRD §4.1).
if [ "$have_pvs" -eq 1 ]; then
    {
        echo "## pvs -o +all"
        pvs -o +all 2>&1 || true
        echo ""
        echo "## vgs -o +all"
        vgs -o +all 2>&1 || true
        echo ""
        echo "## lvs -o +all"
        lvs -o +all 2>&1 || true
    } > "$WORKDIR/system/lvm.txt"
fi

# Aggregate btrfs/modinfo versions into a single file (PRD §4.1).
{
    echo "## btrfs --version"
    [ "$have_btrfs" -eq 1 ] && btrfs --version 2>&1 || echo "btrfs-progs not installed"
    echo ""
    echo "## modinfo btrfs"
    [ "$have_modinfo" -eq 1 ] && modinfo btrfs 2>&1 || echo "modinfo unavailable"
    echo ""
    echo "## modinfo ugacl_vfs"
    [ "$have_modinfo" -eq 1 ] && modinfo ugacl_vfs 2>&1 || echo "modinfo unavailable"
} > "$WORKDIR/system/btrfs_versions.txt"

dmesg --ctime 2>/dev/null | grep -iE 'btrfs|ugacl|incompat' > "$WORKDIR/system/dmesg_btrfs.txt" || true

for f in "$WORKDIR"/system/*; do
    record "system/$(basename "$f")" "system geometry / live-kernel evidence"
done
check_cap

# ── Step 2: kernel + initrd ────────────────────────────────────────────────
step "Capturing kernel (vmlinuz + initrd)" \
     "we need the exact kernel and initramfs that mount this FS so we can boot a matching VM"
mkdir -p "$WORKDIR/kernel"
KREL="$(uname -r)"
for candidate in /boot/vmlinuz /boot/boot/vmlinuz "/boot/vmlinuz-$KREL"; do
    if [ -f "$candidate" ]; then
        cp -a "$candidate" "$WORKDIR/kernel/vmlinuz"
        break
    fi
done
for candidate in /boot/initrd.img /boot/boot/initrd.img "/boot/initrd.img-$KREL"; do
    if [ -f "$candidate" ]; then
        cp -a "$candidate" "$WORKDIR/kernel/initrd.img"
        break
    fi
done
[ -f /boot/boot/vmlinuz2 ]    && cp -a /boot/boot/vmlinuz2    "$WORKDIR/kernel/vmlinuz2"    || true
[ -f /boot/boot/initrd2.img ] && cp -a /boot/boot/initrd2.img "$WORKDIR/kernel/initrd2.img" || true
record kernel/vmlinuz    "bootable kernel"
record kernel/initrd.img "matching initramfs"
record kernel/vmlinuz2   "A/B slot kernel"
record kernel/initrd2.img "A/B slot initramfs"
check_cap

# ── Step 3: kernel modules ─────────────────────────────────────────────────
step "Capturing kernel modules" \
     "btrfs.ko and ugacl_vfs.ko contain the on-disk format we need to model"
if [ -d "/lib/modules/$KREL" ]; then
    tar --one-file-system -C /lib/modules -czf "$WORKDIR/kernel/modules.tar.gz" "$KREL" 2>/dev/null || true
    record kernel/modules.tar.gz "module tree (contains btrfs.ko, ugacl_vfs.ko)"
else
    note "/lib/modules/$KREL not present; skipping module tree"
fi
check_cap

# ── Step 4: EFI partition ──────────────────────────────────────────────────
step "Capturing EFI partition (if present)" \
     "boot chain context; helps us reproduce the exact boot path"
EFI_MNT="$(findmnt -nro TARGET -t vfat 2>/dev/null | grep -E '^/boot(/efi)?$' | head -1 || true)"
if [ -n "$EFI_MNT" ] && [ -d "$EFI_MNT" ]; then
    tar --one-file-system -C "$EFI_MNT" -czf "$WORKDIR/kernel/efi.tar.gz" . 2>/dev/null || true
    record kernel/efi.tar.gz "EFI partition contents"
else
    note "no EFI partition mounted; skipping"
fi
check_cap

# ── Step 5: rootfs squashfs + factory ──────────────────────────────────────
step "Capturing UGOS rootfs squashfs images" \
     "we need UGOS userland to assemble a bootable VM; these are vendor-shipped, no user data"
mkdir -p "$WORKDIR/rootfs"
for sub in base kernel apt fw oem; do
    src="/rootfs/$sub"
    if mountpoint -q "$src" 2>/dev/null; then
        backing="$(findmnt -nro SOURCE --target "$src" 2>/dev/null)"
        sqfs="$(losetup -nO BACK-FILE "$backing" 2>/dev/null || true)"
        if [ -n "$sqfs" ] && [ -f "$sqfs" ]; then
            cp -a "$sqfs" "$WORKDIR/rootfs/$sub.sqfs"
            record "rootfs/$sub.sqfs" "UGOS userland layer ($sub)"
        else
            note "could not resolve squashfs backing file for $src"
        fi
    fi
done
FACTORY_DEV="$(findmnt -nro SOURCE --target /mnt/factory 2>/dev/null || true)"
if [ -b "$FACTORY_DEV" ]; then
    note "dumping factory partition $FACTORY_DEV → rootfs/factory.img.gz"
    dd if="$FACTORY_DEV" bs=1M status=none 2>/dev/null | gzip -c > "$WORKDIR/rootfs/factory.img.gz" || true
    record rootfs/factory.img.gz "UGOS factory partition (small, vendor data)"
fi
check_cap

# ── Step 6: superblock regions ─────────────────────────────────────────────
step "Capturing BTRFS superblock regions (64 KiB × 3 mirrors per pool)" \
     "full 64 KiB lets us model checksum coverage incl. UGACL extension"
mkdir -p "$WORKDIR/sb"
# btrfs SB mirror offsets:   64 KiB,  64 MiB,   256 GiB
declare -a MIRROR_OFFSETS_KIB=(64 65536 268435456)
for p in "${POOLS[@]}"; do
    pool_name="$(basename "$p")"
    # TOCTOU re-check: refuse if pool became mounted-rw since plan was printed
    # (unless --allow-mounted was passed).
    if [ "$ALLOW_MOUNTED" -ne 1 ] && is_mounted_rw "$p"; then
        fail "pool '$p' became mounted-rw during capture (TOCTOU). Re-run with --allow-mounted if intentional."
    fi
    pool_size="$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)"
    for i in 0 1 2; do
        off_kib="${MIRROR_OFFSETS_KIB[$i]}"
        off_bytes=$(( off_kib * 1024 ))
        if [ "$off_bytes" -ge "$pool_size" ]; then
            note "$pool_name mirror $i at ${off_kib} KiB is past device end; skipping"
            continue
        fi
        # 64 KiB = 16 blocks of 4 KiB. dd skip is in bs units.
        dd if="$p" of="$WORKDIR/sb/${pool_name}_mirror${i}_64KiB.bin" \
           bs=4096 count=16 skip=$(( off_kib / 4 )) status=none 2>/dev/null || true
        record "sb/${pool_name}_mirror${i}_64KiB.bin" \
               "full 64 KiB SB region for $pool_name mirror $i (offset ${off_kib} KiB)"
    done
    # First 1 MiB of the device (partition / RAID / LVM headers in situ).
    # PRD §4.1 filename: <pool>_first_1MiB.bin.gz  (underscore between first and 1MiB).
    dd if="$p" bs=1M count=1 status=none 2>/dev/null | gzip -c > "$WORKDIR/sb/${pool_name}_first_1MiB.bin.gz" || true
    record "sb/${pool_name}_first_1MiB.bin.gz" \
           "first 1 MiB of $pool_name (partition/RAID/LVM header context)"
    # Kernel's own dump-super output — ground truth for what crc32c IT computes.
    if [ "$have_btrfs" -eq 1 ]; then
        btrfs inspect-internal dump-super -fa "$p" > "$WORKDIR/sb/${pool_name}_dump_super.txt" 2>&1 || true
        record "sb/${pool_name}_dump_super.txt" \
               "btrfs-progs dump-super: ground truth for kernel-computed CRC and incompat flags"
    fi
done
check_cap

# ── Step 7: optional config capture ────────────────────────────────────────
step "Optional config capture" \
     "small, helps explain non-default mkfs options; only if --include-config"
if [ "$INCLUDE_CONFIG" -eq 1 ]; then
    mkdir -p "$WORKDIR/config"
    for d in /etc/ugreen /etc/ugos /etc/ugnas /usr/share/ugreen /usr/share/ugos; do
        if [ -d "$d" ]; then
            rel="config/$(echo "$d" | tr / _).tar.gz"
            # --one-file-system + no -h: don't follow symlinks out of the dir.
            tar --one-file-system -C / -czf "$WORKDIR/$rel" "${d#/}" 2>/dev/null || true
            record "$rel" "UGOS config directory $d"
        fi
    done
else
    note "skipped (use --include-config to enable)"
fi
check_cap

# ── Step 8: sanitisation (mandatory, fatal on failure) ─────────────────────
step "Sanitising text artefacts" \
     "scrub hostnames, MACs, public IPs, IPv6, serials, WWNs (UUIDs kept)"

real_host="$(hostname 2>/dev/null || echo '')"

# All sanitisation in one Python pass — easier to reason about, single point
# of failure, and handles IPv6 properly (sed can't).
python3 - "$WORKDIR/system" "$WORKDIR/sb" "$WORKDIR/config" <<PYEOF
import ipaddress, json, os, re, sys

REAL_HOST = ${real_host@Q}

IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
IPV6 = re.compile(r"\b(?:[A-Fa-f0-9]{1,4}:){2,7}[A-Fa-f0-9]{1,4}\b")
MAC  = re.compile(r"\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b")
SERIAL_JSON = re.compile(r'("serial"\s*:\s*)"[^"]*"')
WWN_JSON    = re.compile(r'("wwn"\s*:\s*)"[^"]*"')
SERIAL_KEY  = re.compile(r'(SERIAL=)"[^"]*"')
WWN_KEY     = re.compile(r'(WWN=)"[^"]*"')

def scrub_ipv4(m):
    ip = m.group(0)
    try:
        a = ipaddress.IPv4Address(ip)
    except Exception:
        return ip
    if a.is_private or a.is_loopback or a.is_link_local or a.is_multicast or a.is_reserved or a.is_unspecified:
        return ip
    return "203.0.113.1"

def scrub_ipv6(m):
    ip = m.group(0)
    try:
        a = ipaddress.IPv6Address(ip)
    except Exception:
        return ip
    if a.is_private or a.is_loopback or a.is_link_local or a.is_multicast or a.is_reserved or a.is_unspecified or a.is_site_local:
        return ip
    return "2001:db8::1"

def scrub(text):
    if REAL_HOST and REAL_HOST not in ("localhost", ""):
        text = re.sub(r"\b" + re.escape(REAL_HOST) + r"\b", "VOLUNTEER", text)
    text = MAC.sub("aa:bb:cc:dd:ee:ff", text)
    text = IPV4.sub(scrub_ipv4, text)
    text = IPV6.sub(scrub_ipv6, text)
    text = SERIAL_JSON.sub(r'\1"SERIAL_REDACTED"', text)
    text = WWN_JSON.sub(r'\1"WWN_REDACTED"', text)
    text = SERIAL_KEY.sub(r'\1"SERIAL_REDACTED"', text)
    text = WWN_KEY.sub(r'\1"WWN_REDACTED"', text)
    return text

EXTS = (".txt", ".json", ".log")
for root in sys.argv[1:]:
    if not os.path.isdir(root):
        continue
    for dp, _, fns in os.walk(root):
        for fn in fns:
            if not fn.endswith(EXTS):
                continue
            p = os.path.join(dp, fn)
            try:
                with open(p, "r", errors="replace") as fh:
                    data = fh.read()
            except Exception as e:
                print("SCRUB_FAIL\t%s\t%s" % (p, e), file=sys.stderr)
                sys.exit(2)
            new = scrub(data)
            if new != data:
                try:
                    with open(p, "w") as fh:
                        fh.write(new)
                except Exception as e:
                    print("SCRUB_FAIL\t%s\t%s" % (p, e), file=sys.stderr)
                    sys.exit(2)
print("SCRUB_OK")
PYEOF
SCRUB_RC=$?
if [ "$SCRUB_RC" -ne 0 ]; then
    fail "sanitisation pass failed (exit $SCRUB_RC). Bundle not produced. Re-run after fixing the cause; do not send the work-in-progress files."
fi

# Verification pass: after scrubbing, no text artefact should contain the
# real hostname (case-insensitive, word-bounded).
if [ -n "$real_host" ] && [ "$real_host" != "localhost" ]; then
    if grep -rwIi "$real_host" "$WORKDIR/system" "$WORKDIR/sb" 2>/dev/null | head -1 | grep -q .; then
        fail "sanitisation verification failed: hostname '$real_host' still appears in text artefacts. Bundle not produced."
    fi
fi

# Rebuild manifest from scratch over the work dir so all sha256/size values
# reflect the post-scrub state. Avoids the old re-hash-with-fragile-parsing path.
{
    head -n "$MANIFEST_HEADER_LINES" "$MANIFEST"
} > "$MANIFEST.new"
# Preserve original rationales by reading the old manifest into an associative array.
declare -A RATIONALES
while IFS=$'\t' read -r _ _ rel rationale; do
    [ -n "$rel" ] || continue
    RATIONALES["$rel"]="$rationale"
done < <(tail -n +$(( MANIFEST_HEADER_LINES + 1 )) "$MANIFEST")
# Walk the workdir and emit fresh hashes.
while IFS= read -r abs; do
    rel="${abs#"$WORKDIR/"}"
    [ "$rel" = "MANIFEST.txt" ] && continue
    [ "$rel" = "MANIFEST.txt.new" ] && continue
    sum="$(sha256sum "$abs" | awk '{print $1}')"
    size="$(stat -c%s "$abs" 2>/dev/null || stat -f%z "$abs")"
    rationale="${RATIONALES[$rel]:-captured (no rationale recorded)}"
    printf '%s\t%s\t%s\t%s\n' "$sum" "$size" "$rel" "$rationale" >> "$MANIFEST.new"
done < <(find "$WORKDIR" -type f ! -name 'MANIFEST.txt*' | sort)
mv "$MANIFEST.new" "$MANIFEST"

# ── Enforce PRD §4.1: required artefacts must exist ────────────────────────

REQUIRED=(
    MANIFEST.txt
    system/uname.txt
    system/cmdline.txt
    system/lsblk.json
    system/blkid.txt
    system/findmnt.json
    system/dmsetup.txt
    system/btrfs_versions.txt
    system/dmesg_btrfs.txt
    kernel/vmlinuz
    kernel/initrd.img
)
# Per-pool required artefacts.
for p in "${POOLS[@]}"; do
    pool_name="$(basename "$p")"
    REQUIRED+=("sb/${pool_name}_first_1MiB.bin.gz")
    # At least the 64 KiB mirror must exist; the other two depend on device size.
    REQUIRED+=("sb/${pool_name}_mirror0_64KiB.bin")
done
MISSING=()
for rel in "${REQUIRED[@]}"; do
    [ -f "$WORKDIR/$rel" ] || MISSING+=("$rel")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
    {
        echo "Required artefacts missing from the work directory:"
        printf '  - %s\n' "${MISSING[@]}"
        echo ""
        echo "Bundle not produced. Likely causes:"
        echo "  - A capture step exited early. Re-run and look at [step N/M] lines for hints."
        echo "  - A required tool is missing (rerun and the script will name it)."
        echo "  - You ran on a system without UGOS userland (no /boot/vmlinuz)."
    } >&2
    fail "${#MISSING[@]} required artefact(s) missing"
fi

# ─── Bundle ─────────────────────────────────────────────────────────────────

BUNDLE_PATH="$OUT_DIR_CANON/$BUNDLE_NAME.tar.gz"
tar -C "$WORKDIR" -czf "$BUNDLE_PATH" .
chmod 600 "$BUNDLE_PATH"

# Chown to the invoking sudo user so they can scp without another sudo.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    chown "$SUDO_USER" "$BUNDLE_PATH" 2>/dev/null || true
fi

BUNDLE_SIZE="$(stat -c%s "$BUNDLE_PATH" 2>/dev/null || stat -f%z "$BUNDLE_PATH")"
BUNDLE_SHA="$(sha256sum "$BUNDLE_PATH" | awk '{print $1}')"

# Single-line summary, human-readable.
echo ""
echo "Bundle: $BUNDLE_PATH  ($(hsize "$BUNDLE_SIZE"), sha256=$BUNDLE_SHA) — attach this file to the GitHub issue; you're done."
