# Bug PRD: BTRFS Patching Critical Vulnerabilities

## 1. Overview
A series of critical defects have been identified in the BTRFS patching toolchain. These range from destructive offset errors to logic failures that would prevent successful restoration or mounting. This document serves as the authoritative list of bugs to be remediated before the tool is released.

## 2. Resolved Bugs

### BUG-001: Incorrect `OFF_INCOMPAT_FLAGS` (RESOLVED)
*   **Status:** FIXED. Offset updated to `0xBC`.
*   **Impact:** Destructive risk eliminated.

### BUG-002: Checksum Type Assumption (RESOLVED)
*   **Status:** FIXED. Tool now verifies `csum_type == 0` (CRC32C) before patching.

### BUG-003: Bytenr Validation Absence (RESOLVED)
*   **Status:** FIXED. Tool now verifies that the superblock's internal `bytenr` field matches its physical disk offset.

### BUG-004: Mirror Restore `bytenr` Mismatch (RESOLVED)
*   **Status:** FIXED. Backups are now per-mirror, and rollback instructions utilize the correct block for each physical slot.

### BUG-005: Backup Format Offset Prefix (RESOLVED)
*   **Status:** FIXED. Backups are now raw 4KiB blocks.

### BUG-006: Rollback Instruction Mismatch (RESOLVED)
*   **Status:** FIXED. Documentation now reflects raw binary restoration.

### BUG-007: Erroneous 1 PiB Mirror Offset (RESOLVED)
*   **Status:** FIXED. Non-standard mirror removed; list limited to 64KiB, 64MiB, and 256GiB.

### BUG-008: `dmsetup` Quoting Vulnerability (RESOLVED)
*   **Status:** FIXED. Shell script now uses hardened string passing for device paths.

### BUG-009: Misleading `OFF_BYTENR` Constant (RESOLVED)
*   **Status:** FIXED. Constants renamed to `OFF_BYTENR` (0x30) and `OFF_CSUM_DATA_START` (0x20).

## 3. Round 2 Audit Findings

### BUG-010: Missing Existing CRC Verification (RESOLVED)
*   **Status:** FIXED. Tool now verifies the existing superblock CRC before patching to avoid masking pre-existing bit rot or corruption.
*   **Impact:** Prevents masking pre-existing silent corruption with a freshly valid CRC.

### BUG-011: `COW_DIR` Logic Clashing (RESOLVED)
*   **Status:** FIXED. `recover_btrfs.sh` now respects user-provided `COW_DIR` and only applies tmpfs heuristics when the variable is unset.
*   **Impact:** User-exported `COW_DIR` is now always honored.

### BUG-012: Insecure Backup Location (RESOLVED)
*   **Status:** FIXED. Added `--backup-dir` argument and implemented a cross-device check to prevent writing backups to the same physical disk being mutated.
*   **Impact:** Eliminates the risk of writing the rollback artefact onto the device being mutated.

### BUG-013: Rigid Partial-Patch Abort (RESOLVED)
*   **Status:** FIXED. Tool now supports a "resume" state, allowing it to skip already-clean mirrors and patch only the remaining ones.
*   **Impact:** Interrupted runs can now be resumed safely.

### BUG-014: Crash Safety Documentation (RESOLVED)
*   **Status:** FIXED. `BTRFS_TESTING.md` now includes a comprehensive section on partial-patch behavior and recovery.
*   **Impact:** Operators now understand the risk and the remediation path.

### BUG-015: COW Snapshot Overrun (RESOLVED)
*   **Status:** FIXED. Default COW size bumped to 4GB, and verification mount now uses `noatime,nodiratime` to minimize write churn.
*   **Impact:** Long inspection sessions no longer risk COW exhaustion.

### BUG-016: Wrong `crc32c` Polynomial Form (RESOLVED — CRITICAL)
*   **Severity:** **Highest of any bug in this file.** Latent disk-corruption defect.
*   **Defect:** `_build_crc32c_table` in `scripts/patch_btrfs_ugos.py` used the FORWARD Castagnoli polynomial constant `0x1EDC6F41` in a LSB-first (right-shift) table-building loop. That combination is mathematically inconsistent: the LSB-first loop requires the REFLECTED form `0x82F63B78`. The result was a CRC routine that looked superficially like `crc32c` but disagreed with the kernel on every non-trivial input.
*   **Impact (would-have-been):** every invocation of the patcher's `--check` returned `CRC mismatch` against a perfectly healthy on-disk superblock. Any volunteer who had proceeded from `--check` to `recover_btrfs.sh` in write-mode would have **overwritten their valid superblocks with wrongly-computed CRCs**, corrupting their filesystem. The reason this never happened in the wild: `--check` always failed first, and the validator told the volunteer to stop. The volunteer in [issue #1](https://github.com/manawenuz/ugreen-os-ext4-recovery/issues/1) was the canonical false-positive; their NAS was healthy throughout.
*   **Affected versions:** all btrfs-patcher releases prior to the fix commit. `main` shipped this bug from the original `patch_btrfs_ugos.py` commit through `7af380f` inclusive.
*   **How it was found:** static analysis of the captured UGOS `btrfs.ko` via `pyelftools` + `capstone` confirmed the kernel hashes the mainline range `[sb+0x20 .. sb+0x1000)` — no UGACL-induced byte-range shift. That ruled out the working hypothesis (UGREEN's modifications) and pointed at our own implementation. Standard RFC 3720 test vectors then confirmed the patcher's `crc32c` disagrees with reference on `"123456789"` (expected `0xE3069283`, got `0xF28417BE`) and four other vectors.
*   **Fix:** single-line constant change in `_build_crc32c_table` from `0x1EDC6F41` → `0x82F63B78`. Verified against:
    - 5 RFC 3720 / standard test vectors,
    - 3 mirror dumps from the issue-#1 volunteer (computed CRC matches the byte stored in the on-disk csum field exactly),
    - direct disassembly of `btrfs_check_super_csum` (same range, same length).
*   **Hardening that landed with the fix:**
    - `tests/test_crc32c.py` pins 5 standard vectors + table-structure invariants (`T[0]=0`, `T[1]=0xF26B8303`, `T[255]=0xAD7D5351`) + a `patch_superblock → verify_superblock_crc` round-trip test on a synthetic 4 KiB SB. A future regression to the wrong polynomial form, or any desync between patch-side and verify-side, is caught at unit-test time.
    - `patch_btrfs_ugos.py` now refuses to write to a mounted-rw device unless `--allow-mounted` is passed. Mirrors the volunteer-collector's gate so the patcher isn't single-tripwire on `recover_btrfs.sh`.
    - Each post-write step now re-reads the SB from disk and asserts (CRC valid) ∧ (UGREEN bit cleared). Future similar bugs cannot land silently because the patcher will detect the divergence between in-memory state and on-disk state at write-time, while backups are still warm.
    - Backup filenames now include nanosecond timestamp + PID, eliminating sub-second collision.
*   **Audit memo:** `PRD_AUDIT_PATCHER_CRC_FIX.md`.
