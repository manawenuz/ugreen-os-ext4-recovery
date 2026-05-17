# UGOS image capture — maintainer-requested fallback

> [!warning]
> **Status: maintainer-requested fallback, not the default volunteer entry point.**
>
> If you're a volunteer looking for what to run, the default tool is
> `scripts/volunteer_collect.sh` (see `scripts/VOLUNTEER_COLLECT_README.md`).
> That collector captures a smaller, targeted metadata bundle and is what we
> want for almost all debugging work.
>
> Run `image_capture/` **only if a maintainer has explicitly asked you to**.
> This tool produces a much larger bundle (1–30 GiB) intended for booting
> UGOS in a VM, and it has known blockers documented below that must be
> understood before running.

## Known blockers (per `PRD_AUDIT_LEGACY_TOOLING.md`)

Before this tool is offered to a second volunteer, the following defects
need fixing:

- **`apply_strip` deletes by basename glob without a `-type f` filter**
  (`sanitize.sh`). Patterns like `**/secret*`, `**/*.pem`, `**/*.key`
  recursively `rm -rf` anything matching, including CPython's stdlib
  `secrets.py`, system CA bundle PEMs, and Xorg keyboard `.key` files.
  The resulting sanitised rootfs may be missing libraries needed to boot.
  `test_sanitize.sh` does not catch this because its keepers list has no
  library files.

- **`inventory.json` is documented as "non-sensitive metadata" but isn't.**
  It contains the unmodified hostname, mount UUIDs, kernel cmdline, and
  **block-device serial numbers** (via `lsblk -O`). The sanitiser does not
  touch it. Volunteers were told it was safe to share.

- **`/etc/hostname` is explicitly preserved in KEEPERS.** On consumer NAS,
  hostname is often serial-derived (`UGREEN-DXP4800-XXXXXXX`). This leaks
  the device serial.

- **Phase B captures the live UGOS rootfs without quiescing.** No
  fs-freeze, no snapshot. Any sqlite/btree database being written produces
  a torn copy, and the resulting VM may fail to boot.

- **Sanitisation gaps** in network leases (systemd-networkd), bluetooth
  pairings, user dotfiles (`.git-credentials`, browser profiles),
  `/etc/hosts`, `*.crt`-with-embedded-private-key, and `authorized_keys2`
  / `*.pub` files.

---

## Original runbook (if a maintainer has asked you to run this anyway)

> **One-line summary:** read kernel + (optionally) rootfs from your live NAS,
> redact secrets locally, ship the sanitized archive to the maintainer so
> they can boot UGOS in a VM and reverse the `ugacl` btrfs CRC routine
> without ever needing your actual data.

---

## What you need before starting

- Root access on the NAS (sudo).
- An **external drive** or **separate partition** with at least:
  - **1 GB free** for Phase A (kernel + modules only), or
  - **10–30 GB free** for Phase B (full sanitized rootfs).
- About **30 minutes** of (mostly hands-off) wall-clock time for Phase A.
  Phase B takes longer depending on rootfs size.
- Standard tooling already on UGOS: `tar`, `zstd`, `jq`, `findmnt`, `blkid`,
  `lsblk`, `sha256sum`, `openssl`.

You do **not** need to:

- Reboot.
- Stop your shares.
- Boot into a live USB or rescue environment.
- Touch your data pools.

---

## What the maintainer will see

Only what you decide to upload, after you've reviewed:

- `sanitize.log` — every file that was redacted or removed.
- `diffs/passwd.diff`, `diffs/shadow.diff`, `diffs/fstab.diff` — the exact
  text changes made to those three files.
- The output tarball itself.

The capture script reads only. The sanitize script only modifies a copy.
Your live root account, your data pools, and your shares are never touched.

---

## Step-by-step

### Step 1 — Clone the branch

```sh
git clone -b feature/image-capture-tooling \
    https://github.com/manawenuz/ugreen-os-ext4-recovery.git
cd ugreen-os-ext4-recovery
```

### Step 2 — (Optional but appreciated) re-run the validator

The validator that gave you "vanilla Linux" last time has been fixed and now
takes an `--os` override flag. Re-running it gives the maintainer a clean
report with the three bugs from your first round gone.

```sh
sudo ./scripts/volunteer_validate.sh --os ugos /dev/mapper/ug_<your-pool>
```

This produces a tarball at the repo root named
`btrfs_volunteer_report_<timestamp>.tar.gz`. You can attach it to the issue
or skip this step entirely if you'd rather just go straight to the capture.

### Step 3 — Read the rules before you run anything

Open these two files and skim them:

- [`sanitize.rules`](./sanitize.rules) — the exact list of paths the
  sanitizer will strip or rewrite. If you see something missing or
  something too aggressive, edit the file before step 5.
- [`exclude.list`](./exclude.list) — the paths the capture will skip.
  The capture script will also dynamically add every non-OS mount it finds
  (data pools, network shares, FUSE mounts) to this list at runtime, so the
  static list is just the baseline.

### Step 4 — Run the Phase A capture

Phase A is small and fast — just the kernel, modules, firmware, and a JSON
inventory of your hardware/mount layout. The maintainer thinks this is
likely enough on its own to reverse the CRC routine.

```sh
sudo ./scripts/image_capture/capture.sh \
    --phase a \
    --out /mnt/external/ugos-capture
```

Replace `/mnt/external/ugos-capture` with a path on your external drive or
any partition that is **not** the system disk. The script will refuse to
run if you point it at the same filesystem as `/`.

Expected output: a directory named
`capture-phase-a-<hostname>-<timestamp>/` containing:

```
inventory.json     ← your hw/mount layout, kernel version, fstab, etc.
manifest.json      ← sha256 of every chunk
capture.log        ← full transcript of the capture, including warnings
include.list       ← what tar was told to read
exclude.list       ← static excludes + the dynamic mount excludes
capture.tar.zst.0000
capture.tar.zst.0001
...
```

### Step 5 — Read `capture.log`

Open it and scan for:

- Anything that looks like it came from `/volume*`, `/mnt/*`, `/media/*`,
  or any other data-pool path. There should be **nothing**. If you see
  something, stop and open a comment on the issue — that's a bug we need
  to fix before continuing.
- The line near the top that lists the dynamic mount excludes. Confirm
  your data pools are listed there.

### Step 6 — Sanitize

```sh
sudo ./scripts/image_capture/sanitize.sh \
    --in  /mnt/external/ugos-capture/capture-phase-a-<hostname>-<timestamp> \
    --out /mnt/external/ugos-sanitized
```

This extracts the captured tarball into a staging directory under `--out`,
applies the rules in `sanitize.rules` (logging every action), and re-tars
the redacted result. The original capture is never modified. Your live
system is never touched.

Output:

```
sanitized.tar.zst.0000
sanitized.tar.zst.0001
...
manifest.json
sanitize.log          ← every STRIP and REPLACE action
diffs/
    passwd.diff       ← unified diff of /etc/passwd
    shadow.diff       ← unified diff of /etc/shadow
    fstab.diff        ← unified diff of /etc/fstab
inventory.json        ← copied from the capture (non-sensitive)
```

### Step 7 — Review before uploading

Read **all** of these:

- `sanitize.log` end-to-end. Each `STRIP` line says exactly what was removed.
  Each `REPLACE` line says what was rewritten.
- `diffs/passwd.diff`, `diffs/shadow.diff`, `diffs/fstab.diff`. These three
  files are the most identity-bearing, so the sanitizer always emits a diff
  for them so you can see exactly what changed.
- If something looks wrong, do **not** upload. Open a comment on the issue
  and we'll iterate.

### Step 8 — Upload

Drop the contents of `--out` somewhere the maintainer can reach. Anywhere
you trust works:

- Your own object storage / NAS share with a temporary link.
- A one-shot transfer service (transfer.sh, croc, magic-wormhole, etc.).
- Whatever you prefer.

Tell the maintainer where to find it via the issue.

### Step 9 — Optional: Phase B

Only if the maintainer comes back and says Phase A wasn't enough. Phase B
captures the entire sanitized-candidate rootfs (typically 2–8 GB
compressed). Same flow, just `--phase b`:

```sh
sudo ./scripts/image_capture/capture.sh --phase b --out /mnt/external/ugos-capture
sudo ./scripts/image_capture/sanitize.sh \
    --in  /mnt/external/ugos-capture/capture-phase-b-<hostname>-<timestamp> \
    --out /mnt/external/ugos-sanitized-b
```

---

## Trust model in one paragraph

The capture script **only reads** from your live system; it refuses to write
to system paths and refuses if the output directory is on the same
filesystem as `/`. `tar --one-file-system` plus dynamic exclusion of every
non-OS mount keeps the archive boundary tight even if UGOS bind-mounts pool
content into rootfs paths. The sanitize script **only modifies a staging
copy**; it never reads or writes outside the directory you pass via `--out`.
The root password reset applies **only to the staging copy**, not your live
root account.

---

## Files in this directory

| File | Runs where | Purpose |
| --- | --- | --- |
| `README.md` | — | This file. |
| `capture.sh` | volunteer NAS | Live, read-only capture. |
| `exclude.list` | volunteer NAS | Static rootfs-tar exclude patterns. |
| `sanitize.sh` | volunteer NAS | Redact secrets from the captured tarball. |
| `sanitize.rules` | volunteer NAS | Reviewable STRIP / REPLACE rules. |
| `test_sanitize.sh` | anywhere | Decoy test — plants 60 fake secrets and asserts the sanitizer removes them all. Runs locally without root. |
| `rebuild_qcow2.sh` | maintainer | Builds a bootable VM from the sanitized output. |

---

## Verifying the tooling yourself

If you'd like to confirm the sanitizer actually catches what it claims to,
run the included decoy test on any Linux box (no root needed):

```sh
bash ./scripts/image_capture/test_sanitize.sh
```

It plants 60 decoy files matching every category in `sanitize.rules` —
fake SSH keys, AWS credentials, WireGuard configs, samba secrets,
ugreen tokens, PEMs, history files — and asserts every one of them is
removed. It also asserts that OS-required files (`/etc/fstab`, the kernel,
the modules) survive. Current result: **59 pass, 0 fail.**

---

## If something goes wrong

- Don't upload anything.
- Open a comment on
  [issue #1](https://github.com/manawenuz/ugreen-os-ext4-recovery/issues/1)
  with the relevant output (`capture.log`, `sanitize.log`, or the error
  message).
- The maintainer will iterate on the tooling. There is no rush.

Thank you for helping with this.
