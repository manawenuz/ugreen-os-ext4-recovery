# Audit findings: `volunteer_collect.sh` v0.1.0

Three independent reviewers, parallel, non-overlapping mandates. Findings
consolidated below in fix order (data-loss → correctness → UX). Nothing
ships to volunteers until Blockers and Spec-violations are closed.

## Blockers (data-loss / safety / spec-breaking)

| # | Issue                                                                                                  | Source        |
|---|--------------------------------------------------------------------------------------------------------|---------------|
| 1 | `for d in $(ls /dev/mapper/ug_*)` word-splits; device names with spaces/IFS chars break gate           | Lens 1        |
| 2 | `is_mounted_rw` parses `findmnt` with `awk '{print $2}'`; space-bearing SOURCE shifts column; gate fails | Lens 1        |
| 3 | Manifest re-hash uses `head -6`/`tail -n +7` but header is **5 lines** — first recorded file is dropped | Lens 1 + 2    |
| 4 | Sanitisation failure is silent (`|| true` everywhere); a failed scrub still produces a "Bundle:" line  | Lens 1        |
| 5 | `--out-dir` not canonicalised; volunteer can write bundle into `/volume1/...` (their own data tree)    | Lens 1        |
| 6 | Cleanup trap leaves populated WORKDIR on Ctrl-C in `--confirm` mode (README promises otherwise)        | Lens 1        |
| 7 | Hostname scrub uses `/` as sed delimiter without escaping `/`; FQDN/odd hostnames inject               | Lens 1        |
| 8 | "Collector fails if any required item is missing" (PRD §4.1 lead-in) is **not enforced** anywhere      | Lens 2        |
| 9 | Filename drift from PRD §4.1: `_first1MiB` vs `_first_1MiB`; `mdadm_scan/detail` vs `mdadm.txt`; same for lvm/dmsetup/btrfs_versions | Lens 2 |
| 10 | IPv6 scrub absent despite PRD §4.3 listing it                                                          | Lens 1        |

## Should-fix (defence in depth)

- TOCTOU between mount-state check and `dd` reads — re-verify immediately before each capture.
- `--include-config` follows symlinks via `tar`; a hostile config-dir symlink could exfiltrate. Add `--one-file-system`.
- `cleanup` trap captures `rc=$?` from last command, not signal. Separate INT/TERM handlers.
- WORKDIR in `$TMPDIR`/`/tmp` — large `--allow-large` plus tmpfs `/tmp` OOMs. Put WORKDIR next to `--out-dir`.
- Bundle file owned by root; volunteer can't `scp` without sudo. Chown to `$SUDO_USER`.
- `--pool ""` empty arg silently accepted; reject explicitly.

## UX

- Sizes shown as raw bytes (`size=21474836480`); use `numfmt --to=iec-i`.
- Dry-run promises an estimated total size (PRD §5.1.3) but never computes one.
- `--help` dumps the file header; should be a flag table.
- `fail()` has no script-name prefix — not useful in pasted GitHub issues.
- `--confirm` re-invocation hint always echoes `--out-dir` (defaults to `$PWD`).
- No proof of "read-only-by-construction" surfaced in dry-run; volunteer must trust on faith.
- Mounted-rw refusal message asks for acknowledgement without explaining what's being acknowledged.
- Final `Bundle:` line uses bytes and gives no "what next" hint.
- README size section uses jargon ("squashfs layers") and doesn't reassure with a typical-size range.

## Clean

- Read-only construction (no `mount`/`mkfs`/`dd of=…`/`setrw`/`dmsetup create` anywhere reachable).
- Write-flag refusal (`--write/--patch/--fix/--repair/--apply/--commit`) is unconditional and pre-positional.
- Dry-run is the genuine default; `--confirm` cannot be set via env or sourced files.
- Size-cap enforcement fires after every step.
- SB offset math (64 KiB / 64 MiB / 256 GiB) is correct.
- `btrfs inspect-internal dump-super -fa` is captured per pool (oracle for CRC debug).

## Fix order

1. Blockers 1–10 in one editing pass.
2. Should-fix items in same pass where cheap.
3. UX rewordings + numfmt in same pass.
4. Re-run audits (or at least syntax + a manual dry-run) before posting.

## Resolution (v0.2.0)

All 10 Blockers addressed, all 6 Should-fixes addressed, all 9 UX items
addressed. Notable implementation choices:

- **Blocker 1** — replaced `$(ls /dev/mapper/ug_*)` with a `shopt -s nullglob` for-loop over the glob directly.
- **Blocker 2** — `is_mounted_rw` now uses `findmnt -nro OPTIONS --source <dev>`, parsing OPTIONS only.
- **Blocker 3** — manifest is rebuilt from scratch after sanitisation, walking the work dir; no fragile re-hash parse. TAB-separated columns. Header line count is a named variable.
- **Blocker 4** — sanitisation is one Python pass; non-zero exit is fatal; a post-pass `grep -rwIi <hostname>` verification fires if the scrub somehow missed.
- **Blocker 5** — `--out-dir` is canonicalised via `readlink -f` and refused if it resolves under `/volume*`, `/home`, `/overlay`, `/rootfs`, `/mnt/factory`, `/root`, `/var/lib`.
- **Blocker 6** — split EXIT trap (best-effort cleanup) from INT/TERM/HUP (sets INTERRUPTED=1, exits 130). WORKDIR is removed on every non-success path.
- **Blocker 7** — hostname scrub moved into Python with `re.escape`; no sed delimiter risk.
- **Blocker 8** — explicit REQUIRED-artefacts list checked post-capture; bundle is refused if any are missing, with a list of which.
- **Blocker 9** — filenames now match PRD §4.1 exactly: `system/mdadm.txt`, `system/lvm.txt`, `system/dmsetup.txt`, `system/btrfs_versions.txt`, `sb/<pool>_first_1MiB.bin.gz`.
- **Blocker 10** — IPv6 scrub included in the Python pass (public addresses → `2001:db8::1`).

- Should-fixes: TOCTOU re-check before each per-pool `dd`; `tar --one-file-system` on config and module-tree and EFI captures; WORKDIR is now `mktemp -d` next to `--out-dir` so cap and disk-space apply to one filesystem; bundle is chowned to `$SUDO_USER`; empty `--pool` rejected.

- UX: `hsize()` via `numfmt --to=iec-i`; dry-run computes and prints estimated bundle size; `--help` is a real flag table (and works without root); `fail()` prefixes script name; `--confirm` re-invocation hint only echoes flags the user passed (via `${USER_ARGS[@]}`); dry-run includes a "Tools this script will INVOKE / will NEVER invoke" listing; mounted-rw refusal now explains *what* you're acknowledging; final `Bundle:` line uses human sizes and tells the volunteer they're done.

Manual smoke-tested: `--help`, `--version`, `--write`, `--bogus`, no-args all behave correctly with and without root. Full dry-run / capture path requires a Linux box with UGOS and is left for the next volunteer to exercise.
