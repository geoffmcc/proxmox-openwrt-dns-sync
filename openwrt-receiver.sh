
#!/bin/sh
set -eu

# Proxmox LXC DNS synchronization receiver
# OpenWrt 25.12 / dnsmasq running under ujail
#
# Validates incoming records, updates the existing hosts
# file in place, signals dnsmasq through procd, and
# verifies DNS resolution.
#
# IMPORTANT:
# Do not replace DEST with mv or BusyBox cp.
# The dnsmasq jail retains a bind mount to the file's inode.

DEST=/etc/hosts.proxmox-sync
DNS_SERVER=10.47.15.1

TMP=$(mktemp /tmp/proxmox-dns-incoming.XXXXXX)
BACKUP=$(mktemp /tmp/proxmox-dns-backup.XXXXXX)

cleanup() {
    rm -f "$TMP" "$BACKUP"
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

log() {
    logger -t proxmox-dns-sync "$1"
    echo "$1"
}

error() {
    logger -t proxmox-dns-sync "ERROR: $1"
    echo "ERROR: $1" >&2
}

dns_running() {
    /etc/init.d/dnsmasq status >/dev/null 2>&1
}

reload_dns() {
    ubus call service signal \
        '{"name":"dnsmasq","signal":1}' >/dev/null
}

restore_previous() {
    error "Attempting to restore previous DNS records"

    # Write through the existing inode.
    if cat "$BACKUP" > "$DEST"; then
        if reload_dns; then
            log "Previous DNS records restored and reload requested"
        else
            error "Failed to signal dnsmasq during recovery"
        fi
    else
        error "Failed to restore previous DNS records"
    fi

    return 1
}

# Validate incoming records before modifying live DNS.
if ! awk '
BEGIN {
    suffix[10]="management.home.digitaltrainwreck.com"
    suffix[15]="infra.home.digitaltrainwreck.com"
    suffix[20]="servers.home.digitaltrainwreck.com"
    suffix[30]="home.digitaltrainwreck.com"
    suffix[40]="iot.home.digitaltrainwreck.com"
    suffix[50]="guest.home.digitaltrainwreck.com"
    suffix[60]="personal.home.digitaltrainwreck.com"
}

{
    if (NF != 2 ||
        $1 !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
        invalid=1
        exit 1
    }

    split($1, ip, ".")
    split($2, name, ".")

    if (ip[1] != 10 ||
        ip[2] != 47 ||
        !(ip[3] in suffix) ||
        ip[4] < 1 ||
        ip[4] > 254 ||
        name[1] !~ /^[a-z0-9][a-z0-9-]*$/ ||
        $2 != name[1] "." suffix[ip[3]]) {
        invalid=1
        exit 1
    }

    if (seen[$2]++) {
        invalid=1
        exit 1
    }

    print $1, $2
    count++
}

END {
    if (invalid || count == 0)
        exit 1
}
' > "$TMP"; then
    error "Invalid or empty DNS input"
    exit 1
fi

# Never update records when dnsmasq is stopped.
if ! dns_running; then
    error "dnsmasq is not running"
    exit 1
fi

# The destination must exist to preserve its inode.
if [ ! -f "$DEST" ]; then
    error "DNS hosts file does not exist"
    exit 1
fi

# No change means no reload is necessary.
if cmp -s "$TMP" "$DEST"; then
    exit 0
fi

# Save previous contents for recovery.
if ! cp "$DEST" "$BACKUP"; then
    error "Could not back up current DNS records"
    exit 1
fi

# Update the existing file IN PLACE.
# Shell redirection preserves the inode visible inside ujail.
if ! cat "$TMP" > "$DEST"; then
    error "Failed to write DNS records"
    restore_previous || true
    exit 1
fi

# Verify the contents were written correctly.
if ! cmp -s "$TMP" "$DEST"; then
    error "DNS records differ after writing"
    restore_previous || true
    exit 1
fi

# Signal dnsmasq to reread addn-hosts.
# This does not stop or restart the service.
if ! reload_dns; then
    error "Failed to signal dnsmasq"
    restore_previous || true
    exit 1
fi

if ! dns_running; then
    error "dnsmasq stopped after reload"
    restore_previous || true
    exit 1
fi

# Allow dnsmasq to process SIGHUP.
sleep 1

# Verify every generated hostname resolves to its IP.
while read -r ip hostname; do
    if ! nslookup "$hostname" "$DNS_SERVER" 2>/dev/null |
        grep -Fq "Address: $ip"; then

        error "DNS verification failed for $hostname"
        restore_previous || true
        exit 1
    fi
done < "$TMP"

log "SUCCESS: Proxmox DNS records synchronized and verified"
exit 0
