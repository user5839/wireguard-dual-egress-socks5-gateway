# WireGuard Dual Gateway + SOCKS5 Proxy

**Project release: 1.2**

A set of scripts for automatically deploying two independent WireGuard
gateways on a clean Ubuntu VPS.

## Architecture

``` text
                    ┌── wg1 ──> eth0 ──> Internet
                    │           VPS IP
Phone/PC ─────────> VPS
                    │
                    └── wg2 ──> proxy-ns ──> sing-box ──> SOCKS5 ──> Internet
                                                             Proxy IP

                    ┌── SSH
                    ├── Docker
VPS itself ────────┼── Websites
                    ├── APIs
                    └── etc.
                         │
                         └── eth0 ──> Internet
```

## How it works

-   `wg1` is a normal VPN using the VPS public IP.
-   `wg2` routes client traffic through a SOCKS5 proxy.
-   The VPS itself continues to use the normal `eth0` route.
-   SSH, Docker, nginx, websites, APIs, and other VPS services do not
    depend on the proxy.
-   The proxy subsystem is isolated inside the Linux network namespace
    `proxy-ns`.
-   `sing-box` creates the `sbtun0` TUN interface inside `proxy-ns`.
-   Policy routing sends the `10.20.20.0/24` network into the proxy
    namespace.
-   If the proxy is unavailable, `wg2` does not fall back to the VPS
    public IP. This acts as a kill switch.
-   The full configuration is restored automatically after reboot using
    systemd.

------------------------------------------------------------------------

# Scripts

## `setup-double-wireguard-proxy-interactive.sh`

Main installation script.

Designed for a clean Ubuntu VPS.

During startup it asks for:

``` text
Proxy IP/Host
Proxy port
Proxy login
Proxy password
```

The password is hidden while typing.

The script:

-   installs WireGuard;
-   installs nftables;
-   installs sing-box;
-   enables IPv4 forwarding;
-   creates `wg1`;
-   creates `wg2`;
-   creates `proxy-ns`;
-   creates `veth-host <-> veth-proxy`;
-   creates host routing table `201 / wg2proxy`;
-   creates namespace routing table `202`;
-   creates systemd services;
-   creates the first `wg1` client;
-   creates the first `wg2` client;
-   tests the upstream SOCKS5 proxy;
-   tests sing-box;
-   validates JSON;
-   retries the initial proxy test several times.

Run:

``` bash
chmod +x setup-double-wireguard-proxy-interactive.sh
sudo ./setup-double-wireguard-proxy-interactive.sh
```

> The setup script is intended for a clean VPS. Review it before using
> it on a server with existing WireGuard, nftables, or custom routing
> rules.

------------------------------------------------------------------------

# Client directory layout

In project release 1.2, client files are stored in dedicated
directories.

WG1:

``` text
/etc/wireguard/clients-wg1/
```

WG2:

``` text
/etc/wireguard/clients-wg2/
```

Example:

``` text
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

For compatibility, setup also creates:

``` text
/etc/wireguard/wg1-client1.conf
/etc/wireguard/wg2-client1.conf
```

as symlinks.

------------------------------------------------------------------------

## `add-wg1-client.sh`

Creates a new direct VPN client for `wg1`.

Traffic path:

``` text
Client -> wg1 -> VPS -> eth0 -> Internet
```

Run:

``` bash
chmod +x add-wg1-client.sh
sudo ./add-wg1-client.sh
```

The script:

-   asks for a client name;
-   finds the next free IP;
-   generates WireGuard keys;
-   generates a PresharedKey;
-   backs up `wg1.conf`;
-   adds the peer;
-   validates the new server configuration;
-   applies the peer without restarting WireGuard;
-   automatically rolls back on failure;
-   creates the client `.conf`;
-   optionally displays a QR code.

Files:

``` text
/etc/wireguard/clients-wg1/CLIENT.conf
/etc/wireguard/clients-wg1/CLIENT.private.key
/etc/wireguard/clients-wg1/CLIENT.public.key
/etc/wireguard/clients-wg1/CLIENT.psk.key
```

------------------------------------------------------------------------

## `add-wg2-client.sh`

Creates a new proxy-routed client for `wg2`.

Traffic path:

``` text
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

Run:

``` bash
chmod +x add-wg2-client.sh
sudo ./add-wg2-client.sh
```

Files:

``` text
/etc/wireguard/clients-wg2/CLIENT.conf
/etc/wireguard/clients-wg2/CLIENT.private.key
/etc/wireguard/clients-wg2/CLIENT.public.key
/etc/wireguard/clients-wg2/CLIENT.psk.key
```

No extra policy-routing rules are required for individual clients
because the entire `10.20.20.0/24` network is already routed through the
proxy path.

------------------------------------------------------------------------

## `change-wg2-proxy.sh`

Changes the SOCKS5 proxy used by `wg2`.

Run:

``` bash
chmod +x change-wg2-proxy.sh
sudo ./change-wg2-proxy.sh
```

The script asks for:

``` text
Proxy IP/Host
Proxy port
Proxy login
Proxy password
```

It then:

1.  validates the current JSON;
2.  validates the current sing-box config;
3.  creates a backup;
4.  changes SOCKS5 host/port/login/password;
5.  writes valid JSON;
6.  checks JSON using `python3 -m json.tool`;
7.  checks the config using `sing-box check`;
8.  restarts `proxy-singbox.service`;
9.  verifies `proxy-routing.service`;
10. tests the proxy through `127.0.0.1:1081` up to 5 times;
11. if the local sing-box path fails, tests the upstream SOCKS5
    directly;
12. automatically restores the previous config if validation fails.

Backups:

``` text
/etc/sing-box-proxy/backups/
```

------------------------------------------------------------------------

# Default addressing

``` text
wg1 server:        10.10.10.1/24
wg1 clients:       10.10.10.2-254
wg1 UDP port:      51820

wg2 server:        10.20.20.1/24
wg2 clients:       10.20.20.2-254
wg2 UDP port:      51821

veth-host:         172.31.255.1/30
veth-proxy:        172.31.255.2/30

sbtun0:            172.30.0.1/30

Host table:        201 / wg2proxy
Namespace table:   202
```

------------------------------------------------------------------------

# Systemd services

Check:

``` bash
systemctl is-active nftables
systemctl is-active wg-quick@wg1
systemctl is-active wg-quick@wg2
systemctl is-active proxy-netns
systemctl is-active proxy-singbox
systemctl is-active proxy-routing
```

Expected:

``` text
active
active
active
active
active
active
```

WireGuard:

``` bash
wg show wg1
wg show wg2
```

Namespace:

``` bash
ip netns list
ip netns exec proxy-ns ip addr
ip netns exec proxy-ns ip route
ip netns exec proxy-ns ip rule
ip netns exec proxy-ns ip route show table 202
```

Expected:

``` text
default dev sbtun0 scope link
```

------------------------------------------------------------------------

# QR codes

First WG1 client:

``` bash
qrencode -t ansiutf8 < /etc/wireguard/clients-wg1/client1.conf
```

First WG2 client:

``` bash
qrencode -t ansiutf8 < /etc/wireguard/clients-wg2/client1.conf
```

Other clients:

``` bash
qrencode -t ansiutf8 < /etc/wireguard/clients-wg1/CLIENT.conf
```

or:

``` bash
qrencode -t ansiutf8 < /etc/wireguard/clients-wg2/CLIENT.conf
```

------------------------------------------------------------------------

# External IP verification

WG1 client:

``` text
Public IP = VPS IP
```

WG2 client:

``` text
Public IP = SOCKS5 Proxy IP
```

VPS itself:

``` text
Public IP = VPS IP
```

Check the VPS:

``` bash
curl -4 https://api.ipify.org
```

Check the proxy through sing-box:

``` bash
ip netns exec proxy-ns \
  curl --connect-timeout 10 \
  --socks5-hostname 127.0.0.1:1081 \
  https://api.ipify.org
```

------------------------------------------------------------------------

# Routing verification

Host:

``` bash
ip route get 8.8.8.8 from 10.20.20.2 iif wg2
```

Expected:

``` text
via 172.31.255.2 dev veth-host table wg2proxy
```

Namespace:

``` bash
ip netns exec proxy-ns \
  ip route get 8.8.8.8 from 10.20.20.2 iif veth-proxy
```

Expected:

``` text
dev sbtun0 table 202
```

------------------------------------------------------------------------

# Temporarily stop the proxy path

To stop the VPS from connecting to the SOCKS5 proxy:

``` bash
systemctl stop proxy-singbox.service
```

Result:

``` text
wg1      -> works
SSH      -> works
Docker   -> works
Web      -> works
wg2      -> no Internet
SOCKS5   -> not used
```

Start it again:

``` bash
systemctl start proxy-singbox.service
```

------------------------------------------------------------------------

# Fixes and improvements in release 1.2

### JSON newline bug

The old version could append literal characters:

``` text
}\n
```

instead of a real newline.

The current release writes valid JSON and validates it using:

``` bash
python3 -m json.tool /etc/sing-box-proxy/config.json
```

### Initial proxy timeout

The first proxy test immediately after service startup could
occasionally time out even though the proxy became available seconds
later.

The current release retries up to 5 times.

### Better proxy diagnostics

If the local sing-box path fails, setup/change-proxy also tests the
upstream SOCKS5 directly.

This distinguishes:

``` text
proxy provider problem
```

from:

``` text
sing-box/routing problem
```

### Client directories

Client files are now stored consistently in:

``` text
/etc/wireguard/clients-wg1/
/etc/wireguard/clients-wg2/
```

### Client creation rollback

`add-wg1-client.sh` and `add-wg2-client.sh` back up the server
configuration and restore it if applying the peer fails.

### Proxy change rollback

`change-wg2-proxy.sh` automatically restores the previous sing-box
configuration if the new proxy fails validation.

------------------------------------------------------------------------

# Security

Do not publish:

``` text
PrivateKey
PresharedKey
SOCKS5 password
```

Sensitive files:

``` text
/etc/wireguard/clients-wg1/
/etc/wireguard/clients-wg2/
/etc/wireguard/*private*
/etc/wireguard/*psk*
/etc/sing-box-proxy/config.json
```

Do not commit them to a public Git repository.

------------------------------------------------------------------------

# Typical workflow

``` text
1. Install:
   setup-double-wireguard-proxy-interactive.sh

2. Add direct VPN client:
   add-wg1-client.sh

3. Add proxy VPN client:
   add-wg2-client.sh

4. Change SOCKS5 proxy:
   change-wg2-proxy.sh
```

------------------------------------------------------------------------

# Short summary

``` text
WG1:
Client -> wg1 -> NAT -> eth0 -> Internet

WG2:
Client -> wg2
       -> policy route table 201
       -> proxy-ns
       -> policy route table 202
       -> sbtun0
       -> sing-box
       -> SOCKS5
       -> Internet

VPS:
SSH / Docker / nginx / APIs
       -> eth0
       -> Internet
```
