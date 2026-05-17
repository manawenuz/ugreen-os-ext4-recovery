# Audit findings: BUG-016 patcher CRC fix

Three independent reviewers in parallel — safety / correctness / disclosure.
Mandates were non-overlapping. Findings consolidated below in fix order.

## Context

`scripts/patch_btrfs_ugos.py` shipped a CRC bug for an entire release
cycle: `_build_crc32c_table` used the forward Castagnoli polynomial
`0x1EDC6F41` in an LSB-first table builder, which requires the reflected
form `0x82F63B78`. The patcher's `--check` therefore reported "CRC
mismatch" against perfectly healthy on-disk superblocks. Anyone who had
proceeded to `recover_btrfs.sh` write-mode would have **corrupted their
filesystem** by overwriting valid SBs with wrong CRCs. The bug never
reached the wild because `--check` always failed first and the validator
told volunteers to stop. The volunteer in issue #1 was the canonical
false-positive.

Found via:
1. Static analysis of UGOS's `btrfs.ko` with `pyelftools` + `capstone`
   — confirmed the kernel hashes mainline range `[0x20..0x1000)`.
2. RFC 3720 test vectors — proved our routine is not crc32c.
3. The volunteer's own SB dumps — our (fixed) routine reproduces the
   byte stored in the on-disk csum field on all three mirrors.

Fix: one-line constant change `0x1EDC6F41` → `0x82F63B78`.

## Audit findings (3 lenses)

### Lens 1 — safety / latent disk-corruption

**Blockers (fixed):**
1. **Patcher had no mount check.** Anyone invoking the patcher directly
   (bypassing `recover_btrfs.sh`) could write under the kernel's feet.
   *Fix:* added `is_device_mounted_rw()` and a write-time gate; refuses
   unless `--allow-mounted` is passed. Mirrors the collector's gate.
2. **No post-write read-back verification.** The very bug we just fixed
   was undetectable for a release cycle precisely because nothing
   re-read the disk after writing. *Fix:* after every per-mirror write,
   re-read the SB from disk, recompute CRC, assert (CRC valid) ∧ (UGREEN
   bit cleared). Abort the run on mismatch, while backups are still
   warm.
3. **Stale comment in `make_synth_btrfs.sh` named wrong poly as crc32c.**
   Future contributor copying that comment seeds the same bug again.
   *Fix:* expanded the comment with explicit warning + cross-reference
   to this PRD and the regression test.

**Should-fix (addressed where cheap):**
- Backup filename collision in same-second runs. *Fix:* nanosecond
  timestamp + PID.
- `--yes` doesn't verify target is a dm-snapshot device. Acknowledged
  but not fixed: `recover_btrfs.sh` already wraps the dm-snapshot
  workflow; adding a separate check inside the patcher would couple it
  to dmsetup conventions and could false-positive on volunteers running
  on partition images for testing. Documented in the new `--allow-mounted`
  flag's help text.

### Lens 2 — correctness of the fix

**No correctness bugs remaining.** Independent trace of the table-build
confirmed:
- Reflected Castagnoli table is mathematically correct (`T[1]=0xF26B8303`,
  `T[255]=0xAD7D5351`, validated against public references).
- `crc32c()` uses an LSB-first table walk consistent with the LSB-first
  table build. Seed `0xFFFFFFFF`, final XOR `0xFFFFFFFF` — standard.
- `verify_superblock_crc` and `patch_superblock` both hash
  `block[0x20:0x1000]` (4064 bytes), matching the disassembled kernel
  `rsi += 0x20; edx = 0xFE0`.
- All five regression-test vectors are canonical (cross-checked against
  manual reflected impl).
- No other CRC implementation in the repo needs the same fix; the inline
  variant in `scripts/repro/make_synth_btrfs.sh` was already using the
  reflected form.

**Test gaps (addressed):**
- Round-trip test: `patch_superblock → verify_superblock_crc` on a
  synthetic 4 KiB SB.
- Table-structure pins: `T[0]`, `T[1]`, `T[255]`, `len(table)`.
- Volunteer-SB tests remain (skipped on machines without the local dump
  path; pass locally).

**Test gaps (acknowledged but not closed):**
- Cross-impl check between `patch_btrfs_ugos.crc32c` and
  `make_synth_btrfs.sh`'s inline crc32c. The shell→Python bridge is
  awkward in Python's `unittest`; deferred unless we see real
  divergence.
- Length-sensitivity test (feeding 4063/4064/4065 bytes). The round-trip
  test plus the disassembly-based comment cover this in practice.

### Lens 3 — disclosure

**Addressed:**
- `PRD_BUGS_BTRFS_PATCH.md` updated with BUG-016 as the highest-severity
  entry in the file.
- `README.md`: removed "100% safe" and "Zero-Risk" overclaims; added a
  one-line acknowledgement of the bug class with a forward reference
  to BUG-016. Kept the practical guidance (run `--check` first, COW
  snapshot before commit).
- This PRD memorialises the audit trail.
- The fix, tests, and docs ship in one logical commit so anyone reading
  history sees the full picture.
- Issue #1 will receive an update post-commit (separately, since that's
  a write-to-shared-state action).

**Not addressed (deliberately):**
- No version/freshness check in `patch_btrfs_ugos.py` itself. The audit
  suggested warning users on stale checkouts via a commit-SHA assertion;
  that's a new feature, not a fix, and would couple the script to git
  semantics it doesn't otherwise rely on. The README banner + BUG-016
  entry are the right disclosure surface.

## Hardening summary (what's different now)

| Before                                                       | After                                                                              |
|--------------------------------------------------------------|------------------------------------------------------------------------------------|
| Patcher could write to a mounted-rw device                   | Refused unless `--allow-mounted`; clear error path                                 |
| Wrote SB, trusted the OS to land it                          | Reads back, re-verifies CRC + flag-cleared; aborts on mismatch                     |
| `crc32c` table built with wrong polynomial form              | Reflected Castagnoli, pinned by 5 standard vectors + table-structure invariants    |
| No test for `patch → verify` agreement                       | Round-trip test on a synthetic 4 KiB block                                         |
| `make_synth_btrfs.sh` comment named wrong poly as "crc32c"   | Comment expanded with explicit warning + back-references                           |
| Backup filenames collided on same-second runs                | Nanosecond timestamp + PID                                                         |
| README claimed "100% safe" / "Zero-Risk"                     | Honest framing; defence-in-depth language; pointer to BUG-016                      |
| BUG-016 not in `PRD_BUGS_BTRFS_PATCH.md`                     | Top-severity entry with full postmortem                                            |
