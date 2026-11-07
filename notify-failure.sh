#!/bin/bash
set -eu
state=/var/lib/proxmox-dns-sync
install -d -m 0700 "$state"
exec 9>"$state/notification.lock"
flock -x 9
[[ ! -e "$state/failure-notified" ]] || exit 0
systemctl is-failed --quiet proxmox-dns-sync.service || exit 0
{
    printf 'To: root\nSubject: [pve] Proxmox DNS sync failed\n\n'
    printf 'The Proxmox DNS synchronization service failed. It retries every five minutes.\n'
    printf 'Inspect: systemctl status proxmox-dns-sync.service\n'
    printf 'Details: journalctl -u proxmox-dns-sync.service -n 30 --no-pager\n'
} | /usr/sbin/sendmail -oi -t
touch "$state/failure-notified"
