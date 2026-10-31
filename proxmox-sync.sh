#!/bin/bash
set -euo pipefail

# Runs on Proxmox; preview by default, --apply publishes.
DNS_SERVER="10.47.10.1"
SSH_KEY="/root/.ssh/proxmox-dns-sync"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

for vmid in $(pct list | awk 'NR > 1 {print $1}'); do
    config=$(pct config "$vmid")
    hostname=$(printf '%s\n' "$config" | sed -n 's/^hostname: //p')
    network=$(printf '%s\n' "$config" | sed -n 's/^net0: //p')
    ip=$(printf '%s\n' "$network" | tr ',' '\n' | sed -n 's/^ip=\([^/]*\).*/\1/p')
    vlan=$(printf '%s\n' "$network" | tr ',' '\n' | sed -n 's/^tag=//p')

    case "$vlan" in
        10) domain="management.home.example.com" ;;
        15) domain="infra.home.example.com" ;;
        20) domain="servers.home.example.com" ;;
        30) domain="home.example.com" ;;
        40) domain="iot.home.example.com" ;;
        50) domain="guest.home.example.com" ;;
        60) domain="personal.home.example.com" ;;
        *) echo "ERROR: Unsupported VLAN $vlan on CT $vmid" >&2; exit 1 ;;
    esac

    if [[ -z "$hostname" || -z "$ip" || "$ip" == "dhcp" ]]; then
        echo "ERROR: Missing static hostname/IP on CT $vmid" >&2
        exit 1
    fi
    printf '%s %s.%s\n' "$ip" "$hostname" "$domain" >> "$TMP"
done

if [[ ! -s "$TMP" ]]; then
    echo "ERROR: No container records generated" >&2
    exit 1
fi

if [[ "${1:-}" != "--apply" ]]; then
    echo "DNS synchronization preview:"
    cat "$TMP"
    exit 0
fi

ssh -T -i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
    root@"$DNS_SERVER" < "$TMP"
    