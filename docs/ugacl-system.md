---
title: The UGACL System (Windows ACL Emulation)
tags: [ugos, ugacl, xattr, btrfs, acl, vfs]
created: 2026-05-17
---

# The UGACL System (Windows ACL Emulation)

UGACL is the most surprising thing in this project. Reading the
`ugacl_vfs.ko` module's metadata directly:

```
description=Add Windows ACL System Call Support
author=Ugreen Inc.
license=GPL
name=ugacl_vfs
```

UGACL is UGREEN's **Windows-style ACL emulation layer**, stored as
extended attributes on btrfs files, with **DOS-style archive bits**.
It's loaded on every UGOS boot, announced via the `Set btrfs UGACL,
version[1]` dmesg line ([[btrfs-modification]]). Its purpose is
presumably to make SMB/CIFS exports behave more like Windows shares,
where ACLs, inheritance, and the archive bit are first-class concepts
that POSIX doesn't model directly.

## Why the maintainer cares (and the volunteer doesn't have to)

For the recovery flow, UGACL is mostly inert:

- It is **not on the data path**. File contents are stored by btrfs
  as usual; UGACL only annotates permissions and metadata.
- It is **not a filesystem-layout change**. No extent format
  differences, no inode flag changes that mainline btrfs can't read.
- It **does** put data in xattrs that mainline doesn't interpret —
  but those xattrs are inert when read by a non-UGACL kernel.

So clearing the incompat bit and mounting under mainline Linux works
fine for **read access**; the xattrs are just along for the ride.

The risk is on the **write side** and on **round-trip to UGOS** —
covered in [[recovery-approach#reversibility-and-round-trip]].

## Module structure

`ugacl_vfs.ko` is small (76 KiB stripped, ~28 exported symbols) and
self-contained. It depends on no other module (`depends=` is empty in
its `modinfo`). The exported function set tells you exactly what
domain it covers:

### Permission and access control

```
ugacl_access
ugacl_check_perm
ugacl_exec_permission
ugacl_may_delete
ugacl_permission
ugacl_permission_byuid
ug_check_capable
```

These are the entry points the kernel's VFS layer calls to ask "is
this user allowed to do that?" Standard POSIX hooks, just delegated
to UGACL logic.

### ACL conversion

```
convert_posixacl
_posix_to_ugacl_one.isra.0
ugacl_to_mode
ugacl_get_perm
ugacl_get_perms
ugacl_init_acl
ug_get_acl
ug_set_acl
```

The bridge between POSIX ACLs (the kernel's native abstraction) and
UGACL's Windows-style model. `convert_posixacl` and
`_posix_to_ugacl_one` are the workhorses.

### DOS archive bits

```
ug_archive_safe_add
ug_archive_safe_clean
ugacl_archive_change_ok
ugacl_get_archive_bits
```

Yes — UGOS tracks the Windows/DOS **archive bit** per file, the one
backup software has used since the 1980s to know "this file changed
since last backup." Stored separately from the ACL, manipulated by
its own set of functions. There's even a debug string:
`No ACL exists but archive bit is enabled.` — so the archive bit is
orthogonal to the ACL itself.

### xattr handlers

```
ugacl_xattr_get
ugacl_setattr_post
```

Hook into the VFS's `setattr` path so UGACL state stays in sync
when chmod/chown happens.

### Lifecycle

```
load_ugacl
unload_ugacl
ugacl_extend_api
ugacl_is_support
init_module
cleanup_module
```

Standard module init/teardown plus a capability-discovery function
that the modified `btrfs.ko` calls via `request_module` to see if
UGACL support is installed.

## On-disk format (what we have, what we don't)

UGACL data lives in three xattrs on individual files:

| xattr name              | Namespace  | Likely purpose                            |
|-------------------------|------------|-------------------------------------------|
| `system.ugacl_self`     | `system`   | The file's own ACL (binary blob)          |
| `trusted.ugacl_status`  | `trusted`  | Per-file UGACL state (probably archive bit, inheritance flags) |
| `trusted.ugacl_version` | `trusted`  | Schema version, matches the SB-level version |

The `system` namespace is special — kernel-managed, requires
filesystem support to set. The `trusted` namespace requires
`CAP_SYS_ADMIN` to read or write. Both are visible to `getfattr`.

What we **don't know yet**:

- The byte format of the `system.ugacl_self` blob. We have
  `btrfs_ugacl_from_disk` exported, which presumably deserializes
  it, but we haven't disassembled it.
- The exact bit layout of `trusted.ugacl_status` (presumably
  archive bit + flags).
- Whether UGACL supports inheritance, audit ACLs, or just basic
  per-file permissions. Function names suggest at minimum
  per-user permissions (`ugacl_permission_byuid`) and capability
  checks (`ug_check_capable`).

These are open questions for a future deeper analysis pass; the
recovery flow doesn't need them.

## The "request_module failed" warning

A standard Linux kernel mounting an ex-UGOS volume (after our patch)
will sometimes log:

```
ugacl_vfs request_module failed
```

This is the modified `btrfs.ko` trying to find UGACL support and not
finding it (because we're not running UGOS, we're running mainline,
where `ugacl_vfs.ko` doesn't exist). The kernel **continues normally**:
permissions fall back to POSIX, the UGACL xattrs are just regular
xattrs nobody reads.

This is mentioned in the parent README as a "Gotchas" item.

> [!note]
> This warning **only appears if the UGOS-modified `btrfs.ko` is
> loaded**. If you're booting plain Debian/Ubuntu/TrueNAS with their
> own btrfs module, you'll never see it — your kernel doesn't know
> UGACL exists in the first place.

## Functional consequences when reading under mainline

Things that **work**:

- Reading every file's contents.
- Reading the POSIX ACL via `getfacl` — mainline btrfs reads its
  native ACL xattrs (`system.posix_acl_access`, `_default`)
  independently of UGACL.
- Listing the orphaned UGACL xattrs via `getfattr -d -m '.*'`.

Things that **don't work** (but probably don't matter):

- DOS archive bit tracking. SMB exports under Samba can still
  emulate the archive bit themselves; the on-disk state UGOS
  recorded just becomes stale.
- Windows-specific ACL inheritance semantics. POSIX ACLs apply
  instead, which is what mainline distros assume anyway.
- Anything UGOS-specific that depended on UGACL being available
  (e.g., the UGREEN web UI's permission editor).

## Related

- [[btrfs-modification]] — the SB-level signal that activates UGACL
- [[recovery-approach]] — the COW snapshot pattern that lets us test
  UGACL-touching changes without consequence
- [[static-analysis-toolkit]] — how to extract more of UGACL's
  internals yourself
