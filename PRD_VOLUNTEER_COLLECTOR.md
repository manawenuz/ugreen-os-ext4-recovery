# PRD: Volunteer Collector + Local UGOS Reproduction

Status: draft  •  Owner: maintainer  •  Created: 2026-05-17

## 1. Why this exists

We received our first real-world UGOS BTRFS bundle (issue #1) and discovered two things:

1. **Our patcher disagrees with the live kernel on the superblock CRC of all three mirrors at once.** The pattern is consistent with our CRC routine being computed over the wrong byte range — almost certainly because UGOS's `UGACL` extension (loaded as `ugacl_vfs.ko`, announced in dmesg as `Set btrfs UGACL, version[1]`) changes the superblock layout in a way we never modelled.
2. **Our `volunteer_validate.sh` collector did not capture enough material to let us reproduce the failure locally.** We have a kernel + modules but no userland (no squashfs rootfs images), and our superblock dumps are 4 KiB each rather than the full 64 KiB SB region. We cannot boot a minimal UGOS-like VM and cannot synthesise a test filesystem with confidence.

Without local reproduction, every patcher change is a guess against someone else's live data. That is the bar we are unwilling to clear.

This PRD specifies (a) what a volunteer bundle must contain to make local reproduction possible, (b) the new collector script that produces such bundles safely, and (c) the multi-agent audit gate that script must pass before we ship it to any volunteer.

## 2. Goals

* From a single volunteer bundle, a maintainer can reconstruct a near-identical UGOS environment locally (QEMU + captured kernel/initrd/squashfs) within one hour.
* Within that environment, the maintainer can synthesise a btrfs+UGACL filesystem, deliberately reproduce the CRC mismatch our patcher reported, and validate a fix — without ever writing to a volunteer's device.
* The collector itself is read-only by construction, idiot-proof to run, transparent about what it captures, and safe to share with non-experts.

## 3. Non-goals

* Reverse-engineering UGREEN's full userspace stack. We only need enough to load `btrfs.ko` + `ugacl_vfs.ko` and exercise the on-disk superblock format.
* Capturing user data. No file contents from `/volume*`, `/home`, `/overlay`, or any user subvolume — ever.
* Replacing `volunteer_validate.sh`. The validator stays; it answers "is this volume in scope for the patcher?" The collector answers a different question: "give us enough material to debug our own tooling."

## 4. Bundle contents specification

The collector produces a single tarball: `volunteer_bundle_<host-hash>_<UTC-date>.tar.gz`.

### 4.1 Required contents (collector fails if any is missing)

| Path inside tarball                  | Source                                                              | Purpose                                                       |
|--------------------------------------|---------------------------------------------------------------------|---------------------------------------------------------------|
| `MANIFEST.txt`                       | computed                                                            | sha256 + size of every file in bundle, with capture rationale |
| `system/uname.txt`                   | `uname -a`                                                          | kernel version match for VM                                   |
| `system/cmdline.txt`                 | `/proc/cmdline`                                                     | boot args UGOS uses                                           |
| `system/lsblk.json`                  | `lsblk -J -O`                                                       | full block topology                                           |
| `system/blkid.txt`                   | `blkid`                                                             | filesystem ids per device                                     |
| `system/mdadm.txt`                   | `mdadm --detail --scan` + `--detail /dev/md*`                       | RAID layout reconstruction                                    |
| `system/lvm.txt`                     | `pvs`, `vgs`, `lvs` (all `-o +all`)                                 | LVM layout reconstruction                                     |
| `system/dmsetup.txt`                 | `dmsetup table` + `dmsetup info`                                    | device-mapper graph                                           |
| `system/findmnt.json`                | `findmnt -J`                                                        | how UGOS mounts pools                                         |
| `system/btrfs_versions.txt`          | `btrfs --version`, `modinfo btrfs`, `modinfo ugacl_vfs`             | toolchain pinning                                             |
| `system/dmesg_btrfs.txt`             | `dmesg | grep -iE 'btrfs|ugacl|incompat'`                           | live evidence of what kernel computed                         |
| `kernel/vmlinuz`                     | `/boot/vmlinuz` (or `/boot/boot/vmlinuz`)                           | bootable kernel                                               |
| `kernel/initrd.img`                  | matching initrd                                                     | bootable initramfs                                            |
| `kernel/modules.tar.gz`              | `/lib/modules/$(uname -r)/`                                         | full module tree (must contain `btrfs.ko`, `ugacl_vfs.ko`)    |
| `kernel/efi.tar.gz`                  | EFI partition contents                                              | boot chain                                                    |
| `rootfs/base.sqfs` …                 | each squashfs mounted at `/rootfs/*`                                | UGOS userland                                                 |
| `rootfs/factory.img.gz`              | `/dev/<factory-partition>` (read-only, raw)                         | UGOS factory data                                             |
| `sb/<pool>_mirror<N>_64KiB.bin`      | `dd if=<dev> bs=4K count=16 skip=<offset/4K>` for each SB mirror    | **full 64 KiB superblock region**, all three mirrors per pool |
| `sb/<pool>_dump_super.txt`           | `btrfs inspect-internal dump-super -fa <dev>`                       | ground-truth CRC the kernel computes                          |
| `sb/<pool>_first_1MiB.bin.gz`        | first 1 MiB of each pool's block device, gzipped                    | partition/RAID/LVM headers in context                         |

### 4.2 Forbidden contents (collector aborts if it sees these in the work dir)

* Anything from a mounted subvolume that contains user data.
* Anything from `/home`, `/root`, `/var/log` beyond `dmesg`, `/etc/shadow`, ssh keys, network config with creds.
* Full disk images.
* Anything > the configured size cap (default 2 GiB) unless `--allow-large` is passed.

### 4.3 Sanitisation pass

Before tarballing, run text files through a scrubber that replaces:

* hostnames → `VOLUNTEER`
* MAC addresses → `aa:bb:cc:dd:ee:ff`
* public IPv4/IPv6 → `203.0.113.1` / `2001:db8::1`
* serial numbers found in `lsblk -O` → `SERIAL_REDACTED`
* `WWN` → `WWN_REDACTED`

UUIDs are kept (we need them to reconstruct dm-mapper layout). The scrubber lives in `scripts/image_capture/sanitize.sh` already; we extend it.

## 5. Collector script: `scripts/volunteer_collect.sh`

### 5.1 Hard rules (enforced in code, not in docs)

1. **Read-only by construction.** No `mount`, no `mkfs`, no `dd of=<device>`, no `blockdev --setrw`, no `dmsetup create`. Only `dd if=<device> of=<file>`, file copies, and process invocation for read-only tools.
2. **No write-mode flag exists.** There is no `--write`, `--patch`, `--fix`, `--repair` argument. A typo cannot escalate the script.
3. **Dry-run is the default.** First invocation prints what would be captured, the estimated total size, and exits. Real run requires `--confirm`.
4. **Refuses to operate on mounted-rw targets** unless `--allow-mounted` is passed (live reads are fine but we want the user to acknowledge).
5. **Size cap.** Hard default 2 GiB. Exits with a clear message if estimate exceeds cap; `--allow-large=N` to raise.
6. **Manifest before bundle.** Every file added to the work dir is sha256'd into `MANIFEST.txt` with a one-line "why captured" rationale.
7. **Single entry point, single output line.** End of run prints exactly: `Bundle: <path>  (<size>)  sha256=<hex>`. Nothing else routes through stdout at the tail.
8. **All operations logged in plain English** with a `[step N/M] doing X because Y` prefix. No raw `set -x`.

### 5.2 CLI shape

```
sudo ./scripts/volunteer_collect.sh [--confirm] [--allow-mounted] [--allow-large=GiB]
                                    [--out-dir DIR] [--pool /dev/mapper/<vol> ...]
```

* No positional args. Pools are discovered automatically and shown for confirmation in dry-run.
* `--pool` can be repeated to restrict to specific volumes; default is "all btrfs pools detected, both UGOS-labelled and unlabelled."

### 5.3 Failure modes (all must produce a copy-pasteable hint)

* Missing tool (`btrfs`, `mdadm`, …) → tell user which package on Debian/UGOS.
* Insufficient space in `--out-dir` → tell user the cap and the actual estimate.
* `/lib/modules/$(uname -r)` not present → fall back to whatever module tree exists, log it, continue.
* User answers "no" at the confirm prompt → exit 0, no partial files left on disk.

## 6. Local reproduction harness (Phase 3, after first good bundle)

* `scripts/repro/unpack_bundle.sh` — extracts a bundle to `./repro/<bundle-id>/`.
* `scripts/repro/build_vm.sh` — assembles a qcow2 from squashfs + a writable overlay; produces a QEMU command line that boots the captured `vmlinuz`+`initrd.img` with the captured module tree mounted in.
* `scripts/repro/make_synth_btrfs.sh` — given the captured SB region as a template, produces a small (e.g. 256 MiB) synthetic btrfs image with the UGACL incompat bit set, suitable for the patcher to chew on.
* `scripts/repro/check_patcher.sh` — runs `patch_btrfs_ugos.py --check` in the VM against the synthetic image, then runs `btrfs inspect-internal dump-super -fa` and diffs the CRCs. Pass iff they match.

Out of scope for the first round (Phase 2 ships the collector; Phase 3 follows once we have a bundle that satisfies §4.1).

## 7. Audit gate (Phase 4)

Before the collector is offered to any new volunteer, three independent reviewers run, in parallel, with non-overlapping mandates. Findings collected into `PRD_AUDIT_VOLUNTEER_COLLECTOR.md`. We fix data-loss issues first, correctness second, UX last. Nothing ships until categories 1 and 2 are clean.

| Lens                 | Mandate                                                                                                                                                                                                                              |
|----------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1. Data-loss / safety | Any code path that could write to a target disk? Any TOCTOU between probe and capture? Any way `--confirm` becomes implicit? Any shell-injection via device names or filenames? Any flag typo that silently does the wrong thing?    |
| 2. Correctness        | Does each step do what the docs say? For every item in §4.1, is it actually captured? Is the manifest accurate? Does the size cap really fire? Does refusing on mounted-rw really refuse? Does sanitisation cover every text artefact? |
| 3. UX / clarity       | Can a non-expert volunteer follow this without dread? Are prompts unambiguous? Do error messages tell them what to do next? Does the README's "what this will and will not do" section match the code's actual behaviour?              |

Lens 1 and Lens 2 use separate agents and must not share context. Lens 3 reviews the result.

## 8. Phased plan

| Phase | Deliverable                                                                                  | Blocked by |
|------:|----------------------------------------------------------------------------------------------|-----------:|
| 1     | This PRD merged. Bundle contents spec frozen.                                                | —          |
| 2     | `scripts/volunteer_collect.sh` + `sanitize.sh` extensions + README                           | Phase 1    |
| 3     | Audit (three agents, parallel). `PRD_AUDIT_VOLUNTEER_COLLECTOR.md` produced and addressed.   | Phase 2    |
| 4     | Collector posted on issue #1 with one-line invocation. Wait for new bundle.                  | Phase 3    |
| 5     | `scripts/repro/*` harness. Reproduce CRC mismatch locally.                                   | Phase 4    |
| 6     | Patcher CRC fix, validated against repro harness, posted as proposed.                        | Phase 5    |
| 7     | Audit (three agents) of the patcher fix, same gates as Phase 3.                              | Phase 6    |

## 9. Open questions

* Should the bundle also capture `/etc/ugreen` / `/etc/ugos` config trees? They're tiny and might explain non-default mkfs options. Tentative yes, behind a flag.
* Squashfs files can be 100+ MiB each. The default 2 GiB cap should cover them, but worth checking against a real DXP6800 Pro install before we promise it to volunteers.
* `vmlinuz2`/`initrd2.img` (A/B slot) — capture both or just the live one? Tentative both; cost is small.

## 10. References

* Issue #1: https://github.com/manawenuz/ugreen-os-ext4-recovery/issues/1
* Existing collector: `scripts/volunteer_validate.sh`
* Existing image capture (qcow2 path): `scripts/image_capture/`
* Existing patcher: `scripts/patch_btrfs_ugos.py`
* Original BTRFS PRD: `PRD_UGREEN_OS_BTRFS_PATCH.md`
