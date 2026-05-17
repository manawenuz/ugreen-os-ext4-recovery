#!/bin/bash
# Build patched e2fsprogs that recognizes UGREEN OS's 0x20000000 incompat flag.
# Produces:
#   ./build/e2fsprogs/misc/tune2fs   — strip the flag (one-way fix)
#   ./build/e2fsprogs/misc/fuse2fs   — read-only userspace mount
#   ./build/e2fsprogs/misc/e2image   — clone metadata for offline tests
#   ./build/e2fsprogs/e2fsck/e2fsck  — fsck the patched filesystem
#
# Usage: ./build_patched_e2fsprogs.sh
# Run from repo root (the directory containing patches/ and scripts/).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH="$REPO_ROOT/patches/0001-Recognize-ugreen_proprietary-incompat-feature.patch"
BUILD_DIR="$REPO_ROOT/build"

if [ ! -f "$PATCH" ]; then
    echo "ERROR: patch not found at $PATCH" >&2
    exit 1
fi

echo "=== [1/5] Installing build dependencies ==="
if command -v apt >/dev/null; then
    apt update
    apt install -y build-essential git autoconf automake libtool pkg-config \
                   libfuse-dev libblkid-dev uuid-dev gettext texinfo
elif command -v dnf >/dev/null; then
    dnf install -y gcc make git autoconf automake libtool pkgconfig \
                   fuse-devel libblkid-devel libuuid-devel gettext texinfo
else
    echo "WARN: unrecognized package manager — install build tools manually" >&2
fi

echo "=== [2/5] Cloning e2fsprogs ==="
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
E2FSPROGS_VERSION="v1.47.1"
if [ ! -d e2fsprogs ]; then
    git clone https://git.kernel.org/pub/scm/fs/ext2/e2fsprogs.git
fi
cd e2fsprogs
git fetch --tags
git checkout "$E2FSPROGS_VERSION"
git reset --hard HEAD
git clean -fdx

# Verify the upstream tag's GPG signature. e2fsprogs release tags are signed
# by Ted Ts'o; if the maintainer's key is in the local GPG keyring,
# `git verify-tag` succeeds. We DO NOT auto-fetch keys (that would defeat
# the purpose). On a fresh machine this step will warn loudly — that's
# correct behavior; the operator should fetch and verify Ted's key out of
# band before trusting the build. See EXT4-S1 in PRD_BUGS_EXT4_PATCH.md.
echo ""
echo "Verifying tag signature for $E2FSPROGS_VERSION..."
if git verify-tag "$E2FSPROGS_VERSION" 2>&1; then
    echo "  ✓ tag $E2FSPROGS_VERSION verified against local GPG keyring"
else
    rc=$?
    echo ""
    echo "  ⚠ tag $E2FSPROGS_VERSION signature could not be verified (exit $rc)."
    echo "    e2fsprogs release tags are signed by Ted Ts'o."
    echo "    To verify in the future, import his key first, e.g.:"
    echo "      gpg --keyserver keyserver.ubuntu.com --recv-keys <Ted's key ID>"
    echo "    The key ID and a current pinned fingerprint are intentionally"
    echo "    NOT hard-coded here; check kernel.org / signature on the tarball"
    echo "    out of band the first time you build."
    echo ""
    if [ -t 0 ]; then
        read -rp "Continue without signature verification? [y/N] " confirm
        case "${confirm:-N}" in
            [Yy]*) echo "    proceeding under operator override." ;;
            *)     echo "    aborting." >&2; exit 1 ;;
        esac
    else
        echo "  (non-interactive: aborting; rerun in a terminal to override)" >&2
        exit 1
    fi
fi

# Print the upstream commit SHA we just checked out, for reproducibility.
echo ""
echo "Upstream commit: $(git rev-parse HEAD)"

echo "=== [3/5] Applying patch ==="
git apply --check "$PATCH"
git apply "$PATCH"
echo "Patched files:"
git diff --stat
echo ""
echo "Patch contents (full):"
cat "$PATCH" | sed 's/^/    /'
echo ""

echo "=== [4/5] Configure & build ==="
CFLAGS="-std=gnu99 -D_FILE_OFFSET_BITS=64" ./configure --prefix=/usr/local/e2fsprogs-ugreen_os >"$BUILD_DIR/configure.log" 2>&1 || {
    echo "ERROR: configure failed. See $BUILD_DIR/configure.log" >&2
    tail -n 20 "$BUILD_DIR/configure.log" >&2
    exit 1
}
make -j"$(nproc)"

echo "=== [5/5] Sanity check ==="
if strings misc/tune2fs | grep -q '^ugreen_proprietary$'; then
    echo "  ✓ ugreen_proprietary string present in tune2fs"
else
    echo "  ✗ patch string missing in binary — build is broken" >&2
    exit 1
fi

echo "Verifying all built binaries:"
for bin in misc/tune2fs misc/fuse2fs misc/e2image e2fsck/e2fsck; do
    if [ ! -x "$bin" ]; then
        echo "  ✗ $bin missing" >&2
        exit 1
    fi
    echo "  ✓ $bin"
done

echo ""
echo "Run them directly from this build tree, e.g.:"
echo "  $(pwd)/misc/tune2fs -O ^ugreen_proprietary /dev/mapper/<volume>"
