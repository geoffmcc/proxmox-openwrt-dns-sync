#!/bin/sh
set -eu

# Forced SSH command on OpenWrt. Validates IP and VLAN-specific hostname.
DEST=/etc/hosts.proxmox-sync
TMP=$(mktemp /etc/hosts.proxmox-sync.XXXXXX)
trap 'rm -f "$TMP"' EXIT

awk '
BEGIN {
    suffix[10]="management.home.example.com"
    suffix[15]="infra.home.example.com"
    suffix[20]="servers.home.example.com"
    suffix[30]="home.example.com"
    suffix[40]="iot.home.example.com"
    suffix[50]="guest.home.example.com"
    suffix[60]="personal.home.example.com"
}
{
    if (NF != 2 || $1 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)
        exit 1
    split($1, ip, ".")
    split($2, name, ".")
    if (ip[1] != 10 || ip[2] != 47 ||
        !(ip[3] in suffix) || ip[4] < 1 || ip[4] > 254 ||
        name[1] !~ /^[a-z0-9][a-z0-9-]*$/ ||
        $2 != name[1] "." suffix[ip[3]])
        exit 1
    print $1, $2
    count++
}
END { if (count == 0) exit 1 }
' > "$TMP"

# No change = no DNS restart.
if cmp -s "$TMP" "$DEST"; then
    exit 0
fi

chmod 644 "$TMP"
mv -f "$TMP" "$DEST"
/etc/init.d/dnsmasq restart
