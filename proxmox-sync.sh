#!/usr/bin/env bash
set -euo pipefail

# Proxmox LXC -> OpenWrt DNS synchronization.
# Preview by default; --apply publishes the complete eligible record set.
DNS_SERVER="${PROXMOX_DNS_SYNC_SERVER:-10.47.10.1}"
SSH_KEY="${PROXMOX_DNS_SYNC_KEY:-/root/.ssh/proxmox-dns-sync}"
DOMAIN_ROOT="home.digitaltrainwreck.com"

if [[ $# -gt 1 || ( $# -eq 1 && $1 != --apply ) ]]; then
    printf 'Usage: %s [--apply]\n' "$0" >&2
    exit 2
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

while read -r vmid; do
    [[ -n $vmid ]] || continue
    config=$(pct config "$vmid") || { echo "ERROR: Cannot read CT $vmid" >&2; exit 1; }
    hostname=$(printf '%s\n' "$config" | sed -n 's/^hostname: //p')
    network=$(printf '%s\n' "$config" | sed -n 's/^net0: //p')
    ip=$(printf '%s\n' "$network" | tr ',' '\n' | sed -n 's/^ip=\([^/]*\).*/\1/p')
    vlan=$(printf '%s\n' "$network" | tr ',' '\n' | sed -n 's/^tag=//p')

    # DHCP records are managed by OpenWrt, not by this static-record feed.
    # Skip before hostname/VLAN validation: DHCP-only CTs are out of scope.
    if [[ $ip == dhcp ]]; then
        printf 'INFO: Skipping DHCP-managed CT %s\n' "$vmid" >&2
        continue
    fi

    if [[ -z $hostname || -z $ip || -z $network ]]; then
        printf 'ERROR: Missing static hostname/IP on CT %s\n' "$vmid" >&2
        exit 1
    fi

    case "$vlan" in
        10) domain="management.$DOMAIN_ROOT" ;;
        15) domain="infra.$DOMAIN_ROOT" ;;
        20) domain="servers.$DOMAIN_ROOT" ;;
        30) domain="$DOMAIN_ROOT" ;;
        40) domain="iot.$DOMAIN_ROOT" ;;
        50) domain="guest.$DOMAIN_ROOT" ;;
        60) domain="personal.$DOMAIN_ROOT" ;;
        65) domain="automation.$DOMAIN_ROOT" ;;
        *) printf 'ERROR: Unsupported VLAN %s on CT %s\n' "$vlan" "$vmid" >&2; exit 1 ;;
    esac

    if [[ ! $hostname =~ ^[a-z0-9][a-z0-9-]*$ || ! $ip =~ ^10\.47\.(10|15|20|30|40|50|60|65)\.([0-9]{1,3})$ ]]; then
        printf 'ERROR: Invalid static hostname/IP on CT %s\n' "$vmid" >&2
        exit 1
    fi
    if [[ ${BASH_REMATCH[1]} != "$vlan" || ${BASH_REMATCH[2]} -lt 1 || ${BASH_REMATCH[2]} -gt 254 ]]; then
        printf 'ERROR: Static IP/VLAN mismatch on CT %s\n' "$vmid" >&2
        exit 1
    fi
    printf '%s %s.%s\n' "$ip" "$hostname" "$domain" >> "$TMP"
done < <(pct list | awk 'NR > 1 {print $1}')

# Fail closed: the receiver rejects empty input, and this also prevents
# accidentally removing all previously managed static DNS records.
if [[ ! -s $TMP ]]; then
    echo 'ERROR: No static container records generated; refusing to publish' >&2
    exit 1
fi

if [[ ${1:-} != --apply ]]; then
    printf 'DNS synchronization preview:\n'
    cat "$TMP"
    exit 0
fi

ssh -T -i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
    root@"$DNS_SERVER" < "$TMP"
    
