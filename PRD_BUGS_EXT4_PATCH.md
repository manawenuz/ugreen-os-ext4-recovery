# Bug PRD: ext4 Recovery Toolchain

This file mirrors `PRD_BUGS_BTRFS_PATCH.md` for the ext4 path. It is
maintained as a known-bugs log so future contributors (and volunteers)
can see at a glance what has been found and addressed.

The ext4 toolchain has a substantially smaller attack surface than the
btrfs one: it delegates the actual on-disk mutation to upstream `tune2fs`,
applies only a small additive patch (four hunks) to whitelist the
`ugreen_proprietary` incompat bit, and never rolls its own crypto. The
BUG-016-class (silently-wrong checksum routine) cannot recur here.

## 1. Audit history

- **2026-05-17** — first formal three-lens audit (safety / correctness /
  UX) applied in the wake of BTRFS BUG-016. Memo: `PRD_AUDIT_EXT4_PATCH.md`.
  Found one real bug (BUG-EXT4-001), five should-fixes, and several UX gaps.
  All addressed in the same commit that landed this file.

## 2. Resolved Bugs

### BUG-EXT4-001: Inverted COW_DIR logic (RESOLVED)
*   **Severity:** Volunteer-availability (not data-loss).
*   **Defect:** `scripts/recover.sh` selected `/tmp` for the 1 GiB COW
    image when `/tmp` was tmpfs, and `/var/tmp` otherwise. The intent
    was the opposite — keep the COW *off* tmpfs to avoid OOMing
    memory-constrained NAS systems. Same anti-pattern as BTRFS BUG-011,
    just in the ext4 sibling.
*   **Impact (would-have-been):** on a memory-constrained host with
    `/tmp` on tmpfs, the 1 GiB COW image would have consumed RAM until
    dm-snapshot invalidated; the test would have aborted mid-flow. Real
    disk was never at risk.
*   **Fix:** invert the conditional. Default to `/var/tmp` when `/tmp`
    is tmpfs; respect a user-provided `COW_DIR=` env var.

### EXT4-S1: e2fsprogs tag unverified (RESOLVED)
*   **Severity:** Supply-chain trust.
*   **Defect:** `scripts/build_patched_e2fsprogs.sh` cloned e2fsprogs
    over HTTPS and ran `git checkout v1.47.1` without `git verify-tag`.
    e2fsprogs tags are signed by Ted Ts'o; nothing was validating that.
*   **Fix:** the build script now runs `git verify-tag v1.47.1`. If the
    signing key is not in the local GPG keyring, the script prints
    instructions for fetching it out-of-band and (interactively) asks
    for an operator override. Non-interactive runs abort. The upstream
    commit SHA is also printed for reproducibility, and the full patch
    diff is echoed before compilation.

### EXT4-S2: COW e2fsck failures swallowed (RESOLVED)
*   **Severity:** Process — could have allowed a corrupted COW result
    to proceed to a real-disk write.
*   **Defect:** `recover.sh` ran `"$E2FSCK" -fn "$SNAP_DEV" || true`,
    which discarded any e2fsck error indicators. A volunteer would have
    seen "SUCCESS!" and the "ready to permanently patch?" prompt even
    when e2fsck on the COW snapshot reported uncorrectable errors.
*   **Fix:** capture the e2fsck exit code (in a local `set +e`/`set -e`
    block), surface it, and refuse the real-disk write entirely if it
    is non-zero. The volunteer sees a "Refusing to commit to real disk"
    message and is told to send the output to the maintainers.

### EXT4-S3: Mount/holder check too narrow (RESOLVED)
*   **Severity:** Data-loss risk.
*   **Defect:** `recover.sh` only checked `findmnt -n "$TARGET_DEV"`.
    A device used as swap, or as an LVM PV in an active VG, or with
    md/dm devices stacked above, would pass the check — then be
    modified by `tune2fs` under the kernel's feet.
*   **Fix:** the gate now also checks `swapon --show` and
    `/sys/block/<dev>/holders/`. Any active stacking aborts with a
    clear error message instructing the operator to disable the
    stacked devices first.

### EXT4-S5: No SB backup before real-disk write (RESOLVED)
*   **Severity:** No-rollback risk.
*   **Defect:** Unlike the btrfs patcher, `recover.sh` did not capture
    the primary superblock before invoking `tune2fs` on the real disk.
    A power-loss mid-write or an unexpected `tune2fs` regression would
    have left no automated rollback path.
*   **Fix:** before invoking `tune2fs -O ^ugreen_proprietary` on the
    real device, `recover.sh` now `dd`'s the first 4 KiB to a
    timestamped + PID-suffixed file in `$REPO_ROOT` and prints a
    `dd` one-liner for rolling back if needed.

### EXT4-CONFIRM: Single-character commit prompt (RESOLVED)
*   **Severity:** UX → safety.
*   **Defect:** `recover.sh` accepted a single `y`/`Y` for an
    irreversible operation. After the maintainer-trust callout in the
    README, this was the only step that felt loose; industry standard
    for destructive ops increasingly requires typing a token.
*   **Fix:** after the initial `y/N`, the script asks the volunteer to
    retype the device basename exactly. Mismatch aborts the run.

## 3. Acknowledged but deferred

| Tag       | Issue                                                           | Why deferred                                            |
|-----------|-----------------------------------------------------------------|---------------------------------------------------------|
| EXT4-S4   | No trap between real-disk `tune2fs` and post-fsck               | Very narrow window; signal handling is awkward to test  |
| EXT4-S6   | `verify_hashes.sh` has hardcoded one-off paths                  | Looks like maintainer scratch; not in the main flow     |
| EXT4-N1   | Bit `0x20000000` could collide if e2fsprogs upgrades            | Pinned to v1.47.1; comment in patch would be belt+braces |
| Doc       | No `EXT4_TESTING.md` runbook (btrfs has one)                    | Maintainer flow works; volunteer flow is `recover.sh`   |
| Test      | No upstream-vs-patched checksum equivalence test                | libext2fs is shared upstream code; risk is structural   |

These can be picked up in a follow-up audit cycle if/when ext4 sees
more volunteer activity.

## 4. Status

The ext4 toolchain is currently the project's mature path. No active
lockdown applies: `recover.sh` will commit to the real disk after the
COW dry-run, the volunteer's exit code check, the device-basename
retype, the mount/holder gate, and the SB backup. None of these are
new ceremony — they're the audit-recommended floor for any tool that
writes to someone's actual data.
