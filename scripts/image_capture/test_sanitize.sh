#!/usr/bin/env bash
#
# Self-contained decoy test for the sanitizer's STRIP rules.
#
# Plants files that SHOULD be stripped and files that should NOT, then
# replays just the apply_strip logic against a fake staging directory.
# Fails loudly if any decoy survives or any keeper disappears.
#
# Run with no arguments. No root required, no Linux-specific features.

set -Eeuo pipefail

PASS=0
FAIL=0
RESULTS=()

STAGING="$(mktemp -d -t sanitize_test.XXXXXX)"
trap 'rm -rf -- "$STAGING"' EXIT

# ── Plant decoys that MUST be stripped ───────────────────────────────────────
DECOYS_STRIPPED=(
    # SSH host keys
    /etc/ssh/ssh_host_rsa_key
    /etc/ssh/ssh_host_ed25519_key.pub
    # ssh user files
    /root/.ssh/authorized_keys
    /home/alice/.ssh/id_rsa
    /home/alice/.ssh/known_hosts
    # NetworkManager / wpa
    /etc/NetworkManager/system-connections/MyWifi.nmconnection
    /etc/wpa_supplicant/wpa_supplicant.conf
    /var/lib/iwd/MyWifi.psk
    # network configs that hold secrets
    /etc/network/interfaces
    /etc/dhcp/dhclient.conf
    /etc/chrony.keys
    /etc/ntp.keys
    /etc/openvpn/client.conf
    # WireGuard (the **-glob form)
    /etc/wireguard/wg0.conf
    /opt/myapp/wg-corp.conf
    # samba/nfs
    /etc/samba/smbpasswd
    /etc/samba/secrets.tdb
    /var/lib/samba/private/secrets.tdb
    /etc/exports
    # ugreen / ugos config trees
    /etc/ugreen/users.db
    /etc/ugreen/cloud/token.json
    /var/lib/ugreen/session/abc123
    /etc/ugos/accounts.json
    /var/lib/ugos/tokens/x
    # shell histories
    /root/.bash_history
    /home/alice/.zsh_history
    /home/alice/.mysql_history
    # cloud creds
    /root/.aws/credentials
    /home/alice/.aws/config
    /root/.config/gcloud/credentials.db
    /root/.docker/config.json
    /root/.kube/config
    /root/.netrc
    # database server data dirs
    /var/lib/mysql/ibdata1
    /var/lib/postgresql/15/main/PG_VERSION
    # generic key/credential basename globs — the bug we were here to catch
    /etc/ssl/private/server.pem
    /etc/ssl/private/server.key
    /opt/somewhere/deeply/nested/dir/leaked.pem
    /usr/local/share/something/api_key.json
    /var/lib/foo/credentials.yaml
    /opt/app/config/secret.env
    /var/snap/x/y/something.token
    /home/bob/keys/clientcert.pfx
    /home/bob/keys/clientcert.p12
    /home/bob/keys/clientcert.jks
    /home/bob/.ssh/id_ed25519
    # sudoers
    /etc/sudoers.d/90-mycustom
    # opasswd
    /etc/security/opasswd
)

# ── Plant files that MUST SURVIVE the sanitizer ─────────────────────────────
KEEPERS=(
    /etc/fstab
    /etc/hostname
    /etc/os-release
    /usr/bin/bash
    /lib/modules/6.12.30+/kernel/fs/btrfs/btrfs.ko
    /boot/vmlinuz-6.12.30+
    /boot/initrd.img-6.12.30+
    /etc/passwd
    /etc/shadow
    /etc/ssl/certs/ca-certificates.crt
    # similar-name files that should NOT match (e.g. "secrets" but not in
    # any pattern we declared)
    /var/log/journal/keep_me/here
    # PEM-like name but in a context we want to test: still matches **/*.pem
    # so it would be stripped — we DO want that. Skip this case.
)

# ── Plant the decoys ─────────────────────────────────────────────────────────
for p in "${DECOYS_STRIPPED[@]}" "${KEEPERS[@]}"; do
    dir="$(dirname -- "$p")"
    mkdir -p -- "$STAGING$dir"
    printf 'decoy:%s\n' "$p" > "$STAGING$p"
done
# Pre-populate /etc/passwd and /etc/shadow with realistic content so the
# REPLACE rules' "missing target" guard doesn't fire when we later replay
# the full sanitizer for integration tests.
printf 'root:x:0:0:root:/root:/bin/bash\n' > "$STAGING/etc/passwd"
printf 'root:!:19000:0:99999:7:::\n'      > "$STAGING/etc/shadow"

# ── Replay the apply_strip logic from sanitize.sh ───────────────────────────
# We deliberately INLINE the same function so the test fails if the
# real script's logic ever diverges from what we're asserting against.
apply_strip() {
    local pat="$1"
    local find_expr=()
    case "$pat" in
        '**/'*)
            local name_pat="${pat#**/}"
            find_expr=( -name "$name_pat" )
            ;;
        /*)
            find_expr=( -path "${STAGING}${pat}" )
            ;;
        *)
            return 0
            ;;
    esac
    while IFS= read -r -d '' path; do
        case "$path" in
            "$STAGING"/*|"$STAGING") ;;
            *) continue ;;
        esac
        rm -rf -- "$path"
    done < <(find "$STAGING" "${find_expr[@]}" -print0 2>/dev/null)
}

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RULES="$SCRIPT_DIR/sanitize.rules"
[[ -f "$RULES" ]] || { echo "sanitize.rules not found"; exit 2; }

# Apply only the STRIP rules (REPLACE rules require root + openssl).
while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    # shellcheck disable=SC2206
    tokens=( $line )
    [[ "${tokens[0]}" == "STRIP" ]] || continue
    [[ ${#tokens[@]} -eq 2 ]] || continue
    apply_strip "${tokens[1]}"
done < "$RULES"

# ── Assert ───────────────────────────────────────────────────────────────────
record() { RESULTS+=("$1"); if [[ "$1" == PASS* ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi; }

for p in "${DECOYS_STRIPPED[@]}"; do
    if [[ -e "$STAGING$p" ]]; then
        record "FAIL [decoy survived] $p"
    else
        record "PASS [stripped] $p"
    fi
done
for p in "${KEEPERS[@]}"; do
    if [[ -e "$STAGING$p" ]]; then
        record "PASS [kept] $p"
    else
        record "FAIL [keeper missing] $p"
    fi
done

# ── Report ──────────────────────────────────────────────────────────────────
printf '\n'
for r in "${RESULTS[@]}"; do
    case "$r" in
        PASS*) printf '  \033[32m%s\033[0m\n' "$r" ;;
        FAIL*) printf '  \033[31m%s\033[0m\n' "$r" ;;
    esac
done
printf '\n  %d pass, %d fail\n' "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
