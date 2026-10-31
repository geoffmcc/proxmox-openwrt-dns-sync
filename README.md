# Automatic Proxmox LXC DNS → OpenWrt

**Static IPs in Proxmox. Automatic hostnames in OpenWrt. No extra container.**

One small script reads `pct` configurations, maps VLANs to DNS suffixes, and sends the resulting records over a restricted SSH connection to OpenWrt. A systemd timer runs it every five minutes.

```text
Proxmox LXCs → sync script → restricted SSH → OpenWrt receiver
                                                ↓
                                    hosts.proxmox-sync
                                                ↓
                                          dnsmasq
                                                ↓
                                     AdGuard / clients
```

> [!IMPORTANT]
> This setup is for **LXCs with static IPv4 addresses on `net0`**. DHCP clients can register through OpenWrt directly. Proxmox VMs need a separate IP discovery approach.

## At a glance

| What | How |
| --- | --- |
| New LXC discovered | `pct list` at every run |
| Domain selected | `tag=` VLAN on `net0` |
| Frequency | Every five minutes |
| OpenWrt access | Dedicated forced-command SSH key |
| DNS storage | Separate `/etc/hosts.proxmox-sync` |
| DNS disruption | Restart only when records actually change |

### Example naming

| VLAN | Suffix | Example |
| --- | --- | --- |
| 10 | `management.home.example.com` | `pve.management.home.example.com` |
| 15 | `infra.home.example.com` | `pulse.infra.home.example.com` |
| 20 | `servers.home.example.com` | `jellyfin.servers.home.example.com` |
| 60 | `personal.home.example.com` | `desktop.personal.home.example.com` |

The scripts also include VLANs 30, 40, and 50. Replace the example domains and `10.47.x.x` addresses with your own.

## Installation

### 1. OpenWrt DNS

Set subnet-scoped domains in `/etc/dnsmasq.conf`:

```ini
domain=management.home.example.com,10.47.10.0/24,local
domain=infra.home.example.com,10.47.15.0/24,local
domain=servers.home.example.com,10.47.20.0/24,local
domain=personal.home.example.com,10.47.60.0/24,local
```

Keep a default domain in OpenWrt UCI if using `dhcp-fqdn`.

For AdGuard Home clients, configure a conditional upstream:

```text
[/home.example.com/]10.47.15.1
```

Create the generated hosts file and register it with dnsmasq:

```sh
touch /etc/hosts.proxmox-sync
chmod 644 /etc/hosts.proxmox-sync
uci add_list 'dhcp.@dnsmasq[0].addnhosts=/etc/hosts.proxmox-sync'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

Run `uci add_list` only once. Verify `addn-hosts=/etc/hosts.proxmox-sync` appears in OpenWrt's generated dnsmasq config.

### 2. Receiver and SSH

Install **`openwrt-receiver.sh`** as `/usr/bin/proxmox-dns-receiver` (`chmod 755`). Customize the VLAN/domain map.

On Proxmox, generate a dedicated key:

```sh
ssh-keygen -t ed25519 -f /root/.ssh/proxmox-dns-sync -N '' -C pve-dns-sync
```

Verify OpenWrt's SSH host fingerprint before accepting it. In `/etc/dropbear/authorized_keys`, preserve existing entries and add the **public key** with a forced command:

```text
command="/usr/bin/proxmox-dns-receiver",no-port-forwarding,no-pty ssh-ed25519 YOUR_PUBLIC_KEY_HERE pve-dns-sync
```

Set `chmod 600 /etc/dropbear/authorized_keys`. Restrict SSH access to trusted network sources, too.

**Security test from Proxmox:**

```sh
printf 'invalid\n' | ssh -T -i /root/.ssh/proxmox-dns-sync \
  -o IdentitiesOnly=yes -o BatchMode=yes root@10.47.10.1 'echo SHOULD_NOT_RUN'
```

Expect failure and **no** `SHOULD_NOT_RUN` output.

### 3. Proxmox sync and scheduling

Install **`proxmox-sync.sh`** as `/usr/local/sbin/proxmox-dns-sync` (`chmod 700`). Configure the router IP and VLAN suffixes.

```sh
# Safe preview
/usr/local/sbin/proxmox-dns-sync

# Publish after reviewing every generated IP/name
/usr/local/sbin/proxmox-dns-sync --apply
```

Install **`proxmox-dns-sync.service`** and **`proxmox-dns-sync.timer`** under `/etc/systemd/system/`:

```sh
systemctl daemon-reload
systemctl start proxmox-dns-sync.service
systemctl enable --now proxmox-dns-sync.timer
systemctl list-timers proxmox-dns-sync.timer
```

## Verify

```sh
# OpenWrt
cat /etc/hosts.proxmox-sync
nslookup pulse.infra.home.example.com 127.0.0.1

# Proxmox
journalctl -u proxmox-dns-sync.service -n 20 --no-pager
```

Once names resolve from the generated file, remove any *overlapping* manual dnsmasq records. Leave unrelated infrastructure records intact.

<details>
<summary><strong>Troubleshooting & limitations</strong></summary>

| Symptom | Check |
| --- | --- |
| Hosts file updates but DNS returns NXDOMAIN | `reload` did not reread `addn-hosts` in this setup; full dnsmasq `restart` worked. Receiver only restarts when changed. |
| Standalone dnsmasq test fails with `dhcp-fqdn` | Test the **active generated OpenWrt config** (find its `-C` argument via `ps`). |
| Authentication fails | Confirm host fingerprint and the Dropbear forced-command key line. |
| New LXC missing | It must have a supported `tag=` and static `ip=` on `net0`. Inspect the timer journal. |
| Multi-NIC LXC | Only `net0` is registered as the primary DNS address. |
| All LXCs removed | Receiver rejects empty input rather than clearing last-known records. |
| VMs and DHCP-assigned LXCs | Not covered by this static LXC synchronization script. |

</details>

---

**Tested:** Six LXCs, including a multi-homed relay, registered successfully with no extra VM, container, or Docker dependency.
