---
title: UGREEN's ext4 Modification
tags: [ugos, ext4, vendor-lockin, incompat-flag]
created: 2026-05-17
---

# UGREEN's ext4 Modification

UGREEN OS sets **one bit** in the ext4 superblock's `s_feature_incompat`
field on every volume it creates: `0x20000000`. This bit is unallocated
upstream as of kernel 6.12, so a mainline kernel asked to mount the
volume responds:

```
EXT4-fs (dm-X): Couldn't mount because of unsupported optional features (20000000)
```

The kernel's refusal is **conservative and correct**: ext4 incompat
flags are by definition things the kernel must understand to safely
mount, so an unknown bit must abort. UGREEN exploits this contract to
ensure standard distros refuse the volume even though the on-disk
layout is otherwise vanilla.

## What the flag actually does

Empirically: **nothing observable on disk**. The flag is a marker, not
a feature. The patch comment in
`patches/0001-Recognize-ugreen_proprietary-incompat-feature.patch`
notes that filesystems "mount and read/write correctly under the
UGREEN OS kernel even when the proprietary ugacl module fails to
load." We've never observed a layout change, a custom journal format,
or any other on-disk artifact tied to bit `0x20000000`.

The contrast with btrfs (see [[btrfs-modification]]) is interesting:
on btrfs the flag accompanies a real subsystem (UGACL xattrs, see
[[ugacl-system]]). On ext4 the flag has no userland companion module
that we've identified; UGOS's `dmesg` does not log a corresponding
"Set ext4 UGACL" line on ext4 mounts.

## Where the bit lives in the superblock

ext4 superblock at offset 0 of the partition (with 1024-byte padding).
The relevant field is `s_feature_incompat` at byte offset `0x60`
relative to the SB start, 32 bits wide, little-endian.

```
struct ext4_super_block {
    ...
    __le32 s_feature_incompat;   /* offset 0x60 */
    ...
};
```

Bit `0x20000000` = bit 29 of `s_feature_incompat`. UGREEN named it
`ugacl` in their patched `e2fsprogs` (the userspace tool that reports
features). When mainline `tune2fs -l` encounters it, the symbolic name
is missing from its feature table, so it prints `FEATURE_I29`.

## How we recognize and strip it

The patch in `patches/0001-Recognize-ugreen_proprietary-incompat-feature.patch`
touches four locations in upstream e2fsprogs:

1. `lib/e2p/feature.c` — adds `ugreen_proprietary` to the
   `incompat_features[]` table so `tune2fs -l` prints the symbolic
   name instead of `FEATURE_I29`, and `-O ^ugreen_proprietary`
   parses.
2. `lib/ext2fs/ext2_fs.h` — adds the `#define
   EXT4_FEATURE_INCOMPAT_UGREEN_PROPRIETARY 0x20000000`.
3. `lib/ext2fs/ext2fs.h` — adds the bit to
   `EXT2_LIB_FEATURE_INCOMPAT_SUPP`, the mask of features libext2fs
   understands. Without this, every libext2fs consumer (tune2fs,
   e2fsck, debugfs, dumpe2fs, resize2fs, e2image, fuse2fs) would
   refuse the volume the same way the kernel does.
4. `misc/tune2fs.c` — adds the bit to `clear_ok_features[0]`, the
   whitelist of features `-O ^X` is allowed to clear. The bit is
   deliberately **not** added to the corresponding `set_ok_features`,
   so patched `tune2fs` can still strip the flag but cannot re-add
   it — and `mke2fs.c` is untouched, so `mkfs.ext4 -O
   ugreen_proprietary` is rejected.

Once patched, the recovery flow is:

```bash
tune2fs -O ^ugreen_proprietary /dev/mapper/<vol>
```

Upstream `tune2fs` then handles the actual SB rewrite, CRC32c
recalculation (because ext4 with `metadata_csum` enabled checksums
the SB), and propagation to all backup superblocks. We don't roll our
own crypto here — that's deliberate, see [[bug-postmortems#bug-016]]
for why.

## Why this is the safer of our two recovery paths

Compared to the btrfs side:

- **The on-disk mutation is upstream code.** Every distro ships
  `tune2fs`; the patch is four hunks that add one whitelist entry.
- **No hand-rolled CRC.** ext4's `metadata_csum` is computed inside
  libext2fs, the same code path every ext4 filesystem on Earth
  exercises every time it's modified.
- **The flag has no functional companion.** Clearing it does not
  strand userland-visible data the way btrfs's UGACL bit would
  (see [[ugacl-system]]).

For these reasons the ext4 recovery flow is the project's *mature
path* (the maintainer uses it on their own NAS). The btrfs flow is
substantially more complex and is currently locked down — see
[[bug-postmortems]] and [[recovery-approach]].

## Reversibility (round-trip to UGOS)

The on-disk artifact of clearing the flag is: bit `0x20000000`
becomes 0 in `s_feature_incompat`, and the SB checksum updates. That's
the entire change. **No file content is altered**, no inode flags
change, no xattrs are touched.

Whether a stripped ext4 volume re-mounts cleanly under UGOS is
discussed in [[recovery-approach#reversibility-and-round-trip]].
Short version: it should, because UGOS's kernel is a Linux kernel and
the volume is now a perfectly valid plain ext4 filesystem — but this
has not been independently tested by the project and the safe default
is to do it on a copy, not on the original.

## Related

- [[btrfs-modification]] — the much more involved sibling
- [[recovery-approach]] — the COW-snapshot test pattern
- [[bug-postmortems]] — what we got wrong and what we fixed
