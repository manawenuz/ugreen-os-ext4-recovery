---
title: UGREEN's btrfs Modification
tags: [ugos, btrfs, vendor-lockin, incompat-flag, ugacl, superblock]
created: 2026-05-17
---

# UGREEN's btrfs Modification

UGREEN OS's btrfs modification is structurally similar to its
[[ext4-modification|ext4 one]] — one bit in the incompat-flags field —
but it accompanies a **real, observable userspace subsystem**: UGACL,
which emulates Windows-style ACLs on top of btrfs and stores its data
in extended attributes. The flag isn't decorative; it signals that the
filesystem expects UGACL infrastructure to be present.

## The bit and where it lives

Bit `62` (`0x4000000000000000`) of the btrfs superblock's
`incompat_flags` field is the marker.

| Field        | Value                                       |
|--------------|---------------------------------------------|
| Symbol       | `BTRFS_FEATURE_INCOMPAT_UGACL`              |
| Bit          | 62                                          |
| Mask         | `0x4000000000000000`                        |
| SB offset    | **`0xBC`** (8 bytes, little-endian)         |

> [!warning]
> The original PRD (`PRD_UGREEN_OS_BTRFS_PATCH.md`) at one point said
> the offset was `0x128`. That's wrong. The correct offset is `0xBC`,
> verified against the mainline btrfs `struct btrfs_super_block`
> definition and against `btrfs inspect-internal dump-super` on a real
> UGOS volume. See `PRD_BUGS_BTRFS_PATCH.md` → BUG-001.

When a mainline kernel reads this SB, it sees the unknown bit and
refuses the mount with `BTRFS error: unsupported optional features
(0x4000000000000000)`.

## Superblock mirror offsets

btrfs replicates the superblock at **three** offsets on every
sufficiently-large device:

| Mirror | Offset bytes  | Offset (human) |
|--------|---------------|-----------------|
| 0      | `0x00010000`  | 64 KiB          |
| 1      | `0x04000000`  | 64 MiB          |
| 2      | `0x4000000000`| 256 GiB         |

Each is exactly 4 KiB (the `BTRFS_SUPER_INFO_SIZE`). On a btrfs
volume smaller than 256 GiB, mirror 2 simply doesn't exist (the SB
init code skips offsets past device end).

> [!warning]
> Older drafts of this project's PRDs mentioned a fourth mirror at
> 1 TiB. That was incorrect — see `PRD_BUGS_BTRFS_PATCH.md` → BUG-007.
> Writing to a 1 TiB offset on a real device would have stomped on
> user data.

## Superblock structure and checksum

```
offset  size   field
0x00    32     csum         ← the checksum (32 bytes reserved; only 4
                              are used for crc32c)
0x20    16     fsid
0x30    8      bytenr        (physical offset where this SB lives)
0x40    8      magic         "_BHRfS_M"
0xBC    8      incompat_flags  ← bit 62 = UGACL
...     ...    ...
0x1000  end of SB
```

The checksum covers bytes `[0x20 .. 0x1000)` — 4064 bytes (`0xFE0`).
The csum field itself is **not** included in the hash input. Mainline
btrfs uses crc32c (Castagnoli polynomial) by default; UGOS does
likewise (`using crc32c (crc32c-intel) checksum algorithm` in dmesg
on mount).

Confirming this empirically: disassembling `btrfs_check_super_csum`
out of the captured UGOS `btrfs.ko` shows:

```asm
mov ecx, 0x2f       ; shash setup
mov edx, 0xfe0      ; length = 4064 = 0xFE0
add rsi, 0x20       ; source pointer += 0x20
```

This is the mainline range. UGREEN did **not** move the CRC window.
See [[bug-postmortems#bug-016]] for why that mattered.

## UGACL-related symbols in btrfs.ko

UGREEN added a handful of symbols to their modified `btrfs.ko`:

```
btrfs_set_ugacl                  (T, exported)
btrfs_get_ugacl                  (T, exported)
btrfs_ugacl_from_disk            (T, exported)
__btrfs_set_ugacl.constprop.0    (t, internal)
btrfs_xattr_ugacl_get            (t, internal)
btrfs_xattr_ugacl_set            (t, internal)
btrfs_xattr_ugacl_access_handler (R, xattr_handler instance)
ug_super_acl_version_get.isra.0  (t, internal)
```

Read these alongside the strings UGREEN's btrfs prints:

```
[%s:%d:%s] magic[0x%0X,0x%0X,0x%0X] ugacl[%d,%lld,%lld].
Set btrfs UGACL, version[%u].
Failed request ugacl module.
```

The `Set btrfs UGACL, version[1]` log line you'll see in `dmesg` on
every UGOS mount is emitted by `btrfs_set_ugacl` via
`__btrfs_set_ugacl.constprop.0`. It's the kernel announcing "this FS
expects the UGACL companion module." If `ugacl_vfs.ko` is missing or
fails to load, you get `Failed request ugacl module` and the FS
silently degrades to plain btrfs semantics — see [[ugacl-system]] for
what that means functionally.

## What UGREEN stores in the superblock

Two kinds of state live in or near the SB:

1. The **incompat bit** at `0xBC` — the trigger.
2. A **UGACL version field** read by `ug_super_acl_version_get.isra.0`.
   We have not yet pinned down the exact offset; the function's name
   (with `.isra.0` suffix indicating it was inlined and specialized)
   tells us it reads a `version` value out of the SB struct. The
   format string `magic[0x%0X,0x%0X,0x%0X] ugacl[%d,%lld,%lld]`
   suggests three integers describing UGACL state alongside three
   magic numbers — but the layout of those bytes within the
   "reserved" region of the SB has not been reverse-engineered.

We do know they live **inside** the checksummed region `[0x20..0x1000)`
because the kernel's CRC matches what we recompute over that range
(see [[bug-postmortems#bug-016]]). They're not metadata that hangs off
the SB; they're part of it.

## How we recognize and strip the flag

The btrfs patcher (`scripts/patch_btrfs_ugos.py`) reads the SB at each
mirror offset, validates magic / bytenr / csum_type, confirms bit 62
is set, clears it, recomputes crc32c over `[0x20..0x1000)`, and
writes the patched 4 KiB block back.

That recompute is where [[bug-postmortems#bug-016|BUG-016]] lived for
a release cycle: our crc32c table was built with the wrong polynomial
form (forward Castagnoli `0x1EDC6F41` in an LSB-first table builder,
which mathematically requires the reflected form `0x82F63B78`). The
result was a CRC that looked plausible but disagreed with the kernel
on every non-trivial input. We never reached the write path in the
wild — the validator told volunteers to stop — but had anyone
proceeded, their FS would have been corrupted.

The fix is one constant. The reason it survived review for so long is
that **standard test vectors are short**; on small inputs the broken
implementation occasionally agreed with crc32c by accident. RFC 3720's
`"123456789"` check value (`0xE3069283`) was enough to expose it once
we thought to test.

## The orphaned-xattr question

Clearing bit 62 strips the "this FS uses UGACL" signal from the SB,
but the **xattrs UGACL stored on individual files remain on disk**.
Their namespace prefixes are:

- `system.ugacl_self`
- `trusted.ugacl_status`
- `trusted.ugacl_version`

A mainline btrfs after the patch sees these as ordinary xattrs in
the `system` and `trusted` namespaces. `getfattr -d -m '.*' <file>`
will list them. Nothing reads or interprets them; they don't gate
access or affect data integrity. They're inert data.

For round-trip behavior (re-mount under UGOS after our patch), see
[[recovery-approach#reversibility-and-round-trip]].

## Related

- [[ugos-architecture]] — where btrfs sits in the UGOS stack
- [[ugacl-system]] — the userspace consequence of bit 62
- [[bug-postmortems]] — particularly BUG-016 and BUG-007
- [[static-analysis-toolkit]] — how we extracted the symbol info above
