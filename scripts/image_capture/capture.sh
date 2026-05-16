#!/usr/bin/env bash
#
# UGOS image capture — live, read-only, file-based.
#
# Reads only from the live system. Writes only to the directory passed via
# --out. Does not touch /, /etc, /boot, /home, /root, /var, /usr, /opt, /srv,
# /lib, and never descends into mounted data pools (tar --one-file-system).
#
# See README.md in this directory for the trust model and threat model.

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Defaults & argument parsing
# ----------------------------------------------------------------------------
PHASE=""
OUT=""
SPLIT_SIZE="2G"
ZSTD_LEVEL="10"
DRY_RUN=0

usage() {
    cat <<'USAGE'
Usage: capture.sh --phase {a|b} --out <dir> [options]

  --phase a       Kernel + modules + firmware + inventory only (~200-500 MB).
  --phase b       Phase A plus full sanitized-candidate rootfs (~2-8 GB).
  --out <dir>     Destination directory. Must NOT be on the system disk.
  --split <size>  Chunk size for the output (default: 2G).
  --zstd <lvl>    zstd compression level (default: 10).
  --dry-run       Show what would be captured, capture nothing.
  -h, --help      Show this help.

The output directory will contain:
  capture-phase-<a|b>-<host>-<timestamp>/
    inventory.json
    capture.tar.zst.000
    capture.tar.zst.001
    ...
    manifest.json     (sha256 of every chunk)
    capture.log       (tar warnings, changed-during-capture entries)
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase)    PHASE="$2"; shift 2 ;;
        --out)      OUT="$2"; shift 2 ;;
        --split)    SPLIT_SIZE="$2"; shift 2 ;;
        --zstd)     ZSTD_LEVEL="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "unknown arg: $1" >&2; usage; exit 2 ;;
    esac
done

if [[ -z "$PHASE" || -z "$OUT" ]]; then
    usage; exit 2
fi
if [[ "$PHASE" != "a" && "$PHASE" != "b" ]]; then
    echo "ERROR: --phase must be 'a' or 'b'" >&2; exit 2
fi
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: must run as root (need to read /etc/shadow et al)" >&2
    exit 2
fi

# ----------------------------------------------------------------------------
# Safety: refuse dangerous --out values
# ----------------------------------------------------------------------------
# Refuse if OUT is empty, root, or under a system path.
case "$(readlink -f -- "$OUT" 2>/dev/null || echo "$OUT")" in
    ""|/|/boot|/boot/*|/etc|/etc/*|/usr|/usr/*|/lib|/lib/*|/var|/var/*\
    |/home|/home/*|/root|/root/*|/opt|/opt/*|/srv|/srv/*|/sys|/sys/*\
    |/proc|/proc/*|/dev|/dev/*)
        echo "ERROR: refusing to write capture to system path: $OUT" >&2
        exit 3 ;;
esac

# Refuse if OUT is on the same filesystem as /.
mkdir -p -- "$OUT"
root_fsid="$(stat -c %d /)"
out_fsid="$(stat -c %d "$OUT")"
if [[ "$root_fsid" == "$out_fsid" ]]; then
    echo "ERROR: --out is on the same filesystem as /." >&2
    echo "       Use an external drive or a separate mount." >&2
    exit 3
fi

# Required tools.
for tool in tar zstd split sha256sum jq lsblk blkid findmnt; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool not found: $tool" >&2
        exit 4
    fi
done

# ----------------------------------------------------------------------------
# Compute paths
# ----------------------------------------------------------------------------
HOSTNAME_SAFE="$(hostname | tr -c 'A-Za-z0-9._-' '_' || echo nohost)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="${OUT%/}/capture-phase-${PHASE}-${HOSTNAME_SAFE}-${TS}"
mkdir -p -- "$WORK"

LOG="$WORK/capture.log"
exec > >(tee -a "$LOG") 2>&1

echo "[*] capture starting"
echo "[*] phase=$PHASE host=$HOSTNAME_SAFE ts=$TS"
echo "[*] kernel=$(uname -a)"
echo "[*] writing to: $WORK"
echo "[*] dry-run=$DRY_RUN"

# ----------------------------------------------------------------------------
# Inventory (Phase A and B both)
# ----------------------------------------------------------------------------
INV="$WORK/inventory.json"
echo "[*] collecting inventory -> $INV"

jq -n \
    --arg ts          "$TS" \
    --arg phase       "$PHASE" \
    --arg host        "$(hostname)" \
    --arg kernel      "$(uname -r)" \
    --arg kernel_full "$(uname -a)" \
    --arg arch        "$(uname -m)" \
    --arg cmdline     "$(cat /proc/cmdline 2>/dev/null || true)" \
    --argjson mounts  "$(findmnt -J -o TARGET,SOURCE,FSTYPE,OPTIONS,UUID 2>/dev/null || echo null)" \
    --argjson lsblk   "$(lsblk -J -O 2>/dev/null || echo null)" \
    --argjson blkid   "$(blkid -o export 2>/dev/null | awk 'BEGIN{print "["} \
                          /^DEVNAME=/{if(n>0)print ","; printf "{\"DEVNAME\":\"%s\"", substr($0,9); n=1; next} \
                          /=/{k=$0; sub(/=.*/,"",k); v=$0; sub(/^[^=]+=/,"",v); \
                              printf ",\"%s\":\"%s\"", k, v} \
                          END{print "]"}' || echo null)" \
    --arg os_release  "$(cat /etc/os-release 2>/dev/null || true)" \
    --arg ugos_files  "$(find /etc -maxdepth 2 -iname 'ug*' -o -iname '*ugreen*' 2>/dev/null | head -200 || true)" \
    '{
        timestamp: $ts,
        phase:     $phase,
        host:      $host,
        kernel:    $kernel,
        kernel_full: $kernel_full,
        arch:      $arch,
        cmdline:   $cmdline,
        os_release: $os_release,
        mounts:    $mounts,
        lsblk:     $lsblk,
        blkid:     $blkid,
        ugos_paths_hint: $ugos_files
    }' > "$INV"

echo "[+] inventory written ($(stat -c %s "$INV") bytes)"

# ----------------------------------------------------------------------------
# Build the tar include list
# ----------------------------------------------------------------------------
INCLUDE_FILE="$WORK/include.list"
EXCLUDE_FILE="$WORK/exclude.list"
: > "$INCLUDE_FILE"

# Phase A includes
{
    echo "/boot"
    echo "/lib/modules/$(uname -r)"
    echo "/lib/firmware"
    echo "/etc/fstab"
    echo "/etc/os-release"
    echo "/proc/cmdline"
} >> "$INCLUDE_FILE"

# Optional EFI partition
if findmnt -n /boot/efi >/dev/null 2>&1; then
    echo "/boot/efi" >> "$INCLUDE_FILE"
fi

# Copy the exclude.list shipped next to this script
SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/exclude.list" ]]; then
    cp -- "$SCRIPT_DIR/exclude.list" "$EXCLUDE_FILE"
else
    : > "$EXCLUDE_FILE"
fi

# Dynamic mount-based exclusion: enumerate every mount that isn't part of
# the OS (i.e. not /, /boot, /boot/efi) and add it to the exclude list.
# This catches btrfs/zfs data pools, bind-mounts of pool content into
# rootfs paths, FUSE shares, NFS, SMB, and anything else mounted at
# capture time. --one-file-system already protects most of this, but
# subvolumes and overlays can share st_dev with /, so we belt-and-brace.
echo "" >> "$EXCLUDE_FILE"
echo "# --- dynamic mount exclusions added by capture.sh at $(date -u +%FT%TZ) ---" >> "$EXCLUDE_FILE"
while IFS=$'\t' read -r target fstype source; do
    case "$target" in
        ""|"/"|"/boot"|"/boot/efi") continue ;;
        /proc/*|/sys/*|/dev/*|/run/*) continue ;;
    esac
    case "$fstype" in
        proc|sysfs|devtmpfs|devpts|tmpfs|cgroup|cgroup2|debugfs|tracefs|securityfs|pstore|bpf|configfs|fusectl|mqueue|hugetlbfs|rpc_pipefs|autofs|binfmt_misc|efivarfs|none)
            continue ;;
    esac
    # Real candidates: btrfs/zfs/ext4/xfs/etc. data mounts, network mounts,
    # FUSE shares, anything else.
    printf '%s/*\n%s\n' "$target" "$target" >> "$EXCLUDE_FILE"
    echo "[*] excluding mount: $target ($fstype, source=$source)"
done < <(findmnt -ln -o TARGET,FSTYPE,SOURCE 2>/dev/null)

# Phase B adds the entire rootfs, with --one-file-system to stay on /
if [[ "$PHASE" == "b" ]]; then
    # We tar / itself; --one-file-system prevents descending into pools.
    # Replace any /boot or /lib/modules entries already added (tar handles dupes).
    echo "/" >> "$INCLUDE_FILE"
fi

echo "[*] include list:"
sed 's/^/      /' "$INCLUDE_FILE"
echo "[*] exclude list: $EXCLUDE_FILE ($(wc -l < "$EXCLUDE_FILE") patterns)"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[*] dry-run: would now invoke tar on the above paths and stop."
    exit 0
fi

# ----------------------------------------------------------------------------
# The actual capture
# ----------------------------------------------------------------------------
CAP_PREFIX="$WORK/capture.tar.zst."

echo "[*] starting tar | zstd | split"
echo "[*] split size=$SPLIT_SIZE  zstd level=$ZSTD_LEVEL"

# Wrap tar so that exit code 1 ("some files changed while reading") — which
# is benign and expected on a live system — is mapped to 0. Any exit ≥ 2
# (fatal error) propagates so pipefail still aborts the script.
tar_live() {
    nice -n 19 ionice -c 3 \
        tar -c \
            --one-file-system \
            --acls --xattrs \
            --sparse \
            --warning=no-file-changed \
            --ignore-failed-read \
            --numeric-owner \
            -T "$INCLUDE_FILE" \
            -X "$EXCLUDE_FILE" \
            2>>"$LOG"
    local rc=$?
    if [[ $rc -eq 0 || $rc -eq 1 ]]; then return 0; fi
    return "$rc"
}

tar_live \
  | zstd -T0 "-${ZSTD_LEVEL}" \
  | split -b "$SPLIT_SIZE" -d -a 4 - "$CAP_PREFIX"
# Verify every stage of the pipeline succeeded. pipefail + set -e would
# normally abort already, but we check explicitly so the error message
# names the failing stage.
PSTAT=( "${PIPESTATUS[@]}" )
for i in "${!PSTAT[@]}"; do
    if [[ "${PSTAT[$i]}" -ne 0 ]]; then
        echo "ERROR: capture pipeline stage $i exited ${PSTAT[$i]}" >&2
        exit 10
    fi
done

# Ensure we actually produced at least one chunk. Otherwise the manifest
# would be empty and the sanitizer would happily process zero data.
shopt -s nullglob
produced=( "$CAP_PREFIX"* )
shopt -u nullglob
if [[ ${#produced[@]} -eq 0 ]]; then
    echo "ERROR: capture produced zero chunks. Check $LOG." >&2
    exit 11
fi
echo "[+] tar | zstd | split done (${#produced[@]} chunk(s))"

# ----------------------------------------------------------------------------
# Manifest with sha256 of every chunk
# ----------------------------------------------------------------------------
MANIFEST="$WORK/manifest.json"
echo "[*] computing sha256 manifest -> $MANIFEST"

{
    echo "{"
    echo "  \"phase\": \"$PHASE\","
    echo "  \"host\": \"$HOSTNAME_SAFE\","
    echo "  \"timestamp\": \"$TS\","
    echo "  \"split_size\": \"$SPLIT_SIZE\","
    echo "  \"zstd_level\": $ZSTD_LEVEL,"
    echo "  \"chunks\": ["
    first=1
    shopt -s nullglob
    for chunk in "$CAP_PREFIX"*; do
        sum="$(sha256sum -- "$chunk" | awk '{print $1}')"
        size="$(stat -c %s -- "$chunk")"
        name="$(basename -- "$chunk")"
        if [[ $first -eq 1 ]]; then first=0; else echo "    ,"; fi
        echo "    {\"name\": \"$name\", \"size\": $size, \"sha256\": \"$sum\"}"
    done
    shopt -u nullglob
    echo "  ]"
    echo "}"
} > "$MANIFEST"

TOTAL_BYTES="$(du -sb "$WORK" | awk '{print $1}')"
echo "[+] capture complete"
echo "[+] location: $WORK"
echo "[+] total size: $(numfmt --to=iec --suffix=B "$TOTAL_BYTES")"
echo "[+] read manifest.json and capture.log before doing anything else."
echo "[+] next step: ./sanitize.sh --in '$WORK' --out '${OUT%/}/sanitized-${TS}'"
