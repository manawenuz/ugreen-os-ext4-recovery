---
title: UGREEN OS Architecture
tags: [ugos, architecture, kernel, squashfs, dm-mapper]
created: 2026-05-17
---

# UGREEN OS Architecture

UGREEN OS is **Debian 12 + a custom Linux 6.12 kernel + a stack of
squashfs read-only userland layers + UGREEN-authored kernel modules**.
It boots via EFI + GRUB + initramfs on a `Linux 6.12.30+` kernel that
identifies itself in `uname -r` with a `+` suffix (no UGREEN-specific
version string) and in module loads via messages like
`Set btrfs UGACL, version[1]` (see [[ugacl-system]]).

## On-disk layout (DXP6800 Pro, observed)

| Partition         | Filesystem  | Role                                 |
|-------------------|-------------|--------------------------------------|
| `nvme1n1p1`       | vfat        | `/boot` — EFI + kernel + initrd      |
| `nvme1n1p2`       | ext4        | `/rootfs` — root squashfs base       |
| `nvme1n1p3`       | ext4        | `/mnt/factory` — vendor factory data |
| `nvme1n1p4`       | ext4        | rootfs2 (A/B slot)                   |
| `nvme1n1p5`       | swap        | swap                                 |
| `nvme1n1p6`       | ext4        | `/ugreen` — UGREEN service files     |
| `nvme1n1p7`       | ext4        | `/overlay` — user data overlay       |
| `sd{a..e}2`       | linux_raid  | members of `md1` → pool1 (HDDs)      |
| `nvme0n1p2`       | linux_raid  | member of `md2` → pool2 (NVMe)       |

The 5+ HDDs combine into `md1`, which gets an LVM PV/VG/LV laid on top
(`/dev/mapper/ug_<hash>_<id>_pool1-volume1`). Pool2 likewise on NVMe.
The pool volumes are where user data lives, and they're what mainline
Linux refuses to mount because of the proprietary feature flags
described in [[ext4-modification]] and [[btrfs-modification]].

The dm-mapper naming convention is `ug_<6-hex>_<10-digit>_pool<N>-volume<N>`,
where the first hex chunk appears to be a chassis or board ID and the
10-digit number is a creation-time identifier.

## Squashfs userland layers

UGOS mounts five squashfs images as loopback at boot:

```
loop0 → /rootfs/base     (core userland)
loop1 → /rootfs/kernel   (kernel modules)
loop2 → /rootfs/apt      (apt-installable extras)
loop3 → /rootfs/fw       (firmware blobs)
loop4 → /rootfs/oem      (UGREEN-branded layer)
```

These are stacked by the initramfs into the active root. User data
lives separately on `/overlay`, `/home` (on pool2), and `/volume*` (on
pool1/pool2). The squashfs layers contain no user data.

## Kernel modules

UGOS ships with a standard Debian-style `/lib/modules/6.12.30+/` tree.
Three module groups matter for this project:

1. **`fs/btrfs/btrfs.ko`** — a modified btrfs that understands the
   UGACL incompat bit and the `UGACL version` superblock field. See
   [[btrfs-modification]].
2. **`fs/kmugacl/ugacl_vfs.ko`** — a separate module that implements
   the Windows-ACL emulation layer. See [[ugacl-system]].
3. **`drivers/ugreen/*`** — hardware drivers: LED controllers, fans,
   beepers, board-specific I/O. None affect filesystems.

## Why this matters for recovery

Two consequences flow from the above:

- **Recovery doesn't need UGREEN's userland.** Any kernel that
  understands the modified filesystem can read the data. We patch
  e2fsprogs to recognize the ext4 flag and write a small Python tool
  to strip the btrfs flag. The squashfs layers are not the trust
  boundary.
- **UGREEN's modifications are minimal.** Both filesystem changes are
  single bits in `incompat_flags`. No on-disk layout changes; no
  custom journals; no proprietary block formats. This is the cheapest
  possible form of vendor lockin — easy to apply, easy to undo.

> [!info]
> UGREEN's choice of "incompat feature" specifically is what causes
> mainline kernels to refuse the mount cleanly rather than read garbage.
> Bit 0x20000000 in ext4 and bit 62 in btrfs are *unallocated upstream*
> at the time of writing; UGREEN claims them as private vendor flags.
> See [[ext4-modification]] and [[btrfs-modification]] for details on
> each.

## Related

- [[ext4-modification]] — the ext4 side
- [[btrfs-modification]] — the btrfs side
- [[ugacl-system]] — the userspace consequence of the btrfs flag
- [[recovery-approach]] — the COW-snapshot pattern
