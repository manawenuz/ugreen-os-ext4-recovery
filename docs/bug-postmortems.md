---
title: Bug Postmortems
tags: [postmortem, bug, crc32c, cow, lockdown, btrfs, ext4]
created: 2026-05-17
---

# Bug Postmortems

This page collects the two most significant defects this project has
found in its own code, and what we changed in response. The
authoritative bug logs are `PRD_BUGS_BTRFS_PATCH.md` and
`PRD_BUGS_EXT4_PATCH.md` in the repository root; this page is the
human-readable narrative.

## BUG-016 — wrong crc32c polynomial form (btrfs)

> [!danger]
> Latent disk-corruption defect. Would have corrupted any volunteer's
> btrfs filesystem the moment they progressed past `--check` and
> committed to disk. Caught and fixed before reaching the wild.

### What it was

`scripts/patch_btrfs_ugos.py` built its crc32c lookup table with the
**forward** Castagnoli polynomial constant `0x1EDC6F41` inside a
**LSB-first (right-shift)** table-building loop. That combination is
mathematically inconsistent: the LSB-first loop requires the
**reflected** polynomial constant `0x82F63B78`.

The mistake is subtle. Cursory inspection sees:

- Castagnoli — correct algorithm family for btrfs (`csum_type = 0`).
- 0x1EDC6F41 — this *is* a Castagnoli constant; if you Google the
  polynomial, this is the value you'll find first.
- Loop body and final XOR look fine.

But the loop is LSB-first, which mathematically pairs only with the
reflected form. The resulting CRC routine produced values that
agreed with crc32c on the all-zero input (both give `0x8A9136AA` on
32 zeros, since the LFSR state is symmetric), and occasionally on
other small inputs. It disagreed on the all-ones input, on the
RFC 3720 test vector `"123456789"` (expected `0xE3069283`, we
returned `0xF28417BE`), and on essentially every real superblock
the kernel had written.

### How it would have manifested

A volunteer running `patch_btrfs_ugos.py --check /dev/...`:

```
ERROR: CRC mismatch at mirror 0x00010000 (stored=0x..., computed=0x...)
ERROR: CRC mismatch at mirror 0x04000000 (stored=0x..., computed=0x...)
ERROR: CRC mismatch at mirror 0x4000000000 (stored=0x..., computed=0x...)
```

…on a perfectly healthy filesystem.

Read in conjunction with `volunteer_validate.sh`'s output, this
*looked* like the volunteer's NAS had three corrupted superblocks and
the recovery should not proceed. The volunteer was told to send their
bundle to the maintainers. The actual recovery script
(`recover_btrfs.sh`) would have refused to write anything until the
volunteer typed `y` at the final prompt — which the validator told
them not to do.

Had they typed `y`: `recover_btrfs.sh` would have invoked the
patcher's *write* path, which clears the UGREEN bit, recomputes CRC
(with the broken routine), and writes the SB back. The newly-written
SB's stored CRC would be the wrong value our routine produces; the
kernel would refuse to mount the volume with `BTRFS error: bad
checksum on tree block`. Three mirrors, all corrupted. Backups
exist on disk (we save them before patching), so manual restore
would be possible, but no automated rollback.

### How it was caught

1. Issue #1: a volunteer ran the read-only validator and the patcher
   reported three-mirror CRC mismatch. We didn't know yet whether
   that was a real filesystem problem, a UGREEN-specific superblock
   layout we hadn't modeled, or a bug in our code.
2. Static analysis of the captured `btrfs.ko` (see
   [[static-analysis-toolkit]]) showed the kernel's
   `btrfs_check_super_csum` hashes the *mainline* range
   `[0x20 .. 0x1000)` — no UGACL-induced byte-range shift. That
   ruled out our working hypothesis.
3. Standard RFC 3720 test vectors then exposed our routine
   immediately.
4. With the polynomial fix in place, our computed CRC matches the
   byte stored in the volunteer's on-disk csum field on all three
   captured mirrors.

The full investigation took about a day and is memorialized in
`PRD_AUDIT_PATCHER_CRC_FIX.md`.

### The fix

One constant: `_build_crc32c_table` now uses `0x82F63B78`.

The accompanying hardening matters more than the fix itself:

- `tests/test_crc32c.py` pins 5 standard RFC 3720 / iSCSI vectors plus
  the table-structure invariants (`T[0]=0`, `T[1]=0xF26B8303`,
  `T[255]=0xAD7D5351`) plus a `patch_superblock → verify_superblock_crc`
  round-trip on a synthetic 4 KiB block. A future regression of the
  polynomial form fails the unit tests immediately.
- `patch_btrfs_ugos.py` now refuses to write to a mounted-rw device
  unless `--allow-mounted` is passed (mirrors the volunteer collector's
  gate, so the patcher isn't single-tripwire on `recover_btrfs.sh`).
- Every post-write step now reads the SB back from disk and asserts
  `(CRC valid) ∧ (UGREEN bit cleared)`. Future similar bugs cannot
  land silently — the patcher will detect the divergence between
  in-memory state and on-disk state at write-time, while backups are
  still warm.

### The lockdown that followed

The bug taught us that "looks correct in code review" is not a
strong-enough signal for tools that write to volunteer disks. So we
applied a deliberate **real-disk-write lockdown**:

- `patch_btrfs_ugos.py` classifies its target (`file`, `loop`,
  `snapshot`, `real`) and refuses real targets unless an undocumented
  maintainer-approval flag is passed.
- `recover_btrfs.sh` no longer commits to the real disk. It runs the
  COW dry-run and stops.

Lift criteria (in `PRD_BUGS_BTRFS_PATCH.md` §3): a volunteer bundle
processed end-to-end through the local repro harness; agreement
between our patcher and `btrfs-progs dump-super` on a synthetic
UGACL FS; volunteer-verified file integrity on a COW mount; explicit
maintainer PR to lift.

---

## BUG-EXT4-001 — inverted `$COW_DIR` logic (ext4)

> [!note]
> Volunteer-availability bug, not a data-loss bug. The real disk was
> never at risk; the failure mode is the COW test aborts mid-flow on
> memory-constrained systems.

### What it was

`scripts/recover.sh` lines 36–41 selected the COW image location
inversely to the obvious intent. The code, paraphrased:

```bash
COW_DIR=${COW_DIR:-/var/tmp}     # default: /var/tmp (safe, off tmpfs)
if /tmp is tmpfs; then
    COW_DIR=/tmp                  # ← inverted: use the *tmpfs*
fi
```

The intent — "keep the 1 GiB COW off tmpfs so memory-constrained
NASes don't OOM" — was correctly implemented in the btrfs sibling
`recover_btrfs.sh` after BUG-011, but the same fix was never applied
to the ext4 cousin.

### How it would have manifested

A volunteer with `/tmp` on tmpfs (default on many distros) and modest
RAM would have run `recover.sh`, watched the 1 GiB COW image consume
RAM during the test, and either had the dm-snapshot invalidate
mid-flow or had the kernel start killing processes. Real disk was
untouched throughout.

### How it was caught

Three-lens audit of the ext4 toolchain after we landed the btrfs
lockdown. The safety reviewer noticed the inverted conditional
directly while comparing the two sibling scripts.

### The fix

Invert the conditional. `/var/tmp` when `/tmp` is tmpfs; `/tmp`
otherwise. Five lines of shell.

### The hardening that followed

Audit also found four should-fix items, all addressed in the same
commit:

- **EXT4-S1** — pinned `e2fsprogs v1.47.1` is now verified via
  `git verify-tag` in the build script. Ted Ts'o signs e2fsprogs
  release tags; we now validate that.
- **EXT4-S2** — COW-snapshot `e2fsck` exit code no longer swallowed.
  Non-zero refuses the real-disk write.
- **EXT4-S3** — mount/holder check widened (swap, LVM PV holders,
  stacked dm/md).
- **EXT4-S5** — primary SB is dd'd to a backup file before the
  real-disk write, with a one-liner rollback printed.
- Plus the confirmation prompt now requires retyping the device
  basename, not just `y`.

### The non-lockdown

Unlike the btrfs side, **the ext4 path was not locked down**. The
on-disk mutation is performed by upstream `tune2fs`, not by code we
wrote. The BUG-016 class — silently-wrong crypto in shipped code —
cannot recur. The audit-recommended floor for a tool that writes to
volunteer data was applied (verified supply chain, gated COW e2fsck,
widened mount check, SB backup, tightened confirmation prompt), but
the script can still commit to the real disk after the COW dry-run.

This asymmetry is documented in the project `README.md` so it reads
as a deliberate posture, not as an unspoken warning about ext4.

## Bug-class taxonomy (for future contributors)

The two bugs above illustrate the **two distinct failure modes** this
project has had to defend against:

| Class                          | Example     | Defense                                                            |
|--------------------------------|-------------|--------------------------------------------------------------------|
| Hand-rolled crypto wrong       | BUG-016     | Don't roll your own. Where we must, pin test vectors against RFC standards and disassemble the kernel's equivalent to verify byte ranges. |
| Inverted-intent shell logic    | BUG-EXT4-001 | Read sibling scripts to spot drift. Audit lens, not heroics.       |
| Real-disk write before validation | (averted) | COW snapshot pattern, mount/holder gates, post-write read-back     |
| Supply-chain trust unverified  | EXT4-S1     | `git verify-tag` against signed upstream releases                  |
| Silent error swallowing        | EXT4-S2     | Don't `|| true` on exit codes that gate destructive next steps     |

## Related

- [[ext4-modification]] — what BUG-EXT4-001 lived inside
- [[btrfs-modification]] — what BUG-016 lived inside
- [[static-analysis-toolkit]] — how BUG-016 was diagnosed
- [[recovery-approach]] — the COW pattern that gave both bugs a chance to be caught before reaching disk
