# Local reproduction harness

These four scripts let a maintainer take a `volunteer_collect.sh` bundle
and rebuild enough of UGOS locally to debug the patcher without ever
touching volunteer data.

## Flow

```
volunteer_bundle_<hash>_<date>.tar.gz
        │
        ▼
unpack_bundle.sh        ── extract + verify MANIFEST sha256s ──>  repro/<bundle-stem>/
        │
        ├── build_vm.sh         ── stage qcow2 + qemu cmd ──>  vm/run.sh
        │
        ├── make_synth_btrfs.sh ── synth btrfs+UGACL image ──> vm/synth_btrfs.img
        │
        └── check_patcher.sh    ── diff our --check vs btrfs-progs dump-super
                                                              │
                                                              ▼
                                                  exit 0 = agreement
                                                  exit 3 = the bug we're hunting
```

## Status

This is **Phase 5 scaffolding** — the scripts run, the math in
`make_synth_btrfs.sh` follows our current CRC model, and
`check_patcher.sh` performs the diff. What's not yet validated:

1. `build_vm.sh`'s VM actually boots UGOS to a usable shell. The
   captured initrd may need overlay-mount tweaks; if boot stalls in
   initramfs we'll need to either patch the initrd or build a minimal
   busybox rootfs and load `btrfs.ko` + `ugacl_vfs.ko` from the captured
   module tree directly. That's the fallback if the full UGOS pivot is
   too brittle.
2. The `crc32c` byte range in `make_synth_btrfs.sh` matches our patcher
   today. The whole point of `check_patcher.sh` is to see whether that
   matches the kernel's view — when it disagrees, we have our smoking
   gun, and the fix lives in `patch_btrfs_ugos.py`.

## Requirements

- `qemu-system-x86_64`, `qemu-img`
- `btrfs-progs` (provides `mkfs.btrfs` and `btrfs inspect-internal dump-super`)
- `python3`
- root for `make_synth_btrfs.sh` (needs `mkfs.btrfs` and loop devices)

## Quick run

```bash
./scripts/repro/unpack_bundle.sh ~/Downloads/volunteer_bundle_*.tar.gz
sudo ./scripts/repro/make_synth_btrfs.sh --out vm/synth_btrfs.img
sudo ./scripts/repro/check_patcher.sh vm/synth_btrfs.img
# exit 3 = disagreement (expected, this is the bug we're finding)
# exit 0 = our CRC routine already matches the kernel
```

`build_vm.sh` is optional — only needed if static analysis of
`btrfs.ko`/`ugacl_vfs.ko` is inconclusive and we need to observe the
kernel computing checksums live.
