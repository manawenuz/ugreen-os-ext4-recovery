#!/usr/bin/env bash
#
# UGOS capture sanitizer.
#
# Reads a capture directory produced by capture.sh and produces a new,
# sanitized capture directory. The original is never modified, and the
# live system is never touched.
#
# Sanitization rules live in sanitize.rules. Read that file before running.

set -Eeuo pipefail

IN=""
OUT=""
ROOT_PASSWORD="ugos-volunteer-vm"  # the password baked into the VM image
DRY_RUN=0

usage() {
    cat <<'USAGE'
Usage: sanitize.sh --in <capture-dir> --out <new-dir> [options]

  --in <dir>       Directory produced by capture.sh.
  --out <dir>      Destination for sanitized output (must not exist or be empty).
  --root-pw <pw>   Password to bake into the sanitized image's root account.
                   Default: ugos-volunteer-vm
  --dry-run        Show what would be sanitized; produce no output.
  -h, --help       Show this help.

The sanitizer:
  1. extracts the captured tarball into a staging directory under --out
  2. applies the rules in sanitize.rules (logging every action)
  3. re-tars + zstds + splits into a fresh sanitized tarball
  4. emits sanitize.log and diffs of /etc/passwd, /etc/shadow, /etc/fstab

The staging directory is deleted after re-tarring (unless --keep-staging).
USAGE
}

KEEP_STAGING=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --in)          IN="$2"; shift 2 ;;
        --out)         OUT="$2"; shift 2 ;;
        --root-pw)     ROOT_PASSWORD="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=1; shift ;;
        --keep-staging) KEEP_STAGING=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "unknown arg: $1" >&2; usage; exit 2 ;;
    esac
done

if [[ -z "$IN" || -z "$OUT" ]]; then usage; exit 2; fi
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: must run as root (need to preserve ownership during extract)" >&2
    exit 2
fi
if [[ ! -d "$IN" ]]; then
    echo "ERROR: --in does not exist: $IN" >&2; exit 3
fi
if [[ -e "$OUT" && -n "$(ls -A -- "$OUT" 2>/dev/null || true)" ]]; then
    echo "ERROR: --out exists and is not empty: $OUT" >&2; exit 3
fi
mkdir -p -- "$OUT"

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RULES_FILE="$SCRIPT_DIR/sanitize.rules"
if [[ ! -f "$RULES_FILE" ]]; then
    echo "ERROR: sanitize.rules not found next to sanitize.sh" >&2; exit 4
fi

STAGING="$OUT/staging"
LOG="$OUT/sanitize.log"
DIFF_DIR="$OUT/diffs"
mkdir -p -- "$STAGING" "$DIFF_DIR"

exec > >(tee -a "$LOG") 2>&1
echo "[*] sanitize starting"
echo "[*] in:  $IN"
echo "[*] out: $OUT"
echo "[*] rules: $RULES_FILE"
echo "[*] dry-run: $DRY_RUN"

# ----------------------------------------------------------------------------
# Reassemble + extract
# ----------------------------------------------------------------------------
CHUNKS=( "$IN"/capture.tar.zst.* )
if [[ ! -e "${CHUNKS[0]}" ]]; then
    echo "ERROR: no capture.tar.zst.* chunks in $IN" >&2; exit 5
fi
echo "[*] reassembling ${#CHUNKS[@]} chunk(s) into staging"
echo "[*] verifying manifest checksums"

MANIFEST="$IN/manifest.json"
if [[ -f "$MANIFEST" ]]; then
    while IFS= read -r line; do
        name="$(echo "$line" | jq -r '.name')"
        want="$(echo "$line" | jq -r '.sha256')"
        have="$(sha256sum -- "$IN/$name" | awk '{print $1}')"
        if [[ "$want" != "$have" ]]; then
            echo "ERROR: checksum mismatch on $name" >&2
            echo "  manifest: $want"; echo "  computed: $have"
            exit 6
        fi
    done < <(jq -c '.chunks[]' "$MANIFEST")
    echo "[+] all chunks match manifest"
else
    echo "WARNING: no manifest.json found; skipping checksum verification"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[*] dry-run: would now extract and sanitize. stopping."
    exit 0
fi

cat -- "${CHUNKS[@]}" | zstd -d -T0 | tar -x \
    --acls --xattrs --numeric-owner \
    -C "$STAGING" 2>>"$LOG"

echo "[+] extraction complete"

# ----------------------------------------------------------------------------
# Apply rules
# ----------------------------------------------------------------------------
echo "[*] applying sanitize.rules"

# Snapshot originals for diffs.
for f in etc/passwd etc/shadow etc/fstab; do
    if [[ -f "$STAGING/$f" ]]; then
        cp -a -- "$STAGING/$f" "$DIFF_DIR/$(basename "$f").before"
    fi
done

apply_strip() {
    local pat="$1"
    local n=0
    local find_expr=()

    # Pattern dispatch:
    #   **/<glob>   → match basename anywhere in the tree (find -name)
    #   /abs/path*  → match absolute path under staging (find -path)
    #
    # find's -path treats `*` as matching anything INCLUDING `/`, so a stray
    # `**` becomes effectively `*` and matches almost nothing. We split the
    # two cases explicitly.
    case "$pat" in
        '**/'*)
            local name_pat="${pat#**/}"
            find_expr=( -name "$name_pat" )
            ;;
        /*)
            find_expr=( -path "${STAGING}${pat}" )
            ;;
        *)
            echo "WARNING: unsupported STRIP pattern (must start with / or **/): $pat"
            return 0
            ;;
    esac

    while IFS= read -r -d '' path; do
        # Defense in depth: refuse to act on any path outside staging,
        # even though find rooted at $STAGING should never produce one.
        case "$path" in
            "$STAGING"/*|"$STAGING") ;;
            *) echo "WARNING: refusing to act on out-of-staging path: $path"; continue ;;
        esac
        rm -rf -- "$path"
        echo "STRIP    ${path#$STAGING}"
        n=$((n+1))
    done < <(find "$STAGING" "${find_expr[@]}" -print0 2>/dev/null)
    echo "[*] strip pattern '$pat' removed $n path(s)"
}

apply_replace() {
    local target="$1"
    local mode="$2"
    local full="${STAGING}${target}"
    if [[ ! -e "$full" && ! -L "$full" ]]; then
        # MISSING is an error for credential-bearing targets — if /etc/shadow
        # was not captured, we MUST NOT proceed and accidentally ship secrets
        # from a sibling file. The maintainer can override by editing the
        # rules, but the default fails closed.
        case "$mode" in
            shadow-stub|passwd-strip-gecos|fstab-strip-data)
                echo "ERROR: REPLACE target missing in capture: $target ($mode)" >&2
                echo "       refusing to continue. Re-run capture or remove the rule." >&2
                return 1
                ;;
            *)
                echo "REPLACE  (no-op, missing) $target"
                return 0
                ;;
        esac
    fi
    # Defense in depth: break any symlink before writing, so `>` cannot
    # follow it to a location outside the staging tree.
    if [[ -L "$full" ]]; then
        rm -f -- "$full"
    fi
    case "$mode" in
        empty)
            rm -f -- "$full"
            : > "$full"
            echo "REPLACE  $target  (-> empty)"
            ;;
        shadow-stub)
            # Root only, with chosen password. All others locked.
            local hash
            hash="$(openssl passwd -6 -- "$ROOT_PASSWORD")"
            rm -f -- "$full"
            cat > "$full" <<EOF
root:${hash}:19000:0:99999:7:::
daemon:*:19000:0:99999:7:::
bin:*:19000:0:99999:7:::
sys:*:19000:0:99999:7:::
nobody:*:19000:0:99999:7:::
EOF
            chmod 0640 -- "$full"
            echo "REPLACE  $target  (-> shadow-stub, root pw set)"
            ;;
        passwd-strip-gecos)
            # Keep lines, blank out the GECOS field (5th of 7).
            awk -F: 'BEGIN{OFS=":"} {$5=""; print}' "$full" > "$full.new"
            mv -f -- "$full.new" "$full"
            echo "REPLACE  $target  (-> GECOS stripped)"
            ;;
        fstab-strip-data)
            # Comment out lines that look like data-pool mounts.
            # Heuristic: mount target under /volume, /pool, /mnt, /media,
            # /storage, /data — or fstype btrfs/zfs that isn't / or /boot.
            awk '
                /^[[:space:]]*#/ { print; next }
                /^[[:space:]]*$/ { print; next }
                {
                  tgt=$2; fs=$3
                  if (tgt ~ /^\/(volume|pool|mnt|media|storage|data)/ \
                      || ((fs=="btrfs"||fs=="zfs") && tgt != "/" && tgt != "/boot" && tgt != "/boot/efi")) {
                      print "# sanitized-out: " $0; next
                  }
                  print
                }
            ' "$full" > "$full.new"
            mv -f -- "$full.new" "$full"
            echo "REPLACE  $target  (-> data-pool entries commented out)"
            ;;
        *)
            echo "ERROR: unknown REPLACE mode '$mode' for $target" >&2
            return 1
            ;;
    esac
}

while IFS= read -r line; do
    # Strip comments and surrounding whitespace.
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    # Tokenize on whitespace (handles single OR multiple spaces between
    # the command and its arguments — the rules file uses a column-aligned
    # style which inserts multiple spaces).
    # shellcheck disable=SC2206
    tokens=( $line )
    cmd="${tokens[0]}"
    case "$cmd" in
        STRIP)
            if [[ ${#tokens[@]} -ne 2 ]]; then
                echo "WARNING: STRIP expects exactly 1 argument (line: $line)"
                continue
            fi
            apply_strip "${tokens[1]}"
            ;;
        REPLACE)
            if [[ ${#tokens[@]} -ne 3 ]]; then
                echo "WARNING: REPLACE expects exactly 2 arguments (line: $line)"
                continue
            fi
            apply_replace "${tokens[1]}" "${tokens[2]}"
            ;;
        *)
            echo "WARNING: unknown rule '$cmd' (line: $line)"
            ;;
    esac
done < "$RULES_FILE"

# Diffs.
for f in etc/passwd etc/shadow etc/fstab; do
    if [[ -f "$DIFF_DIR/$(basename "$f").before" && -f "$STAGING/$f" ]]; then
        diff -u "$DIFF_DIR/$(basename "$f").before" "$STAGING/$f" \
            > "$DIFF_DIR/$(basename "$f").diff" || true
    fi
done
echo "[+] diffs written to $DIFF_DIR/"

# ----------------------------------------------------------------------------
# Re-tar
# ----------------------------------------------------------------------------
echo "[*] re-tarring sanitized staging"
OUT_PREFIX="$OUT/sanitized.tar.zst."
( cd "$STAGING" && \
  tar -c --acls --xattrs --sparse --numeric-owner . \
  | zstd -T0 -19 \
  | split -b 2G -d -a 4 - "$OUT_PREFIX" )

MANIFEST_OUT="$OUT/manifest.json"
{
    echo "{"
    echo "  \"sanitized_from\": \"$(basename "$IN")\","
    echo "  \"chunks\": ["
    first=1
    shopt -s nullglob
    for chunk in "$OUT_PREFIX"*; do
        sum="$(sha256sum -- "$chunk" | awk '{print $1}')"
        size="$(stat -c %s -- "$chunk")"
        name="$(basename -- "$chunk")"
        if [[ $first -eq 1 ]]; then first=0; else echo "    ,"; fi
        echo "    {\"name\": \"$name\", \"size\": $size, \"sha256\": \"$sum\"}"
    done
    shopt -u nullglob
    echo "  ]"
    echo "}"
} > "$MANIFEST_OUT"

# Also copy the original inventory.json (it's already non-sensitive metadata).
if [[ -f "$IN/inventory.json" ]]; then
    cp -- "$IN/inventory.json" "$OUT/inventory.json"
fi

if [[ "$KEEP_STAGING" -eq 0 ]]; then
    echo "[*] cleaning up staging"
    rm -rf -- "$STAGING"
else
    echo "[*] keeping staging at $STAGING"
fi

echo "[+] sanitize complete"
echo "[+] output: $OUT"
echo "[+] review: sanitize.log and diffs/*.diff before uploading anything"
