# WireGuard Dual Egress SOCKS5 Gateway

**Release: 1.2**

A set of shell scripts for deploying two independent WireGuard egress gateways on an Ubuntu VPS.

- **WG1** routes client traffic directly through the VPS.
- **WG2** routes client traffic through an isolated `sing-box` TUN and an upstream SOCKS5 proxy.
- The **VPS itself** continues to use its normal Internet connection through `eth0`.

This allows a single VPS to provide both a normal WireGuard VPN and a proxy-routed WireGuard VPN without forcing the VPS itself through the proxy.

---

## Features

- Two independent WireGuard gateways
- Direct Internet egress through the VPS (`wg1`)
- SOCKS5 proxy egress (`wg2`)
- Linux network namespace isolation
- `sing-box` TUN integration
- Policy-based routing
- nftables NAT
- Automatic systemd startup
- WG2 kill-switch behavior
- Automatic WireGuard client creation
- Automatic IP allocation for new clients
- WireGuard preshared keys
- QR code generation
- SOCKS5 proxy replacement without reinstalling the server
- Configuration validation and rollback
- Proxy connectivity checks and retries

---

## Requirements

- Ubuntu 24.04 LTS
- Root or `sudo` access
- Public IPv4 address on the VPS
- UDP port `51820` reachable for WG1
- UDP port `51821` reachable for WG2
- An upstream SOCKS5 proxy
- SOCKS5 username/password authentication
- A clean VPS is strongly recommended

The setup script installs the required packages automatically.

> **Proxy protocol**
>
> Release 1.2 supports **SOCKS5 upstream proxies**.
>
> HTTP/HTTPS upstream proxy protocols are not currently supported.
>
> This does **not** mean that HTTP or HTTPS websites cannot be accessed through WG2. Web browsing, HTTPS connections, applications, and other normal client traffic can pass through WG2. Only the connection between `sing-box` and the upstream proxy must use SOCKS5.

---

## WG1 vs WG2

| Gateway | Traffic path | Public IP |
| --- | --- | --- |
| `wg1` | Client → WireGuard → VPS → `eth0` → Internet | VPS IP |
| `wg2` | Client → WireGuard → `proxy-ns` → `sing-box` → SOCKS5 → Internet | Proxy IP |
| VPS host | VPS → `eth0` → Internet | VPS IP |

---

## Architecture

```text
                    ┌── wg1 ──> eth0 ──> Internet
                    │           VPS IP
Phone / PC ───────> VPS
                    │
                    └── wg2
                         │
                         ▼
                    routing table 201
                         │
                         ▼
                     veth-host
                         │
                         ▼
                     proxy-ns
                         │
                         ▼
                    routing table 202
                         │
                         ▼
                       sbtun0
                         │
                         ▼
                     sing-box
                         │
                         ▼
                      SOCKS5
                         │
                         ▼
                      Internet
                      Proxy IP
```

The VPS host itself stays outside the proxy path:

```text
VPS
├── SSH
├── Docker
├── nginx
├── Websites
├── APIs
└── Other services
        │
        ▼
      eth0
        │
        ▼
    Internet
    VPS IP
```

---

## How It Works

### WG1

`wg1` is a standard WireGuard VPN.

Traffic path:

```text
Client
  │
  ▼
wg1
  │
  ▼
VPS
  │
  ▼
NAT
  │
  ▼
eth0
  │
  ▼
Internet
```

The public IP visible to websites is the **VPS public IP**.

### WG2

`wg2` is the proxy-routed WireGuard gateway.

Traffic path:

```text
Client
  │
  ▼
wg2
  │
  ▼
Policy routing table 201
  │
  ▼
veth-host
  │
  ▼
proxy-ns
  │
  ▼
Policy routing table 202
  │
  ▼
sbtun0
  │
  ▼
sing-box
  │
  ▼
SOCKS5 proxy
  │
  ▼
Internet
```

The public IP visible to websites is the **SOCKS5 proxy IP**.

### VPS traffic

The VPS itself does not use the SOCKS5 proxy.

For example:

```text
SSH
Docker
nginx
Websites
APIs
    │
    ▼
  eth0
    │
    ▼
Internet
```

This means a SOCKS5 proxy failure does not normally affect SSH or services hosted directly on the VPS.

---

## WG2 Kill Switch

WG2 does not intentionally fall back to direct VPS Internet access.

If `sing-box` or the upstream SOCKS5 proxy becomes unavailable:

```text
WG1 -> Internet works

VPS -> Internet works

SSH -> works

Docker -> works

Web services -> work

WG2 -> Internet unavailable
```

Instead of:

```text
WG2 -> VPS public IP
```

This prevents WG2 clients from silently leaking traffic through the VPS public IP when the proxy path fails.

---

# Quick Start

Make the installer executable:

```bash
chmod +x setup-double-wireguard-proxy-interactive.sh
```

Run it:

```bash
sudo ./setup-double-wireguard-proxy-interactive.sh
```

The installer asks for:

```text
SOCKS5 proxy IP/host
SOCKS5 proxy port
SOCKS5 username
SOCKS5 password
```

The proxy password is hidden while typing.

> The setup script is designed for a clean VPS.
>
> Review the script before running it on a server that already has WireGuard, nftables, custom policy routing, network namespaces, or custom systemd networking configuration.

---

# Scripts

The project contains four main scripts:

```text
setup-double-wireguard-proxy-interactive.sh
add-wg1-client.sh
add-wg2-client.sh
change-wg2-proxy.sh
```

---

## `setup-double-wireguard-proxy-interactive.sh`

Main installation script.

It automatically configures the complete dual-gateway environment.

The script:

- installs WireGuard
- installs nftables
- installs sing-box
- installs required utilities
- enables IPv4 forwarding
- creates `wg1`
- creates `wg2`
- creates WireGuard server keys
- creates the first WG1 client
- creates the first WG2 client
- creates the `proxy-ns` network namespace
- creates the `veth-host <-> veth-proxy` pair
- configures host policy routing
- configures namespace policy routing
- creates the `sbtun0` TUN path
- configures sing-box
- configures SOCKS5 authentication
- creates nftables NAT rules
- creates systemd services
- validates generated JSON
- validates the sing-box configuration
- tests the SOCKS5 proxy
- retries the initial proxy test when necessary
- configures automatic startup after reboot

Run:

```bash
chmod +x setup-double-wireguard-proxy-interactive.sh
sudo ./setup-double-wireguard-proxy-interactive.sh
```

---

# Default Network Layout

## WG1

```text
Server:       10.10.10.1/24
Clients:      10.10.10.2 - 10.10.10.254
UDP port:     51820
```

## WG2

```text
Server:       10.20.20.1/24
Clients:      10.20.20.2 - 10.20.20.254
UDP port:     51821
```

## Namespace veth

```text
veth-host:    172.31.255.1/30
veth-proxy:   172.31.255.2/30
```

## sing-box TUN

```text
sbtun0:       172.30.0.1/30
```

## Policy routing

```text
Host table:        201 / wg2proxy
Namespace table:   202
```

---

# Client Directory Layout

Client files are stored separately for WG1 and WG2.

## WG1 clients

```text
/etc/wireguard/clients-wg1/
```

## WG2 clients

```text
/etc/wireguard/clients-wg2/
```

Example:

```text
/etc/wireguard/
├── wg1.conf
├── wg1-private.key
├── wg1-public.key
├── wg2.conf
├── wg2-private.key
├── wg2-public.key
│
├── clients-wg1/
│   ├── client1.conf
│   ├── client1.private.key
│   ├── client1.public.key
│   └── client1.psk.key
│
└── clients-wg2/
    ├── client1.conf
    ├── client1.private.key
    ├── client1.public.key
    └── client1.psk.key
```

For compatibility, the setup script also creates:

```text
/etc/wireguard/wg1-client1.conf
/etc/wireguard/wg2-client1.conf
```

as symlinks to the first generated client configurations.

---

# Adding a WG1 Client

Use:

```bash
chmod +x add-wg1-client.sh
sudo ./add-wg1-client.sh
```

The script creates a new direct VPN client.

Traffic path:

```text
Client -> wg1 -> VPS -> eth0 -> Internet
```

The script:

- asks for a client name
- finds the next available WG1 IP
- generates a private/public key pair
- generates a WireGuard PresharedKey
- backs up `wg1.conf`
- adds the peer
- validates the server configuration
- applies the peer without restarting the whole WireGuard interface
- rolls back if applying the peer fails
- creates the client configuration
- optionally displays a QR code

Generated files:

```text
/etc/wireguard/clients-wg1/CLIENT.conf
/etc/wireguard/clients-wg1/CLIENT.private.key
/etc/wireguard/clients-wg1/CLIENT.public.key
/etc/wireguard/clients-wg1/CLIENT.psk.key
```

---

# Adding a WG2 Client

Use:

```bash
chmod +x add-wg2-client.sh
sudo ./add-wg2-client.sh
```

The script creates a new proxy-routed WireGuard client.

Traffic path:

```text
Client
  -> wg2
  -> table 201
  -> veth-host
  -> proxy-ns
  -> table 202
  -> sbtun0
  -> sing-box
  -> SOCKS5
  -> Internet
```

The script:

- asks for a client name
- finds the next available WG2 IP
- generates a private/public key pair
- generates a WireGuard PresharedKey
- backs up `wg2.conf`
- adds the peer
- validates the server configuration
- applies the peer
- rolls back on failure
- creates the client configuration
- optionally displays a QR code

Generated files:

```text
/etc/wireguard/clients-wg2/CLIENT.conf
/etc/wireguard/clients-wg2/CLIENT.private.key
/etc/wireguard/clients-wg2/CLIENT.public.key
/etc/wireguard/clients-wg2/CLIENT.psk.key
```

No additional policy-routing rule is required for each WG2 client because the entire:

```text
10.20.20.0/24
```

network is already routed through the proxy path.

---

# Changing the WG2 SOCKS5 Proxy

Run:

```bash
chmod +x change-wg2-proxy.sh
sudo ./change-wg2-proxy.sh
```

The script asks for:

```text
Proxy IP/Host
Proxy port
Proxy username
Proxy password
```

It then:

1. validates the existing JSON configuration
2. validates the current sing-box configuration
3. creates a backup
4. updates the SOCKS5 server
5. updates the SOCKS5 port
6. updates the username
7. updates the password
8. writes valid JSON
9. validates JSON using `python3 -m json.tool`
10. validates the configuration using `sing-box check`
11. restarts `proxy-singbox.service`
12. verifies the proxy routing service
13. tests the local sing-box SOCKS5 path several times
14. tests the upstream SOCKS5 proxy directly when needed
15. restores the previous configuration if validation fails

Backups are stored in:

```text
/etc/sing-box-proxy/backups/
```

---

# Systemd Services

The installation uses the following services:

```text
nftables.service
wg-quick@wg1.service
wg-quick@wg2.service
proxy-netns.service
proxy-singbox.service
proxy-routing.service
```

Check them with:

```bash
systemctl is-active nftables
systemctl is-active wg-quick@wg1
systemctl is-active wg-quick@wg2
systemctl is-active proxy-netns
systemctl is-active proxy-singbox
systemctl is-active proxy-routing
```

Expected result:

```text
active
active
active
active
active
active
```

---

# WireGuard Status

Check WG1:

```bash
wg show wg1
```

Check WG2:

```bash
wg show wg2
```

Or:

```bash
wg show
```

---

# Namespace Verification

Check that the namespace exists:

```bash
ip netns list
```

Inspect interfaces:

```bash
ip netns exec proxy-ns ip addr
```

Inspect routes:

```bash
ip netns exec proxy-ns ip route
```

Inspect policy rules:

```bash
ip netns exec proxy-ns ip rule
```

Inspect routing table 202:

```bash
ip netns exec proxy-ns ip route show table 202
```

Expected proxy route:

```text
default dev sbtun0 scope link
```

---

# Routing Verification

When testing WG2 policy routing, include the incoming interface.

On the VPS host:

```bash
ip route get 8.8.8.8 from 10.20.20.2 iif wg2
```

Expected route:

```text
via 172.31.255.2 dev veth-host table wg2proxy
```

Inside the namespace:

```bash
ip netns exec proxy-ns \
  ip route get 8.8.8.8 from 10.20.20.2 iif veth-proxy
```

Expected route:

```text
dev sbtun0 table 202
```

Using only:

```bash
ip route get 8.8.8.8 from 10.20.20.2
```

is not equivalent to testing a forwarded packet arriving from WG2. The `iif wg2` form should be used when verifying this policy-routing path.

---

# External IP Verification

## VPS

Run:

```bash
curl -4 https://api.ipify.org
```

Expected:

```text
VPS public IP
```

## WG1 client

Open an IP-checking service from a connected WG1 client.

Expected:

```text
Public IP = VPS public IP
```

## WG2 client

Open an IP-checking service from a connected WG2 client.

Expected:

```text
Public IP = SOCKS5 proxy IP
```

---

# Test SOCKS5 Through sing-box

Run:

```bash
ip netns exec proxy-ns \
  curl -4 \
  --connect-timeout 10 \
  --socks5-hostname 127.0.0.1:1081 \
  https://api.ipify.org
```

Expected result:

```text
SOCKS5 proxy public IP
```

A single timeout does not necessarily mean the configuration is broken. Proxy providers can occasionally respond slowly or temporarily reject connections.

---

# sing-box Logs

Recent logs:

```bash
journalctl -u proxy-singbox -n 100 --no-pager
```

Follow logs live:

```bash
journalctl -u proxy-singbox -f
```

Routing service logs:

```bash
journalctl -u proxy-routing -n 100 --no-pager
```

Namespace service logs:

```bash
journalctl -u proxy-netns -n 100 --no-pager
```

---

# QR Codes

The client creation scripts can optionally display QR codes automatically.

They can also be generated manually.

## WG1

```bash
qrencode -t ansiutf8 < /etc/wireguard/clients-wg1/client1.conf
```

## WG2

```bash
qrencode -t ansiutf8 < /etc/wireguard/clients-wg2/client1.conf
```

Other clients:

```bash
qrencode -t ansiutf8 < /etc/wireguard/clients-wg1/CLIENT.conf
```

or:

```bash
qrencode -t ansiutf8 < /etc/wireguard/clients-wg2/CLIENT.conf
```

> **Important:** A WireGuard QR code contains the client configuration, including its private key. Anyone who obtains the QR code may be able to use that VPN client identity.

---

# Temporarily Disable the Proxy Path

To stop the SOCKS5 proxy path:

```bash
sudo systemctl stop proxy-singbox.service
```

Expected behavior:

```text
wg1      -> works
SSH      -> works
Docker   -> works
Web      -> works
VPS      -> normal Internet
wg2      -> no Internet
SOCKS5   -> not used
```

To bring the proxy path back up:

```bash
sudo systemctl restart proxy-singbox.service
sudo systemctl restart proxy-routing.service
```

Verify:

```bash
systemctl is-active proxy-singbox
systemctl is-active proxy-routing
```

Expected:

```text
active
active
```

---

# Reboot Verification

The complete configuration should survive a VPS reboot.

Reboot:

```bash
sudo reboot
```

After reconnecting through SSH, check:

```bash
systemctl is-active nftables
systemctl is-active wg-quick@wg1
systemctl is-active wg-quick@wg2
systemctl is-active proxy-netns
systemctl is-active proxy-singbox
systemctl is-active proxy-routing
```

Check the namespace:

```bash
ip netns list
```

Check the TUN interface:

```bash
ip netns exec proxy-ns ip link show sbtun0
```

Check routing:

```bash
ip route get 8.8.8.8 from 10.20.20.2 iif wg2
```

and:

```bash
ip netns exec proxy-ns \
  ip route get 8.8.8.8 from 10.20.20.2 iif veth-proxy
```

Finally verify:

```text
WG1 -> VPS IP
WG2 -> SOCKS5 proxy IP
VPS -> VPS IP
```

---

# Troubleshooting

## WG1 works but WG2 has no Internet

Check:

```bash
systemctl status proxy-netns --no-pager
systemctl status proxy-singbox --no-pager
systemctl status proxy-routing --no-pager
```

Then:

```bash
ip netns list
ip netns exec proxy-ns ip addr
ip netns exec proxy-ns ip route
ip netns exec proxy-ns ip rule
ip netns exec proxy-ns ip route show table 202
```

Check sing-box:

```bash
journalctl -u proxy-singbox -n 100 --no-pager
```

Test the local SOCKS5 endpoint:

```bash
ip netns exec proxy-ns \
  curl -4 \
  --connect-timeout 10 \
  --socks5-hostname 127.0.0.1:1081 \
  https://api.ipify.org
```

---

## WG2 has a WireGuard handshake but no Internet

A successful WireGuard handshake only confirms that the WireGuard tunnel itself is working.

The remaining path is:

```text
wg2
 -> host policy routing
 -> veth
 -> proxy-ns
 -> namespace policy routing
 -> sbtun0
 -> sing-box
 -> SOCKS5
 -> Internet
```

Check the host route:

```bash
ip route get 8.8.8.8 from 10.20.20.2 iif wg2
```

Then check the namespace route:

```bash
ip netns exec proxy-ns \
  ip route get 8.8.8.8 from 10.20.20.2 iif veth-proxy
```

---

## sing-box is running but the proxy test fails

Check logs:

```bash
journalctl -u proxy-singbox -n 100 --no-pager
```

Validate the configuration:

```bash
python3 -m json.tool /etc/sing-box-proxy/config.json >/dev/null
```

Then:

```bash
sing-box check -c /etc/sing-box-proxy/config.json
```

Possible causes include:

- incorrect proxy hostname/IP
- incorrect port
- incorrect username
- incorrect password
- upstream proxy unavailable
- proxy provider connection limits
- temporary proxy timeout

---

## Check the upstream proxy route

The upstream SOCKS5 server itself must leave the namespace through the VPS path rather than being sent back into `sbtun0`.

For a proxy with IP `PROXY_IP`, check:

```bash
ip netns exec proxy-ns \
  ip route get PROXY_IP from 172.31.255.2
```

It should use:

```text
via 172.31.255.1 dev veth-proxy
```

This prevents a routing loop where the SOCKS5 connection itself would be sent back through the SOCKS5 TUN.

---

# Security

Never publish or commit generated WireGuard configurations, private keys, preshared keys, or SOCKS5 credentials to a public repository.

Keep the following information private:

- WireGuard private keys
- WireGuard preshared keys
- SOCKS5 usernames
- SOCKS5 passwords
- generated WireGuard client configurations
- generated QR codes

In particular, do not publish the contents of:

```text
/etc/wireguard/clients-wg1/
/etc/wireguard/clients-wg2/
/etc/sing-box-proxy/config.json
```

Before committing changes to a public repository, review the files for accidentally included credentials.

---

# Typical Workflow

## Initial installation

```bash
sudo ./setup-double-wireguard-proxy-interactive.sh
```

## Add a direct VPN client

```bash
sudo ./add-wg1-client.sh
```

## Add a proxy-routed VPN client

```bash
sudo ./add-wg2-client.sh
```

## Change the SOCKS5 proxy

```bash
sudo ./change-wg2-proxy.sh
```

---

# Project Files

```text
wireguard-dual-egress-socks5-gateway/
├── README.md
├── setup-double-wireguard-proxy-interactive.sh
├── add-wg1-client.sh
├── add-wg2-client.sh
└── change-wg2-proxy.sh
```

---

# Disclaimer

This project modifies networking, routing, firewall, WireGuard, network namespace, and systemd configuration on the server.

Review the scripts before running them, especially on production systems or servers with existing networking configuration.

A clean VPS is strongly recommended.

Use this project at your own risk.

---

# License

This project can be distributed under the **MIT License**.

If you choose MIT for the GitHub repository, add a `LICENSE` file containing the MIT License text.

---

# Summary

```text
WG1
Client
  │
  ▼
WireGuard wg1
  │
  ▼
VPS
  │
  ▼
eth0
  │
  ▼
Internet

Public IP = VPS IP
```

```text
WG2
Client
  │
  ▼
WireGuard wg2
  │
  ▼
Policy routing table 201
  │
  ▼
veth-host
  │
  ▼
proxy-ns
  │
  ▼
Policy routing table 202
  │
  ▼
sbtun0
  │
  ▼
sing-box
  │
  ▼
SOCKS5 proxy
  │
  ▼
Internet

Public IP = SOCKS5 Proxy IP
```

```text
VPS
SSH / Docker / nginx / Websites / APIs
  │
  ▼
eth0
  │
  ▼
Internet

Public IP = VPS IP
```

---

**Release 1.2**
