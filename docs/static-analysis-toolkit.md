---
title: Static-Analysis Toolkit
tags: [methodology, static-analysis, kernel-module, elf, capstone, pyelftools]
created: 2026-05-17
---

# Static-Analysis Toolkit

How to reproduce the kernel-module findings in this vault yourself. No
Ghidra, no IDA, no commercial tooling required. The two Python
libraries `pyelftools` and `capstone` (both `pip install`-able) plus
GNU `nm`, `strings`, and `file` are sufficient for everything we did
on `btrfs.ko` and `ugacl_vfs.ko`.

The repo ships a small helper at
`scripts/repro/disasm_kernel_function.py` that uses these libraries
to disassemble a named function out of an unstripped `.ko` module.

## Prerequisites

```bash
pip install pyelftools capstone
```

GNU `nm`, `strings`, `file`, `objdump` are usually already installed.
On macOS the Apple-shipped `nm` is LLVM-based and works on ELF; same
for `strings`. `objdump` is missing by default — install Homebrew
`binutils` (`gobjdump`) if you want it, but we never needed it.

## Step 1 — verify what you're looking at

```bash
file /lib/modules/6.12.30+/kernel/fs/btrfs/btrfs.ko
```

Should return `ELF 64-bit LSB relocatable, x86-64, ..., not stripped`.
"Not stripped" is the lucky-day moment: UGREEN ships their modules
with full symbol tables. Function names, debug strings, everything is
preserved. We can extract enormous amounts of information just from
symbol names.

> [!info]
> A stripped module would still be analyzable, but you'd need to
> match against mainline btrfs symbols by signature rather than by
> name. UGREEN's gift to us here is significant.

## Step 2 — symbol survey

```bash
# All defined functions:
nm --defined-only btrfs.ko | awk '$2=="T" || $2=="t" {print $3}' | grep -v '^__pfx_'

# Filter to what you care about:
nm --defined-only btrfs.ko | grep -i ugacl | grep -v __pfx_
```

The `__pfx_` prefix comes from kCFI (kernel Control Flow Integrity).
Each function `foo` has a 16-byte padding-block landing pad named
`__pfx_foo` immediately before it. Strip those prefixes mentally;
they aren't separate functions.

`T` = exported (visible to other modules and the kernel). `t` =
local (file-static). Both are real code.

## Step 3 — string survey

```bash
strings btrfs.ko | grep -iE 'ugacl|ugreen' | sort -u
```

Strings are gold. Format strings reveal API surfaces (`Set btrfs
UGACL, version[%u]` told us there's a UGACL version field somewhere).
xattr names reveal data-storage layout (`trusted.ugacl_status` told
us UGACL state is in xattrs). Debug strings reveal call paths
(`No ACL exists but archive bit is enabled` told us archive bits are
tracked separately from ACLs).

For modules, also look at module metadata:

```bash
strings btrfs.ko | grep -E '^(license|description|author|name|depends)='
modinfo btrfs.ko 2>/dev/null  # works if modinfo can find a kernel
```

The `description=Add Windows ACL System Call Support` line on
`ugacl_vfs.ko` is how we knew, with certainty, what UGACL is for.

## Step 4 — function disassembly

`scripts/repro/disasm_kernel_function.py` wraps the boilerplate:

```bash
./scripts/repro/disasm_kernel_function.py btrfs.ko btrfs_check_super_csum
```

Output is x86-64 assembly with absolute addresses and instruction
bytes. Even without decompilation, the first ten instructions
typically reveal the function's argument handling and any immediate
constants — which is often all you need:

```asm
mov  ecx, 0x2f       ; constant: shash setup
mov  edx, 0xfe0      ; constant: length 4064 bytes
add  rsi, 0x20       ; pointer adjust: +0x20
```

Three lines, three constants, one answer: the kernel hashes
`[base+0x20 .. base+0x20+0xFE0)`. Same range as mainline. That's how
we ruled out "UGREEN moved the CRC window" and pinned BUG-016 on our
own code.

## What we did *not* need

- **Ghidra** — full decompilation would be useful if we needed to
  understand UGACL's xattr blob format. We didn't, for the
  recovery work. If you want to characterize the
  `system.ugacl_self` byte layout, Ghidra (or just careful capstone
  + reading) on `btrfs_ugacl_from_disk` would be the move.
- **IDA / Hex-Rays** — same.
- **Building a matching kernel** — we never had to run the modules.
  The ELF on disk has everything we need.
- **A linux VM** — for symbol/string/disassembly work, you can do
  it all on macOS or Windows. Only the end-to-end repro harness
  needs Linux.

## Relocations and unresolved calls

`call rel32` instructions in an unlinked `.ko` show a relocation
target of `0` (calls point to the next instruction, with the
relocation pending). To resolve them you'd read the `.rela.text`
section. `disasm_kernel_function.py` doesn't currently apply
relocations — for our BUG-016 question we didn't need them, since
the constants we cared about (`0x20`, `0xFE0`) were immediate-mode
`mov` instructions, not call targets.

If you do need them:

```python
from elftools.elf.relocation import RelocationSection
for sec in elf.iter_sections():
    if isinstance(sec, RelocationSection):
        for r in sec.iter_relocations():
            ...
```

`pyelftools` exposes the full relocation table.

## Working in the volunteer-bundle workflow

The volunteer collector (`scripts/volunteer_collect.sh` on the
feature branch) captures `/lib/modules/$(uname -r)/` as a tarball in
the bundle. Extract it locally:

```bash
tar xzf bundle/kernel/modules.tar.gz
ls 6.12.30+/kernel/fs/btrfs/btrfs.ko
ls 6.12.30+/kernel/fs/kmugacl/ugacl_vfs.ko
```

From there it's the same workflow as above. No need to ever touch
the volunteer's running NAS again once you have the bundle.

## Related

- [[bug-postmortems]] — what we found with these tools
- [[btrfs-modification]] — the symbol map this toolkit produced
- [[ugacl-system]] — the most extensive use of the toolkit so far
