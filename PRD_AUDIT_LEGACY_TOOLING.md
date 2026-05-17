# Audit findings: legacy volunteer-facing tooling

Three independent reviewers in parallel — safety / safety+correctness / UX.
Targets: `scripts/volunteer_validate.sh` and `scripts/image_capture/*`.
Both predate the `volunteer_collect.sh` cycle that produced
`PRD_VOLUNTEER_COLLECTOR.md` and `PRD_AUDIT_VOLUNTEER_COLLECTOR.md`.

## Why this audit happened

After landing BUG-016 and the btrfs lockdown, we built `volunteer_collect.sh`
as a deliberately read-only, sanitised, audited replacement for the older
volunteer-facing scripts. But the older scripts are still in tree, still
linked from `BTRFS_TESTING.md`, and (per the UX lens) the volunteer has no
decision tree to pick between three near-synonymous tools. A formal audit
forces us to either bring the old tools up to the new floor or remove them
from the volunteer path.

## Findings summary

### `scripts/volunteer_validate.sh` — Lens 1 (safety)

| Tag      | Issue                                                                                                  |
|----------|--------------------------------------------------------------------------------------------------------|
| VV-B1    | `blockdev --setro` then `--setrw` is a write to kernel device state. Ctrl-C between the two leaves the device read-only because the restore lives outside the trap. |
| VV-B2    | No sanitisation. Tarball ships raw hostnames, MACs, IPs, disk serials, WWNs, UUIDs to public issues. |
| VV-S1    | Output path (`$REPO_ROOT`) is not gated; on UGOS volunteers commonly clone into `/volume1/...`, landing the tarball inside the very btrfs pool under inspection. |
| VV-S2/S3 | Trap cleanup doesn't cover the `--setrw` restore or the probe-mount unmount path. |
| VV-S4    | No "is this actually btrfs?" pre-flight. A typo like `/dev/sda` vs `/dev/sda1` produces confusing patcher errors that look like real validation failures. |

**Verdict (Lens 1):** patcher invocations are strictly read-only; mount
options are correct (`rescue=nologreplay` legitimately suppresses log
replay); no `mkfs`/`dd of=`/`dmsetup create` anywhere. The data-loss
exposure is the `setro/setrw` bracket and the privacy regression of an
unsanitised bundle.

**Lens 1 recommendation:** deprecate `volunteer_validate.sh` in favour
of `volunteer_collect.sh`. The new collector already captures everything
the validator does (full 64 KiB SB region, `dump-super` ground truth,
dmesg, system geometry) plus more, plus sanitisation, plus gated
output path. The mount-probe step is the validator's only unique
contribution and is also the step with the unsafe `setro/setrw` bracket.
We don't need to migrate that step.

### `scripts/image_capture/*` — Lens 2 (safety + correctness)

| Tag      | Issue                                                                                                  |
|----------|--------------------------------------------------------------------------------------------------------|
| IC-B1    | `apply_strip` recursively `rm -rf`'s anything whose basename matches a glob — no `-type f` filter. `**/secret*` eats CPython stdlib `secrets.py`; `**/*.pem` eats system CA bundle PEMs; `**/*.key` eats Xorg/keyboard keys. The "59 pass, 0 fail" test harness misses this because its keepers list contains no library files. |
| IC-B2    | `inventory.json` is documented as "non-sensitive metadata" and shipped sanitiser-untouched, but it contains unmodified hostname, mount UUIDs, **block-device serials via `lsblk -O`**, kernel cmdline. Volunteers were told it was safe to share. |
| IC-B3    | Phase B captures the live UGOS rootfs without quiescing — no fs-freeze, no snapshot. Any sqlite/btree being written produces a torn copy; resulting VM may not boot. |
| IC-B4    | `/etc/hostname` is in the KEEPERS list. On consumer NAS, hostname is often serial-derived (`UGREEN-DXP4800-XXXXXXX`). Leaks device serial. |
| IC-S1+   | Long tail of sanitisation gaps: systemd-networkd leases, bluetooth pairings, user dotfiles, `/etc/hosts`, `*.crt`-with-private-key, `authorized_keys2`, etc. |

**Verdict (Lens 2):** the tool's intended scope is real and distinct from
`volunteer_collect.sh` (a bootable UGOS qcow2 is genuinely useful for some
debugging work). But the current `apply_strip` implementation is unsafe in
the colloquial sense: it will produce sanitised images that don't boot
because system libraries are missing, AND it doesn't successfully redact
the metadata it claims to. Both failure modes happen silently.

**Lens 2 recommendation:** keep `image_capture/` in tree but demote it in
the volunteer flow. Maintainer-requested fallback only. Fix the
`apply_strip` blockers and the `inventory.json` sanitisation gap before
offering it to a second volunteer.

### Both — Lens 3 (UX)

The volunteer-facing surface currently has **three near-synonymous tools**
(`volunteer_validate.sh`, `volunteer_collect.sh`,
`scripts/image_capture/capture.sh`) with overlapping scope and no
decision tree. The top-level `README.md` mentions none of the two
collectors. `BTRFS_TESTING.md` points volunteers at `volunteer_validate.sh`
and at the obsolete `recover_btrfs.sh` "answer N" prompt that no longer
exists. `VOLUNTEER_COLLECT_README.md` and `image_capture/README.md` each
read as if they are *the* volunteer entry point, with no cross-reference.

**Verdict (Lens 3):** the tools are well-built; the onboarding surface
is the problem. Cheapest fix is a decision table in the top-level
`README.md` and reciprocal "see also" pointers between the readmes.

## Resolution

Implemented in the commit landing alongside this PRD:

1.  **`scripts/volunteer_validate.sh` — deprecated.** A loud
    deprecation banner prints at script start, redirecting volunteers
    to `volunteer_collect.sh` with one command line. The script still
    runs (we're not removing it; maintainers may still want it as a
    local smoke test) but no longer instructs the volunteer to proceed
    to `recover_btrfs.sh`'s obsolete prompt. The data-loss blockers
    (VV-B1, VV-B2) are *not* fixed — the script is no longer pointed
    at any volunteer, so the floor we'd need to reach to ship it again
    is the new collector's floor, and at that point we just ship the
    new collector.

2.  **`scripts/image_capture/README.md` — demoted.** A "Status" callout
    at the top says this is a maintainer-requested fallback, lists the
    known blockers (IC-B1..B4) plainly, and points volunteers at
    `volunteer_collect.sh` as the default. The blockers themselves are
    *not* fixed in this commit (they require a careful rule-by-rule
    review of `sanitize.rules` and a much-extended keepers list in
    `test_sanitize.sh`); they are documented as preconditions for any
    future volunteer use.

3.  **Top-level `README.md` — decision table added.** A 10-line table
    near the "Volunteer Testing" section tells a stranger which tool to
    run, when, how big the output is, and what to expect. Reciprocal
    pointers between the three readmes follow.

4.  **`tests/test_crc32c.py` regression suite — pinned by CI.** Separate
    commit. GitHub Actions workflow runs the unit tests plus `bash -n`
    syntax-checks every shell script on every push and PR.
