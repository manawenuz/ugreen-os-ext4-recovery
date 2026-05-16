# UGOS image capture tooling

Tooling to capture a UGOS Pro system image from a live, running NAS without
rebooting and without touching the user's data pools. Designed for the
volunteer workflow described in
[issue #1](https://github.com/manawenuz/ugreen-os-ext4-recovery/issues/1).

## Trust model

Read every script before running. The whole point of this tooling is that you
should be able to audit it line by line and convince yourself it does what it
claims. If something here looks off, open an issue before running anything.

- `capture.sh` only reads from the live system. It never writes to anything
  except the output directory you choose.
- `sanitize.sh` only reads the captured tarball and writes a new sanitized
  tarball. It never touches the live system.
- `rebuild_qcow2.sh` runs on the maintainer side (not on the volunteer's NAS).

## Two phases

### Phase A — kernel + modules only (~200–500 MB)

This is enough to disassemble UGOS's btrfs kernel module and likely reverse
the `ugacl` CRC routine without ever needing a full rootfs.

```sh
sudo ./capture.sh --phase a --out /mnt/external/ugos-capture
```

### Phase B — full sanitized rootfs (~2–8 GB)

Only run this if Phase A wasn't enough. Includes the OS rootfs with
`--one-file-system` so it cannot descend into data pools.

```sh
sudo ./capture.sh --phase b --out /mnt/external/ugos-capture
```

## Workflow

```
volunteer NAS                              maintainer
─────────────                              ──────────
1. capture.sh         ──► raw tarball
2. sanitize.sh        ──► sanitized tarball ──► upload
                                                 │
                                                 ▼
                                          3. rebuild_qcow2.sh
                                          4. qemu-system-x86_64
                                          5. iterate on ugacl
```

## Files in this directory

| File              | Runs where      | What it does                                          |
| ----------------- | --------------- | ----------------------------------------------------- |
| `capture.sh`      | volunteer NAS   | Tars kernel + (optionally) rootfs from live system.   |
| `exclude.list`    | volunteer NAS   | Paths excluded from the rootfs tar. Reviewable.       |
| `sanitize.sh`     | volunteer NAS   | Produces a redacted copy of the capture tarball.      |
| `sanitize.rules`  | volunteer NAS   | Explicit list of paths the sanitizer rewrites/strips. |
| `rebuild_qcow2.sh`| maintainer      | Builds bootable qcow2 from sanitized tarball.         |

## What the volunteer should see when running this

- No reboot. No remount. No mutation of `/`, `/etc`, `/var`, `/home`, or
  anywhere else on the live system.
- Shares stay up. UGOS keeps running.
- Output goes to a directory you pick (external drive recommended).
- A `manifest.json` is produced containing sha256 of every chunk and a full
  inventory of what was captured and what was excluded. Read this before
  uploading anything.
- Captured tarball is **not** sanitized yet. Run `sanitize.sh` next.
- Sanitizer produces a separate `*-sanitized.tar.zst.NNN` set plus a
  `sanitize.log` showing every modification. Read this before uploading.

## Safety checks built into capture.sh

- Refuses to run if not root.
- Refuses to write into `/`, `/boot`, `/etc`, `/var`, `/home`, `/root`,
  `/usr`, `/lib`, `/opt`, `/srv`, or any path under a btrfs/zfs mount.
- Refuses to run if `--out` is on the same filesystem as `/`.
- `tar --one-file-system` guarantees no descent into mounted data pools.
- Uses `nice -n 19 ionice -c 3` so the live system stays responsive.

## Safety checks built into sanitize.sh

- Operates on a copy. Original capture tarball is never modified.
- Reads `sanitize.rules` (a separate file) so you can review every rule
  before running.
- Emits a unified diff of `/etc/passwd`, `/etc/shadow`, `/etc/fstab` so you
  can see exactly what changed.
- Logs every removed path to `sanitize.log`.

## Disk space requirements

- Phase A: ~1 GB free on the destination.
- Phase B: ~3× the size of your installed OS on the destination (room for
  raw capture, sanitized copy, and overhead). For UGOS that's typically
  10–30 GB.

## What this tooling will NOT do

- It will not touch your data pools.
- It will not modify any file on your live system.
- It will not upload anything anywhere. You decide what leaves your NAS
  and when.
- It will not reset your live root password (only the password baked into
  the sanitized image for VM boot).
