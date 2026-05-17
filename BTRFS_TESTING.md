# BTRFS Recovery Tool — Volunteer Testing Guide

> **⚠️ CRITICAL SAFETY RULE:** Under no circumstances should you run the patching tool directly against your real disk during this test phase. All testing must be **read-only** or use the provided COW-snapshot safety wrapper. Your data is irreplaceable.

---

## What We Need From You

We need a volunteer with a UGREEN NAS device formatted with **BTRFS** (not ext4) who can run a series of safe, non-destructive commands and share the output. **One complete run is enough** — if you capture everything listed below, we will not need to ask you to run anything again.

Either environment works:
- **UGREEN OS** (the stock proprietary firmware) — the kernel will mount the volume natively, which gives us extra signal.
- **Vanilla Linux** (Debian, Ubuntu, TrueNAS SCALE, etc., booted from USB or installed) — the kernel will refuse to mount the volume, which is exactly the failure mode we are fixing.

---

## TL;DR — The One-Shot Validator

If you just want the fastest, safest path, run the auto-validator. It is **100% read-only**, detects whether you are on UGOS or vanilla Linux, finds your volume, runs every safe check, and bundles everything into a single tarball you can send us.

```bash
sudo ./scripts/volunteer_validate.sh
# or, with an explicit device:
sudo ./scripts/volunteer_validate.sh /dev/mapper/ug_…
```

Output: `btrfs_volunteer_report_<timestamp>.tar.gz` in the repo root. Attach that file to your issue and you are done.

The remaining sections (Steps 0–5) explain what the validator is doing under the hood, and how to run each step manually if you prefer.

---

## Step 0: Prerequisites

1. A standard Linux distribution booted on your NAS (TrueNAS, Unraid, Debian, Ubuntu, etc.).
2. Root/sudo access.
3. Your UGREEN OS BTRFS volume assembled at the block layer (e.g., `/dev/mapper/ug_*_pool*-volume1`). It should exist as a block device even if it refuses to mount.
4. Python 3 installed (`python3 --version`).
5. `dmsetup`, `losetup`, and standard mount tools available.

---

## Step 1: Clone the Repository

```bash
cd ~
git clone -b feature/btrfs-support <this-repo-url> ugreen_btrfs_test
cd ugreen_btrfs_test
```

---

## Step 2: Identify Your Target Device

List your block devices and find the UGREEN BTRFS volume:

```bash
ls -la /dev/mapper/ug_* 2>/dev/null || echo "No /dev/mapper/ug_* devices found"
lsblk -f
sudo blkid | grep -i btrfs
```

**Copy the full path** of your BTRFS volume (e.g., `/dev/mapper/ug_A5AEB6_1767706191_pool1-volume1`). We will refer to this as `<TARGET>` below.

**Do NOT substitute `<TARGET>` literally — always use your actual device path.**

---

## Step 3: Read-Only Pre-Flight Checks (100% Safe)

These commands only **read** from your disk. They will never modify anything.

Run each command and **save the complete output** to a text file.

### 3.1 Verify the volume is assembled

```bash
sudo file -s <TARGET>
sudo blkid <TARGET>
```

### 3.2 Capture kernel rejection messages

If you have already tried (and failed) to mount the volume, the kernel log contains the exact error:

```bash
sudo dmesg | grep -i btrfs | tail -n 50
```

If the volume is not mounted, try a read-only mount attempt to trigger the error:

```bash
sudo mkdir -p /mnt/ugreen_test_mount
sudo mount -o ro <TARGET> /mnt/ugreen_test_mount 2>&1 || true
sudo dmesg | grep -i btrfs | tail -n 20
```

### 3.3 Run the Python tool in `--check` mode (read-only)

```bash
sudo ./scripts/patch_btrfs_ugos.py --check <TARGET>
```

**Expected success output (fresh UGREEN volume):**
```
Found N valid BTRFS superblock mirror(s):
  - 0x00010000 (65536 bytes, 64.0 KiB)
  ...
Check passed: all mirrors need patching and are structurally valid.
  - CRC32C checksums verified
  - bytenr matches physical offset
  - csum_type = CRC32C (0)
  - UGREEN proprietary flag (0x4000000000000000) is present
```

**Exit codes you may see:**

| Code | Meaning | What to do |
|---|---|---|
| 0 | All mirrors valid and need patching, OR all mirrors already clean (read the stdout to tell them apart) | Proceed |
| 1 | Validation error — CRC mismatch, bytenr mismatch, or unsupported csum_type | **Stop.** Send the output. |
| 2 | Mixed state — some mirrors patched, some not (a previous run was interrupted) | Resume is possible; send the output before retrying |

If you see **errors** (exit 1, e.g., "CRC mismatch", "bytenr mismatch", "unsupported csum_type"), **stop immediately** and send us the output. Do not proceed.

### 3.4 Dump superblocks for offline analysis (read-only)

```bash
sudo ./scripts/patch_btrfs_ugos.py --dump <TARGET>
```

This creates timestamped `btrfs_sb_backup_<device>_offset_<hex>_<timestamp>.bin` files. By default they are written to the current directory. You can redirect them elsewhere with `--backup-dir`:

```bash
sudo ./scripts/patch_btrfs_ugos.py --dump --backup-dir /mnt/safe-disk/backups <TARGET>
```

These are exact 4 KiB copies of each superblock mirror. **Keep these files** — they are your insurance policy.

List them:

```bash
ls -la btrfs_sb_backup_*.bin
sha256sum btrfs_sb_backup_*.bin
```

### 3.5 Inspect superblock flags with xxd/hexdump (optional but helpful)

```bash
xxd -l 256 -g 1 btrfs_sb_backup_<device>_offset_00010000_*.bin | head -20
```

Or inspect the incompat_flags field directly (offset 0xBC = 188 decimal):

```bash
python3 -c "
import sys
with open(sys.argv[1], 'rb') as f:
    f.seek(0xBC)
    flags = int.from_bytes(f.read(8), 'little')
    print(f'incompat_flags = 0x{flags:016X}')
    ugreen = 0x4000000000000000
    print(f'UGREEN bit (0x{ugreen:016X}) set: {bool(flags & ugreen)}')
" btrfs_sb_backup_<device>_offset_00010000_*.bin
```

---

## Step 4: COW Snapshot Test (Still 100% Safe)

This step tests the actual patching logic, but **all writes are trapped in a temporary RAM/disk file**. Your original volume is never modified.

### 4.1 Run the safety wrapper

```bash
sudo ./scripts/recover_btrfs.sh <TARGET>
```

The script will:
1. Verify the UGREEN flag exists (read-only).
2. Create a dm-snapshot COW overlay.
3. Patch the **snapshot only**.
4. Mount the patched snapshot for you to inspect.
5. Tear down the snapshot (destroying all test writes).

### 4.2 During the mounted phase

When the script pauses with the message:

```
SUCCESS! The patched volume is mounted at: /mnt/recovery_btrfs_test_...
```

Open a **second terminal** and verify your data:

```bash
# List the root of the mounted test volume
ls -la /mnt/recovery_btrfs_test_*/

# Check a few files
head -c 100 /mnt/recovery_btrfs_test_*/some-file-you-recognize

# Optional: verify file hashes against a known backup
# sha256sum /mnt/recovery_btrfs_test_*/path/to/important/file
```

Press `[Enter]` in the first terminal when you are satisfied.

### 4.3 After teardown

The script will print:

```
==========================================================
 Validation Complete — and we stop here, on purpose.
==========================================================
```

…and exit. **There is no longer a "permanently patch?" prompt.** The
real-disk write path is currently locked down in this release (see
`PRD_BUGS_BTRFS_PATCH.md` §3 — "Real-disk-write lockdown"). The COW
snapshot proved the patcher logic works on your data; that's the only
question we wanted to answer for this round. Your real disk
(`$TARGET_DEV`) was never touched.

---

## Step 5: Gather ALL Logs (This Is the Most Important Step)

> **Shortcut:** If you used `volunteer_validate.sh` in the TL;DR section, you can skip this step — the validator already produced `btrfs_volunteer_report_<timestamp>.tar.gz` with everything below included. The manual recipe is kept here for transparency and for people who ran the steps by hand.

We need everything in one place. Run the following commands and **copy the entire output into a text file** (or redirect with `>`):

```bash
# Create a single report file
REPORT="btrfs_test_report_$(date +%Y%m%d_%H%M%S).txt"
exec > >(tee -a "$REPORT") 2>&1

echo "===== UGREEN BTRFS Test Report ====="
echo "Date: $(date)"
echo "Host: $(hostname)"
echo "Kernel: $(uname -a)"
echo "Python: $(python3 --version)"
echo ""

echo "===== Target Device ====="
ls -la <TARGET>
file -s <TARGET>
blkid <TARGET>
echo ""

echo "===== BTRFS Kernel Messages ====="
dmesg | grep -i btrfs | tail -n 50
echo ""

echo "===== Python Tool --check Output ====="
./scripts/patch_btrfs_ugos.py --check <TARGET>
echo ""

echo "===== Python Tool --dump Output ====="
./scripts/patch_btrfs_ugos.py --dump --backup-dir /tmp/btrfs_backups <TARGET>
echo ""

echo "===== Backup Files ====="
ls -la /tmp/btrfs_backups/btrfs_sb_backup_*.bin
sha256sum /tmp/btrfs_backups/btrfs_sb_backup_*.bin
echo ""

echo "===== recover_btrfs.sh COW Test Output ====="
echo "(If you ran the COW test, paste its full output here)"
echo ""

echo "===== System Info ====="
lsblk -f
cat /proc/version
echo ""

echo "===== End of Report ====="
```

**Attach `btrfs_test_report_*.txt` and the `btrfs_sb_backup_*.bin` files** to your report.

---

## What NOT To Do

| ❌ Never Do This | Why |
|---|---|
| `sudo ./scripts/patch_btrfs_ugos.py /dev/mapper/ug_...` (without `--check` or `--dump` first) | Currently locked down — the script refuses real-block-device writes (exit 3) and points you here. Use `--check` instead. |
| Type `y` at the permanent patch prompt in `recover_btrfs.sh` | No such prompt exists anymore. The wrapper stops after the COW test. |
| Delete the `btrfs_sb_backup_*.bin` files | These are your rollback insurance. |
| Run any `dd` restore command unless you know exactly what you are doing | Restoring the wrong block to the wrong offset corrupts the superblock. |
| Back up to the same disk being patched | If the patch goes wrong, the backup is on the same failed disk. Always use `--backup-dir` on a different physical device. |

---

## Troubleshooting

### "no valid BTRFS superblocks found"
- Make sure `<TARGET>` is the actual filesystem volume, not the raw RAID device or a partition.
- Try `lsblk -f` and `blkid` to confirm the device has a BTRFS signature.

### "bytenr mismatch"
- This means the tool found a BTRFS magic signature but the `bytenr` field does not match the physical offset.
- This could indicate RAID misassembly, misalignment, or a bug in our offset constants.
- **Stop immediately** and send us the output.

### "unsupported csum_type"
- Your volume uses a checksum algorithm other than CRC32C (e.g., xxhash, sha256, blake2b).
- The current tool only supports CRC32C. We will need to extend it.
- **Stop immediately** and send us the output.

### `--check` exits with code 2
- Exit code 2 means a **mixed state**: some mirrors already have the UGREEN flag cleared (possibly from a previous interrupted run) and others still need patching.
- This is expected if a prior patch was interrupted. You can safely resume by running the patcher again — it will skip already-clean mirrors and patch only the remaining ones.

### COW snapshot mount fails after patching
- The kernel may still be rejecting the filesystem for a reason other than the incompat flag.
- Check `dmesg | tail -n 30` for the exact error.
- This is valuable data — send it to us.

---

## Crash Safety

If the patcher is killed by SIGKILL or the system loses power between writing mirror *N* and mirror *N+1*, you may end up with a **partially patched** state: some superblock mirrors have the UGREEN flag cleared while others still have it set.

### Is this dangerous?

Usually **no**. The BTRFS kernel driver scans all mirrors and selects the one with the newest `generation` number. Since our patcher does not modify `generation`, all mirrors at identical generations are equally valid from the driver's perspective. If it picks a patched mirror, the volume mounts cleanly. If it picks an unpatched mirror, it fails with the same "unsupported feature" error as before.

### How to recover from a partial patch

Simply re-run the patcher. It will:
1. Detect which mirrors are already clean.
2. Skip those mirrors.
3. Patch only the remaining mirrors.

You can verify the current state anytime with:

```bash
sudo ./scripts/patch_btrfs_ugos.py --check <TARGET>
```

- Exit code **0** = all mirrors are clean (nothing to do).
- Exit code **2** = mixed state (resume needed).
- Exit code **1** = error (CRC mismatch, bytenr mismatch, etc.).

---

## How to Submit Your Results

1. Run all steps above.
2. Compress the report and backup files:
   ```bash
   tar czvf btrfs_test_results.tar.gz btrfs_test_report_*.txt btrfs_sb_backup_*.bin
   ```
3. Open an issue in this repository and attach `btrfs_test_results.tar.gz`.
4. Include any additional observations (e.g., "mount succeeded but dmesg shows warnings").

---

## Fixture Testing (For Developers / Advanced Users)

If you want to verify the tool's behavior against synthetic test fixtures before running it on real hardware, create a loopback image and manipulate it:

```bash
# Create a 100 MiB test image
truncate -s 100M /tmp/test_btrfs.img
# Create a BTRFS filesystem on it
mkfs.btrfs /tmp/test_btrfs.img
# Set the UGREEN flag manually (requires python or xxd)
python3 -c "
import struct
with open('/tmp/test_btrfs.img', 'r+b') as f:
    for off in [0x10000, 0x4000000]:
        f.seek(off + 0xBC)
        flags = struct.unpack('<Q', f.read(8))[0]
        flags |= 0x4000000000000000
        f.seek(off + 0xBC)
        f.write(struct.pack('<Q', flags))
        # Recalculate CRC (simplified — full script does this properly)
"
```

Then test the tool's exit codes:

| Fixture | Command | Expected Exit Code |
|---|---|---|
| Clean UGREEN volume | `--check` | **0** |
| Corrupt CRC (flip one bit in superblock body) | `--check` | **1** |
| Partially patched (clear flag on mirror 0 only) | `--check` | **2** |
| All mirrors already clean | `--check` | **0** (with "Nothing to patch" message) |

These fixtures give you confidence in the tool's safety logic without risking real data.

---

Thank you for volunteering! Your careful testing helps make this tool safe for everyone.
