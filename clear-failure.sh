#!/bin/bash
set -eu
state=/var/lib/proxmox-dns-sync
install -d -m 0700 "$state"
exec 9>"$state/notification.lock"
flock -x 9
rm -f "$state/failure-notified"
