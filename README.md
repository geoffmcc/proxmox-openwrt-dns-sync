
## OpenWrt dnsmasq and ujail compatibility

### Important: Do not restart dnsmasq for routine DNS synchronization

OpenWrt 25.12 runs dnsmasq inside a `ujail` environment.

The generated hosts file is individually mounted inside this jail:

```text
/etc/hosts.proxmox-sync
```

This has important consequences for how DNS records must be updated.

### Problem 1: Restarting dnsmasq can interrupt DNS and DHCP

The original receiver used:

```sh
mv -f "$TMP" "$DEST"
/etc/init.d/dnsmasq restart
```

On the tested OpenWrt 25.12.6 installation, restarting dnsmasq triggered repeated `udhcpc` attempts.

The remote synchronization exceeded the Proxmox systemd service's 30-second timeout.

The restart was interrupted, leaving dnsmasq stopped.

Because AdGuard Home forwarded internal DNS queries to OpenWrt, internal hostname resolution failed with SERVFAIL.

### Problem 2: Atomic replacement breaks the jail's file reference

OpenWrt's ujail bind-mounts the generated hosts file.

Replacing that file using `mv` or BusyBox `cp` changes its inode.

The host then sees the new file, while dnsmasq's jail may continue referencing the old inode.

Consequently, SIGHUP can succeed without loading the new DNS records.

This was verified by comparing:

```sh
ls -li /etc/hosts.proxmox-sync
```

With:

```sh
ls -li /proc/ACTUAL_DNSMASQ_PID/root/etc/hosts.proxmox-sync
```

The original failure also appeared in `/proc/ACTUAL_DNSMASQ_PID/mountinfo` as a mount referencing a deleted hosts file.

### Solution: Preserve the inode and signal dnsmasq

The corrected receiver writes through the existing file:

```sh
cat "$TMP" > "$DEST"
```

This preserves the file's inode.

It then asks OpenWrt's service manager to send SIGHUP:

```sh
ubus call service signal '{"name":"dnsmasq","signal":1}'
```

SIGHUP causes dnsmasq to reread files supplied through `addn-hosts` without a full service restart.

The receiver also:

- Validates incoming records.
- Rejects empty or malformed updates.
- Checks that dnsmasq is running.
- Saves previous records for recovery.
- Verifies that the written file matches the input.
- Verifies each hostname resolves to its expected IP.
- Attempts to restore previous records on failure.
- Logs success and failure messages.

### First installation or migration from the original receiver

Create the generated hosts file before starting dnsmasq:

```sh
touch /etc/hosts.proxmox-sync
chmod 644 /etc/hosts.proxmox-sync
```

Configure dnsmasq to use it through OpenWrt UCI:

```text
list addnhosts '/etc/hosts.proxmox-sync'
```

If migrating from an installation that previously replaced the hosts file, the jail may still reference a deleted inode.

A controlled dnsmasq restart is required to recreate that mount.

Perform this directly on OpenWrt during a maintenance window, with independent access to the router.

Afterward, verify that the host and jailed process reference the same inode.

Do not repeatedly restart dnsmasq during normal synchronization.

### Verification

Check the service:

```sh
/etc/init.d/dnsmasq status
```

Check DNS resolution:

```sh
nslookup jellyfin.servers.home.digitaltrainwreck.com 10.47.15.1
```

Check the generated records:

```sh
cat /etc/hosts.proxmox-sync
```

Check the inode:

```sh
ls -li /etc/hosts.proxmox-sync
```

For an end-to-end test, add a temporary valid record to a complete copy of the existing hosts file, submit it through the receiver, and confirm:

1. The temporary hostname resolves.
2. The file inode remains unchanged.
3. dnsmasq remains running.
4. Restoring the original records removes the temporary hostname.

Always verify that your test input includes every existing record before submitting it.

### Known limitations

The in-place update is not atomic.

A crash or power loss during the write could leave partially written records.

The rollback mechanism is best-effort and does not guarantee recovery from every failure.

DNS verification is performed against the configured OpenWrt DNS address and depends on BusyBox nslookup output formatting.

The current implementation is designed for one dnsmasq instance and the specific VLAN/domain mappings configured in the script.

Do not assume it is portable to other OpenWrt configurations without testing.

### Tested environment

- Proxmox VE 9.2.24
- OpenWrt 25.12.6
- dnsmasq running under ujail
- AdGuard Home forwarding the internal DNS zone to OpenWrt
- Six Proxmox LXC records
- Static IPv4 addresses with VLAN-aware hostnames

Tested successfully:

- Invalid record rejection
- Unchanged-record handling
- Adding a temporary DNS record
- Removing the temporary DNS record
- Preserving the hosts file inode
- Keeping dnsmasq running during synchronization
- Automatic execution through the Proxmox systemd timer
```
