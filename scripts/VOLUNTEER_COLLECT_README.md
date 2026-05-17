# `volunteer_collect.sh` — what it does, what it won't touch

This is a **read-only** collector. It exists because our patcher disagrees
with the live kernel on a superblock CRC, and we can't fix that
confidently until we can reproduce the disagreement on our own machines.
Your bundle gives us the material to do that — no more, no less.

## TL;DR

```bash
# 1. Dry run first — see exactly what would be captured. Nothing is written yet.
sudo ./scripts/volunteer_collect.sh

# 2. If the plan looks fine, capture for real:
sudo ./scripts/volunteer_collect.sh --confirm

# 3. The script ends with one line — that's your bundle:
#    Bundle: ./volunteer_bundle_<hash>_<UTC-date>.tar.gz  (NNN bytes)  sha256=…
```

Send us that file. That's it.

## What it captures

* `system/` — `uname`, `lsblk`, `blkid`, `mdadm`, `pvs/vgs/lvs`,
  `dmsetup`, `findmnt`, `dmesg` lines about btrfs/UGACL.
* `kernel/` — `/boot/vmlinuz`, `/boot/initrd.img` (and the A/B slot if
  present), plus a tarball of `/lib/modules/$(uname -r)`. This includes
  `btrfs.ko` and `ugacl_vfs.ko`, which is what we actually need to
  understand the on-disk format.
* `kernel/efi.tar.gz` — your EFI partition contents, so we can match the
  boot chain in a VM.
* `rootfs/*.sqfs` — the squashfs images mounted at `/rootfs/{base,kernel,apt,fw,oem}`.
  These are UGREEN-shipped layers (the OS itself); they do not contain
  your files. Plus `rootfs/factory.img.gz` (the small factory partition).
* `sb/` — for each BTRFS pool: full 64 KiB superblock regions at all
  three canonical mirror offsets, the first 1 MiB of the device (so we
  see partition/RAID/LVM headers in their natural context), and
  `btrfs inspect-internal dump-super -fa` output (ground truth for what
  CRC the kernel computes).
* `MANIFEST.txt` — sha256 + size + "why captured" rationale for every
  file in the bundle. You can read this yourself before sending.

## What it never captures

* Anything under `/volume*`, `/home`, `/overlay`, `/root` — **your data
  is off-limits.**
* `/etc/shadow`, ssh keys, network config with credentials.
* Full disk images. We only grab the small metadata regions and the
  vendor-shipped OS images.

The hard rules above are enforced in the script's code, not just in this
README. If you read `scripts/volunteer_collect.sh`, you'll see there is
no `--write`, `--patch`, `--fix`, or `--repair` flag, and no code path
that opens any block device with write intent.

You can verify this yourself before running anything:

```bash
# All matches will be in comments, in the flag-rejection list, or in the
# dry-run "will NEVER invoke" message — none are actual invocations.
# (Open the file at each line to confirm.)
grep -nE '\bmount\b|\bmkfs|dd\s+of=|--setrw|dmsetup\s+create|btrfstune|--repair' \
     scripts/volunteer_collect.sh
```

The dry-run itself lists every tool the script *will* invoke and every
tool it *will not* invoke — read that list before you confirm.

## Sanitisation

Before bundling, the script scrubs text files:

* Your hostname → `VOLUNTEER`
* MAC addresses → `aa:bb:cc:dd:ee:ff`
* Public IPv4 addresses → `203.0.113.1` (RFC1918 / loopback / link-local
  are kept — useful for reconstructing your dm-mapper stack, and they
  aren't routable anyway)
* Disk serials and WWNs → `SERIAL_REDACTED` / `WWN_REDACTED`
* UUIDs are kept (we need them to reconstruct your block topology in a
  VM; they're not personally identifiable)

Binary blobs (kernel, modules, squashfs, superblock dumps) are vendor
content or block-device content — not personal data — and are passed
through as-is. If you want to be extra careful, `tar tzf bundle.tar.gz`
will list everything inside, and `MANIFEST.txt` explains why each piece
is there.

## Size

The bundle is small — it contains OS metadata and vendor-shipped OS
images, **not your files**. Typical size is **200 MiB to 1.5 GiB**. The
default cap is 2 GiB; if your UGOS install ships unusually large
squashfs layers you'll get a clear error and a hint to raise the cap
with `--allow-large=4` (up to a 20 GiB hard ceiling).

The script also refuses to write the bundle anywhere under `/volume*`,
`/home`, `/overlay`, `/rootfs`, `/mnt/factory`, `/root`, or `/var/lib`
— bundles never land inside a volunteer-data filesystem.

## Flags

| Flag                  | What it does                                                                              |
|-----------------------|-------------------------------------------------------------------------------------------|
| (no flags)            | Dry run. Prints the plan and exits without capturing anything.                            |
| `--confirm`           | Actually capture.                                                                         |
| `--allow-mounted`     | Acknowledge that pools are mounted read-write (we still only do reads).                   |
| `--allow-large=N`     | Raise the size cap to N GiB.                                                              |
| `--out-dir DIR`       | Write the bundle to DIR instead of the current directory.                                 |
| `--pool /dev/...`     | Restrict capture to a specific pool. Can be repeated.                                     |
| `--include-config`    | Also capture `/etc/ugreen`, `/etc/ugos` (small text trees). Off by default.               |
| `--help`              | Show the embedded header from the script.                                                 |

Anything that sounds like a write flag (`--write`, `--patch`, `--fix`,
`--repair`, `--apply`, `--commit`) is explicitly refused with a hint
pointing to `recover_btrfs.sh` — which is a different script and a
different conversation. Don't run that one without us.

## After you send the bundle

You're done. You can still safely run `patch_btrfs_ugos.py --check` or
`--dump` (both read-only) any time you like. Real-disk writes are
currently locked down in this release — even `recover_btrfs.sh` only
performs a COW-snapshot dry-run and stops there. See
`PRD_BUGS_BTRFS_PATCH.md` §3 for the policy.

We'll reproduce the issue locally with what you sent, post a fix, and
come back to you with a clear go-ahead if a real-disk patch ever
becomes the right move.

## If something goes wrong

* Tool missing → the script tells you which `apt-get install` line to
  run.
* Out of space in `--out-dir` → it tells you the cap vs the estimate.
* Module tree missing → it logs that and continues with what it has.
* You answered "no" / Ctrl-C → no partial files are left on disk.

If you hit anything else, copy-paste the failure into the GitHub issue
and we'll sort it out.
