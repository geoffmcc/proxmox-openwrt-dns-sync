# Proxmox LXC DNS Sync for OpenWrt

Synchronize **statically addressed Proxmox LXC containers** into OpenWrt's
`dnsmasq` local DNS, using their Proxmox hostname and VLAN. DHCP-managed
containers are intentionally skipped: OpenWrt can manage their names through
its DHCP leases.

The integration uses a short-lived SSH connection from Proxmox to OpenWrt and
a systemd timer. It does not require another container, daemon, or DNS server.

## How it works

1. `proxmox-sync.sh` reads container configurations using `pct`.
2. It skips containers whose `net0` uses `ip=dhcp`.
3. For eligible static containers, it builds `IP hostname.domain` records from
   the hostname, static IPv4 address, and VLAN tag.
4. Preview mode displays the proposed records without changing OpenWrt.
5. `--apply` sends the complete managed record set over restricted SSH to
   `openwrt-receiver.sh`.
6. The receiver validates records, updates `/etc/hosts.proxmox-sync`, signals
   `dnsmasq` to reload its additional hosts file, and checks DNS resolution.

The sender refuses to publish if it finds invalid static configuration or
generates zero static records. It does not silently wipe the DNS file.

## Domain and VLAN mapping

The scripts are configured for the `10.47.0.0` private network and
`home.digitaltrainwreck.com` domain. Adapt **both scripts** before using them
on another network.

| VLAN | Subnet | DNS suffix |
| --- | --- | --- |
| 10 | `10.47.10.0/24` | `management.home.digitaltrainwreck.com` |
| 15 | `10.47.15.0/24` | `infra.home.digitaltrainwreck.com` |
| 20 | `10.47.20.0/24` | `servers.home.digitaltrainwreck.com` |
| 30 | `10.47.30.0/24` | `home.digitaltrainwreck.com` |
| 40 | `10.47.40.0/24` | `iot.home.digitaltrainwreck.com` |
| 50 | `10.47.50.0/24` | `guest.home.digitaltrainwreck.com` |
| 60 | `10.47.60.0/24` | `personal.home.digitaltrainwreck.com` |

For example, a container named `jellyfin` on VLAN 20 with static address
`10.47.20.10` produces:

```text
10.47.20.10 jellyfin.servers.home.digitaltrainwreck.com
```

## Files

| File | Role |
| --- | --- |
| `proxmox-sync.sh` | Proxmox-side sender; preview or publish |
| `openwrt-receiver.sh` | OpenWrt-side validation and DNS update |
| `test-proxmox-sync.sh` | Mocked sender regression test |
| `README.md` | Project overview and usage |

## Prerequisites

- Proxmox VE with the `pct` command and access to LXC configuration.
- OpenWrt with `dnsmasq`, `ubus`, and a configured additional hosts file.
- An SSH key and tightly restricted command on OpenWrt that runs the receiver.
- A known working DNS path to OpenWrt for validation.
- At least one eligible static LXC record; an all-DHCP inventory is not
  published by this version.

The receiver expects `/etc/hosts.proxmox-sync` to exist and `dnsmasq` to be
configured to read it through `addn-hosts`.

**Security:** The Proxmox script connects as `root` using a dedicated key in
batch mode. Restrict that key on OpenWrt to the receiver command and disable
unnecessary SSH capabilities (port forwarding, PTY, etc.). Do not use an
unrestricted general-purpose root SSH key for this integration.

## Configuration

The Proxmox sender defaults to:

```bash
DNS_SERVER=10.47.10.1
SSH_KEY=/root/.ssh/proxmox-dns-sync
```

These can be overridden with environment variables
`PROXMOX_DNS_SYNC_SERVER` and `PROXMOX_DNS_SYNC_KEY`.

The OpenWrt receiver uses:

```sh
DEST=/etc/hosts.proxmox-sync
DNS_SERVER=10.47.15.1
```

Review these values, the VLAN mappings, and the local DNS forwarding setup
before installation. The sender's actual deployed path may differ from the
filename in this gist.

## Usage on Proxmox

Run the sender as an account authorized to inspect Proxmox containers and use
the configured SSH key (typically root).

Preview without modifying DNS:

```bash
bash proxmox-sync.sh
```

Apply the complete record set:

```bash
bash proxmox-sync.sh --apply
```

A DHCP container produces an informational diagnostic such as:

```text
INFO: Skipping DHCP-managed CT 106
```

That is normal, not a service failure. An invalid static configuration is
still an error. The script exits nonzero rather than publishing an incomplete
record set.

### Automation

The sender can be installed at `/usr/local/sbin/proxmox-dns-sync` and invoked
by a systemd oneshot service and timer. An existing installation may already
have `proxmox-dns-sync.service` and `proxmox-dns-sync.timer` configured.

Check a deployed timer and service with:

```bash
systemctl list-timers proxmox-dns-sync.timer
systemctl status proxmox-dns-sync.service --no-pager -l
journalctl -u proxmox-dns-sync.service -n 50 --no-pager
```

This gist contains the sender and receiver scripts, **not a complete
one-command installer for the SSH restrictions, systemd units, or timer**.
Those parts must be configured for the target systems.

## DHCP behavior and record lifecycle

Only static records are published by this integration. A container with
`net0: ... ip=dhcp ...` is omitted even if it has a Proxmox hostname.

The receiver replaces the **complete managed record set** on each successful
publication. Therefore, when a previously static container switches to DHCP,
its old static record disappears on the next successful sync; its DHCP name
must be managed separately by OpenWrt.

The receiver rejects empty submissions, so an inventory with no static
containers cannot clear the managed file. Manual cleanup is needed if the
last static container is removed.

## OpenWrt `dnsmasq` and `ujail`

On OpenWrt 25.12, `dnsmasq` may run inside `ujail`, which bind-mounts the
additional hosts file. **Do not replace `/etc/hosts.proxmox-sync` by renaming
another file over it:** the jailed process can remain bound to the old inode.

The receiver deliberately writes through the existing file with
`cat "$TMP" > "$DEST"`, then requests a SIGHUP through `ubus`. Routine
synchronization does **not** restart `dnsmasq`.

The receiver performs validation, keeps a temporary recovery copy, checks
the updated contents, and verifies published hostnames. Because the in-place
write is not atomic, recovery after a crash or power loss is best-effort.

If migrating from an older receiver that used atomic file replacement, the
`ujail` bind mount may already reference a deleted inode. Repairing that
condition may require a carefully planned one-time `dnsmasq` restart with
independent access to OpenWrt. Do not do this as part of routine syncs.

### Initial OpenWrt setup

Create the hosts file **before** dnsmasq starts with its additional-hosts
configuration:

```sh
touch /etc/hosts.proxmox-sync
chmod 644 /etc/hosts.proxmox-sync
```

Configure dnsmasq via UCI to include:

```text
list addnhosts '/etc/hosts.proxmox-sync'
```

For an existing installation, do not restart dnsmasq just to apply a normal
record update. When diagnosing a stale bind mount, compare the file inode on
the router to the file visible to the **actual** dnsmasq process:

```sh
ls -li /etc/hosts.proxmox-sync
ls -li /proc/ACTUAL_DNSMASQ_PID/root/etc/hosts.proxmox-sync
```

The original failure occurred when replacing the file changed its inode:
the jailed dnsmasq continued reading the old reference. A full restart also
triggered repeated `udhcpc` attempts in the tested installation, exceeded
the Proxmox service's 30-second timeout, and temporarily disrupted internal
DNS via AdGuard Home. This is why the in-place update and SIGHUP are important.

### Receiver checks

On OpenWrt:

```sh
/etc/init.d/dnsmasq status
cat /etc/hosts.proxmox-sync
nslookup jellyfin.servers.home.digitaltrainwreck.com 10.47.15.1
```

An end-to-end record-add/remove test must submit a **complete copy** of the
current managed records plus the temporary test record, then restore the
complete original set. Never send a single-record test to the live receiver.

## Testing

Run the sender's mocked regression test on a Bash-capable machine:

```bash
bash test-proxmox-sync.sh
```

It verifies that a mixed static/DHCP inventory produces only the static
record and that the SSH submission contains the same record. It does not
exercise a real router, systemd timer, or network connection.

For live verification, first inspect the sender's preview, then apply and
confirm resolution against the configured OpenWrt DNS server. Avoid testing
with partial record submissions, which can replace the complete managed set.

## Limitations

- Reads only `net0` and IPv4 static addresses; not additional interfaces,
  IPv6, or DHCP lease addresses.
- Uses fixed VLAN/domain mappings, not automatic network discovery.
- Requires the configured VLAN and static IPv4 subnet to match.
- Publishes an entire set of managed records, not incremental changes.
- Refuses an empty static-record set.
- Does not configure OpenWrt DHCP, AdGuard Home, SSH authorization, or systemd.
- Assumes one `dnsmasq` instance and the receiver's expected BusyBox `nslookup`
  output during verification.

## Tested environment

The original receiver's in-place update approach was validated on Proxmox
VE 9.2.24 and OpenWrt 25.12.6 with `dnsmasq` running under `ujail`.
The DHCP-aware sender change was validated with mocked `pct` and `ssh`
commands. Verify it against your live configuration before scheduling it.
