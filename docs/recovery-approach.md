---
title: Recovery Approach
tags: [ugos, recovery, cow, dm-snapshot, methodology]
created: 2026-05-17
---

# Recovery Approach

This project has two recovery flows that share a single design
principle: **never test on real data**. Both use Linux Device Mapper
(`dmsetup`) to build a Copy-on-Write overlay above the user's volume,
apply the patch to the overlay, mount and verify there, and only then
(if at all) commit to the physical disk.

## The COW-snapshot pattern

```
        ┌──────────────┐                ┌──────────────┐
        │ /dev/mapper/ │                │ /dev/mapper/ │
        │ ugreen_pool  │                │   cow_test   │
        │   (real)     │ ── reads ───>  │  (snapshot)  │
        └──────────────┘                └──────────────┘
              ▲                                ▲
              │ unchanged                      │
              │                                │ writes (the patch)
              │                                │       │
              │                                │       ▼
              │                          ┌──────────────┐
              │                          │  /var/tmp/   │
              │                          │   cow.img    │
              │                          │ (loop file)  │
              │                          └──────────────┘
```

We run `dmsetup create` with target type `snapshot`, configured
non-persistent (the `N` parameter). Reads pull from the real device;
writes land in a sparse 1–4 GiB image file on `/var/tmp`. When the
test ends, we tear down the dm-mapper device and delete the COW
image. The real device's bytes were never modified, period.

If the patch works on the snapshot, the patched filesystem mounts
cleanly under the test kernel. The volunteer (or maintainer) can
`ls`, `cat`, `sha256sum`, walk the directory tree, prove their files
are intact. *Only then* — and on the ext4 path, only after retyping
the device basename and clearing several other gates — does the
script commit the same patch to the real device. On the btrfs path
we currently do not commit at all (see [[bug-postmortems#bug-016]]
for why).

## Why we never `umount` and then patch in place

`tune2fs -O ^flag` and our btrfs patcher both write to the
filesystem's superblock. If the kernel is still using the device for
*anything* — mount, swap, an LVM PV that's been activated — the write
races against the kernel's own SB state and may produce inconsistent
on-disk structure. The COW approach is bulletproof because the kernel
never sees the changes; they happen in a sandbox.

The two recovery scripts both also widen their pre-write checks to
catch:

- An active mount (`findmnt`)
- A swap (`swapon --show`)
- Stacked dm/md/LVM holders (`/sys/block/<dev>/holders/`)

If any of those find the device in use, the script aborts before
writing.

## ext4 vs btrfs recovery paths

| Step                           | ext4 (`recover.sh`)                                 | btrfs (`recover_btrfs.sh`)                  |
|--------------------------------|-----------------------------------------------------|---------------------------------------------|
| Pre-flight read-only check     | `tune2fs -l` (looks for `ugreen_proprietary`)        | `patch_btrfs_ugos.py --check`               |
| COW snapshot creation          | `dmsetup create … snapshot`                          | `dmsetup create … snapshot`                 |
| Patch the snapshot             | `tune2fs -O ^ugreen_proprietary`                     | `patch_btrfs_ugos.py --yes`                 |
| Verify under test kernel       | `e2fsck -fn`                                         | mount read-only, then mount rw              |
| Final real-disk commit step    | Yes (with retype-device-name confirm + SB backup)    | **None** — currently locked down            |
| Why                            | Mature path, delegates to upstream `tune2fs`         | Patcher is new; lockdown until volunteer-validated |

See [[bug-postmortems]] for the background on the btrfs lockdown.

## Reversibility and round-trip

> A redditor asked: "can I mount the converted ext4 / btrfs back onto
> UGOS?" Short answer for both: **probably yes, but neither has been
> tested by this project, and you should never test on your only copy.**

### ext4 round-trip

Clearing `ugreen_proprietary` strips bit `0x20000000` from
`s_feature_incompat` and updates the SB checksum. No other on-disk
state changes:

- File contents: untouched.
- Inode metadata: untouched.
- Posix ACLs (if any) in `system.posix_acl_*` xattrs: untouched.

UGOS's kernel is a Linux kernel reading a now-completely-vanilla ext4
filesystem. Functionally it should mount fine — UGOS doesn't *require*
the flag to be present (that would be a UGOS bug; you can't require a
feature that's optional in the formal contract).

What we don't know for certain:

- Whether the UGREEN web UI or some UGOS startup script does a
  "this isn't a UGOS volume" check on the SB flag and refuses to
  attach the volume to its storage manager. That would be a
  policy decision, not a technical one, but we haven't observed
  it either way.
- Whether UGOS re-sets the bit silently on first mount (which
  would be transparent to the user — your data is fine, it's
  just "re-locked" — but defeats the purpose of having stripped
  it).

### btrfs round-trip

More nuanced. Clearing bit 62 strips the "this FS uses UGACL"
signal, but the **UGACL xattrs on individual files
(`system.ugacl_self`, `trusted.ugacl_*`) remain on disk**. They are
inert under a mainline kernel — see [[ugacl-system]] — but they
are real bytes UGOS knows how to interpret.

Three plausible UGOS behaviors on re-mount, in order of likelihood:

1. **UGOS reads the orphaned xattrs and seamlessly re-engages
   UGACL.** Most likely. The xattrs encode the same information UGACL
   would have written; UGOS's `btrfs.ko` calls
   `request_module ugacl_vfs`, the module loads, and from UGOS's
   perspective everything works. It may even silently re-set bit 62
   and recompute the CRC. Your data is fine.
2. **UGOS refuses to mount because bit 62 is missing.** Unlikely —
   the kernel would not normally refuse a btrfs FS just because an
   incompat bit it understands is absent. But UGOS could implement
   this as a deliberate policy check in userspace.
3. **UGOS mounts and tries to re-derive UGACL state from the
   xattrs, but doesn't find what it expects (because we cleared
   the SB version field along with the bit) and either re-initializes
   UGACL or logs a confused warning.** This is what would happen
   if our patcher cleared more than just bit 62 — we don't, but the
   risk of orphaned-state mismatch is non-zero.

The honest project status: **we have not tested UGOS round-trip.** We
recommend strongly that anyone wanting to do this:

1. Image the disk to a separate device first (`dd` to a USB-attached
   spare).
2. Patch the copy.
3. Verify the copy mounts and reads correctly under mainline.
4. *Then* try mounting the copy under UGOS to see what happens.

If you do this, please open an issue with what you observed — that's
exactly the kind of evidence that lifts the btrfs lockdown criteria
in `PRD_BUGS_BTRFS_PATCH.md` §3.

## Why "permanently patch" was deliberately disabled on btrfs

We found a CRC bug in our patcher that would have corrupted any
volunteer's filesystem the moment they progressed past the COW test
and committed to disk. The fix is in tree; tests pin it. But we
realized that the cost of being wrong about a write to a volunteer's
NAS is **the volunteer's NAS**, and that lift criterion belongs to
the volunteer, not to us. So `recover_btrfs.sh` stops after the COW
dry-run. See [[bug-postmortems#bug-016]].

## Related

- [[ext4-modification]] — what we strip
- [[btrfs-modification]] — what we strip (and what we leave behind)
- [[ugacl-system]] — why btrfs round-trip is more interesting than ext4
- [[bug-postmortems]] — why the btrfs path is locked down
