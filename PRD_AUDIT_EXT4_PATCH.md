# Audit findings: ext4 recovery toolchain

Three independent reviewers in parallel — safety / correctness / disclosure.
Mandates non-overlapping. Findings below in fix order.

## Context

After landing BUG-016 (the wrong-polynomial crc32c bug in the btrfs patcher),
we applied the same skeptical audit lens to the ext4 toolchain.
Significant difference: the ext4 path **delegates the actual on-disk
mutation to upstream `tune2fs`** (built from `e2fsprogs v1.47.1` plus a
~10-line additive patch). No hand-rolled CRC, no offset arithmetic,
no checksum math. The BUG-016 class — silently-wrong crypto in shipped
code — cannot recur here.

But the surrounding orchestration (`recover.sh`, `build_patched_e2fsprogs.sh`)
has the same volunteer-safety failure modes as the btrfs side did before
the lockdown. Those are addressable without overengineering a fundamentally
sound tool.

The maintainer has used this ext4 path on their own DXP NAS to recover a
multi-TB pool; it is the project's mature path.

## Findings

### Correctness (Lens 2) — clean

- No bit collision: `0x20000000` (= 1<<29) is unallocated in mainline ext4
  through kernel 6.12. CASEFOLD is the highest INCOMPAT bit at `0x20000`;
  VERITY/ORPHAN_PRESENT live in the separate RO_COMPAT word.
- Patch is complete in all four required locations: `feature.c`, `ext2_fs.h`,
  `ext2fs.h` (SUPP mask), `tune2fs.c` (clear_ok_features).
- `mke2fs.c` is correctly NOT patched — preserves "one-way conversion only"
  intent.
- libext2fs's `ext2fs_flush2()` handles CRC recalculation and backup-SB
  propagation; that's upstream code shared with every distro.

Verification gaps acknowledged but low-risk:
- No test confirming patched-tune2fs produces byte-identical output to mainline.
- No comment in `recover.sh` flagging the silent journal-replay that happens
  on the snapshot before the strip.

### Safety (Lens 1) — one real bug + five should-fixes

**Real bugs:**

| Tag    | Issue                                                                                       |
|--------|---------------------------------------------------------------------------------------------|
| BUG-EXT4-001 | `recover.sh` lines 36–41: `$COW_DIR` logic is **inverted**. When `/tmp` is tmpfs the script *overrides* the safe `/var/tmp` default with `/tmp`. Same anti-pattern as BTRFS BUG-011. |

**Supply-chain & trust:**

| Tag    | Issue                                                                                       |
|--------|---------------------------------------------------------------------------------------------|
| EXT4-S1 | `build_patched_e2fsprogs.sh` clones e2fsprogs over HTTPS and `git checkout v1.47.1` without `git verify-tag`. Ted Ts'o signs the tags; volunteers running the build today are not verifying against his key. |

**Process & orchestration:**

| Tag    | Issue                                                                                       |
|--------|---------------------------------------------------------------------------------------------|
| EXT4-S2 | `recover.sh:83`: COW-snapshot e2fsck swallows failures with `\|\| true`. Volunteer sees "SUCCESS!" and proceeds to real-disk write even if COW e2fsck flagged real corruption. |
| EXT4-S3 | `recover.sh:108`: mount check uses `findmnt -n` only. Misses swap, LVM PV holders, stacked dm/md. |
| EXT4-S4 | `recover.sh:113–123`: no trap between real-disk `tune2fs` and post-fsck. SIGINT in that window leaves operator without state info. |
| EXT4-S5 | `recover.sh`: no original-SB backup before write. btrfs equivalent does this; parity is cheap. |
| EXT4-S6 | `scripts/verify_hashes.sh`: hardcoded paths from a one-off maintainer session (`/mnt/new-pool1`, `recovery_test_30848`). |

**Bit-reservation risk (forward-looking only):**

| Tag    | Issue                                                                                       |
|--------|---------------------------------------------------------------------------------------------|
| EXT4-N1 | If a future upstream e2fsprogs adopts bit `0x20000000` for a real feature, a patched binary rebuilt against newer e2fsprogs would silently clear that feature when asked to clear `ugreen_proprietary`. Pinning v1.47.1 mitigates; worth a comment in the patch. |

### UX / Disclosure (Lens 3)

**Asymmetry with btrfs:**

- README has a loud "Status: locked down" callout for btrfs, **nothing for ext4**. A cold reader infers asymmetry as an unspoken warning about ext4.
- `recover.sh` accepts a single `y`/`Y` for irreversible op; `recover_btrfs.sh` removed its prompt entirely under lockdown. The inconsistency is jarring to a reader of both.

**Volunteer onboarding:**

- No "which filesystem do I have?" detection hint. Step 3 of README says run `recover.sh` then Step 4 says "if btrfs use the other one"; users don't always know which they have.
- `recover.sh:30`'s error ("not a UGREEN OS volume, or already patched") does not redirect btrfs users to `recover_btrfs.sh`.
- No `EXT4_TESTING.md` runbook; the btrfs side has 13K of one.

**Trust statement:**

- No `PRD_BUGS_EXT4_PATCH.md`. README never states "maintainer runs this on their own NAS" nor "no known bugs as of <date>." Both extremes are absent.
- Build-trust boundary not stated: the patched `tune2fs` binary is the trust root after the build script runs.
- The "atomically" claim Lens 1's brief feared does not exist; PRD and README correctly say "propagate" not "atomically."

## Calculus question — full lockdown vs reduced

The btrfs lockdown was driven by a hand-rolled CRC bug that *was* wrong on
real input. ext4 here delegates to mainline `tune2fs`; the patch is ten
additive lines that whitelist a bit. Bug-class risk is dramatically lower.

**Recommendation:** do NOT apply the full btrfs posture (no hidden flag,
no `recover.sh` write-step removal, no exit-code-3 refusal). DO apply a
reduced posture targeting the four real volunteer-safety gaps:

1. Fix BUG-EXT4-001 (the inverted COW_DIR logic).
2. Close EXT4-S1 (GPG-verify the e2fsprogs tag in the build script).
3. Close EXT4-S2 (gate the real-disk prompt on COW e2fsck exit code).
4. Close EXT4-S3 (widen the mount/holder check).
5. Close EXT4-S5 (4 KiB SB backup before real-disk write).
6. Add an ext4 Status callout to README mirroring the btrfs one but stating
   the mature-path posture.
7. Tighten `recover.sh`'s confirmation: require the operator to retype the
   device path rather than accept a single `y`.

EXT4-S4 (trap window), EXT4-S6 (verify_hashes.sh cleanup), EXT4-N1 (bit
reservation comment), and the absence of `EXT4_TESTING.md` are
acknowledged but deferred — they don't affect data-safety for a volunteer
running the maintainer-tested flow.

## Resolution

Implemented in commit landing alongside this PRD:

- `recover.sh`: COW_DIR fixed, COW e2fsck gates the prompt, mount/holder check
  widened (parses `/proc/self/mountinfo` + checks `/sys/block/<dev>/holders/`
  + checks `swapon`), 4 KiB SB backup before real-disk write, confirmation
  prompt requires retyping the device path basename.
- `build_patched_e2fsprogs.sh`: `git verify-tag v1.47.1` step (with hint about
  fetching Ted Ts'o's signing key) and prints a checksum + patch diff stat
  before compiling.
- `README.md`: ext4 Status callout added, positioned next to the btrfs one
  so the asymmetry resolves into a clear "stable vs experimental" statement.
- `PRD_BUGS_EXT4_PATCH.md`: new file, mirrors `PRD_BUGS_BTRFS_PATCH.md`,
  records BUG-EXT4-001 and the other findings.
