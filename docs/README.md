---
title: UGREEN OS Knowledge Vault
tags: [ugos, ugreen, nas, btrfs, ext4, ugacl, recovery, index]
created: 2026-05-17
---

# UGREEN OS Knowledge Vault

This directory is a small Obsidian-style knowledge base for everything
this project has learned about **UGREEN OS** — UGREEN Inc.'s NAS
operating system shipped on the DXP4800 / DXP6800 / DXP8800 family —
and the on-disk modifications it makes to ext4 and btrfs that prevent
mainline Linux from mounting those volumes out of the box.

If you found this repo because your NAS dropped you back to a vanilla
kernel and your data won't mount, the practical fix is in the parent
[`README.md`](../README.md). This `docs/` tree is for the deeper
question: *what is UGREEN actually doing to those filesystems, why, and
how do we know?*

## Entry points

Read in any order. Wikilinks connect related ideas:

- [[ugos-architecture]] — what UGREEN OS *is* on disk: kernel, modules, squashfs userland, partition + dm-mapper layout
- [[ext4-modification]] — the `0x20000000` incompat bit on ext4 volumes, and the four-hunk e2fsprogs patch that recognizes it
- [[btrfs-modification]] — bit 62 of `incompat_flags` on btrfs, the `Set btrfs UGACL, version[1]` log line, and what the superblock actually looks like
- [[ugacl-system]] — the `ugacl_vfs.ko` module: **Windows-style ACL emulation** stored as xattrs, with DOS archive bits. Yes, really
- [[recovery-approach]] — the COW-snapshot dry-run pattern that lets us test patches without touching real data
- [[bug-postmortems]] — what went wrong, what we found, what we changed
- [[static-analysis-toolkit]] — how to reproduce our findings yourself with `pyelftools` + `capstone` (no Ghidra required)

## Tags used across the vault

- `#ugos` — facts about UGREEN OS internals
- `#ext4` — ext4-specific
- `#btrfs` — btrfs-specific
- `#ugacl` — Windows ACL emulation layer
- `#methodology` — how we figured something out, not what we found
- `#postmortem` — bugs we made or found, and the fixes
- `#vendor-lockin` — observations about UGREEN's deliberate-or-not lockin choices

## Provenance

Nothing in this vault is decompiled UGREEN source code; everything is
derived from one or more of:

- the unstripped `btrfs.ko` and `ugacl_vfs.ko` modules shipped in
  `/lib/modules/6.12.30+/` on a running UGREEN OS install
- on-disk superblocks captured via `dd`
- live kernel `dmesg` output during normal mount
- open-source mainline btrfs and e2fsprogs source from kernel.org
- the project's own audit work (see [[bug-postmortems]])

Where a claim is directly observable, the vault names the symbol,
string, or instruction it came from so you can re-derive it yourself.

> [!note]
> This vault is *descriptive* (what is and how we know), not
> *prescriptive* (what to do). For the practical recovery flow, see
> the project's parent `README.md` and the `scripts/` directory.
