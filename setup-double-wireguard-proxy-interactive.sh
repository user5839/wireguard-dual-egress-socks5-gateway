#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Ubuntu 24.04: WG1 direct + WG2 via isolated sing-box SOCKS5
# Run as root on a CLEAN VPS.
#
# Proxy credentials are requested interactively at startup.
# The password is not displayed while typing.
# Initial client configs are stored under /etc/wireguard/clients-wg1 and clients-wg2.
# ============================================================

# Optional defaults (normally no need to change)
WG1_PORT="51820"
WG2_PORT="51821"
WG1_NET="10.10.10.0/24"
WG1_SERVER="10.10.10.1/24"
WG1_CLIENT1="10.10.10.2/32"
WG2_NET="10.20.20.0/24"
WG2_SERVER="10.20.20.1/24"
WG2_CLIENT1="10.20.20.2/32"
VETH_HOST_IP="172.31.255.1/30"
VETH_PROXY_IP="172.31.255.2/30"
VETH_NET="172.31.255.0/30"
TUN_IP="172.30.0.1/30"
HOST_POLICY_TABLE="201"
NS_POLICY_TABLE="202"

WG1_CLIENT_DIR="/etc/wireguard/clients-wg1"
WG2_CLIENT_DIR="/etc/wireguard/clients-wg2"

log() { printf '\n\033[1;32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root"

log "SOCKS5 proxy settings"
read -r -p "Proxy IP/Host: " PROXY_HOST
read -r -p "Proxy port: " PROXY_PORT
read -r -p "Proxy login: " PROXY_USER
read -r -s -p "Proxy password: " PROXY_PASS
printf '\n'

[[ -n "$PROXY_HOST" ]] || die "Proxy IP/Host cannot be empty"
[[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || die "Proxy port must be numeric"
(( PROXY_PORT >= 1 && PROXY_PORT <= 65535 )) || die "Proxy port must be between 1 and 65535"
[[ -n "$PROXY_USER" ]] || die "Proxy login cannot be empty"
[[ -n "$PROXY_PASS" ]] || die "Proxy password cannot be empty"

echo
echo "Proxy to configure:"
echo "  Host:  $PROXY_HOST"
echo "  Port:  $PROXY_PORT"
echo "  Login: $PROXY_USER"
echo "  Pass:  ********"
echo
read -r -p "Continue? [Y/n]: " CONFIRM_PROXY
CONFIRM_PROXY="${CONFIRM_PROXY:-Y}"
[[ "$CONFIRM_PROXY" =~ ^[Yy]$ ]] || die "Cancelled"

WAN_IF="$(ip -4 route show default | awk 'NR==1 {print $5}')"
[[ -n "$WAN_IF" ]] || die "Could not detect default interface"
SERVER_IP="$(ip -4 -o addr show dev "$WAN_IF" scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')"
[[ -n "$SERVER_IP" ]] || die "Could not detect public IPv4 on $WAN_IF"

log "Detected WAN interface: $WAN_IF"
log "Detected VPS IPv4: $SERVER_IP"

backup_if_exists() {
  local f="$1"
  if [[ -e "$f" ]]; then
    cp -a "$f" "${f}.backup.$(date +%Y%m%d-%H%M%S)"
  fi
}

log "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y wireguard wireguard-tools qrencode nftables curl ca-certificates iproute2 python3

if ! command -v sing-box >/dev/null 2>&1; then
  log "Installing sing-box"
  bash <(curl -fsSL https://sing-box.app/install.sh)
fi
sing-box version | head -n 1

log "Enabling IPv4 forwarding"
cat > /etc/sysctl.d/90-vpn-forwarding.conf <<'SYSCTL'
net.ipv4.ip_forward=1
SYSCTL
sysctl --system >/dev/null

install -d -m 700 /etc/wireguard
install -d -m 700 "$WG1_CLIENT_DIR" "$WG2_CLIENT_DIR"
umask 077

make_keypair() {
  local priv="$1" pub="$2"
  [[ -s "$priv" && -s "$pub" ]] || wg genkey | tee "$priv" | wg pubkey > "$pub"
}

log "Generating WireGuard keys"
make_keypair /etc/wireguard/wg1-private.key /etc/wireguard/wg1-public.key
make_keypair /etc/wireguard/wg2-private.key /etc/wireguard/wg2-public.key
make_keypair "$WG1_CLIENT_DIR/client1.private.key" "$WG1_CLIENT_DIR/client1.public.key"
make_keypair "$WG2_CLIENT_DIR/client1.private.key" "$WG2_CLIENT_DIR/client1.public.key"
[[ -s "$WG1_CLIENT_DIR/client1.psk.key" ]] || wg genpsk > "$WG1_CLIENT_DIR/client1.psk.key"
[[ -s "$WG2_CLIENT_DIR/client1.psk.key" ]] || wg genpsk > "$WG2_CLIENT_DIR/client1.psk.key"

WG1_PRIV="$(cat /etc/wireguard/wg1-private.key)"
WG2_PRIV="$(cat /etc/wireguard/wg2-private.key)"
WG1_C1_PUB="$(cat "$WG1_CLIENT_DIR/client1.public.key")"
WG2_C1_PUB="$(cat "$WG2_CLIENT_DIR/client1.public.key")"
WG1_C1_PSK="$(cat "$WG1_CLIENT_DIR/client1.psk.key")"
WG2_C1_PSK="$(cat "$WG2_CLIENT_DIR/client1.psk.key")"

backup_if_exists /etc/wireguard/wg1.conf
backup_if_exists /etc/wireguard/wg2.conf

log "Writing wg1.conf and wg2.conf"
cat > /etc/wireguard/wg1.conf <<EOF_WG1
[Interface]
Address = ${WG1_SERVER}
ListenPort = ${WG1_PORT}
PrivateKey = ${WG1_PRIV}

# client1
[Peer]
PublicKey = ${WG1_C1_PUB}
PresharedKey = ${WG1_C1_PSK}
AllowedIPs = ${WG1_CLIENT1}
EOF_WG1

cat > /etc/wireguard/wg2.conf <<EOF_WG2
[Interface]
Address = ${WG2_SERVER}
ListenPort = ${WG2_PORT}
PrivateKey = ${WG2_PRIV}

# client1
[Peer]
PublicKey = ${WG2_C1_PUB}
PresharedKey = ${WG2_C1_PSK}
AllowedIPs = ${WG2_CLIENT1}
EOF_WG2
chmod 600 /etc/wireguard/wg1.conf /etc/wireguard/wg2.conf
wg-quick strip wg1 >/dev/null
wg-quick strip wg2 >/dev/null

log "Writing client configs"
WG1_C1_PRIV="$(cat "$WG1_CLIENT_DIR/client1.private.key")"
WG2_C1_PRIV="$(cat "$WG2_CLIENT_DIR/client1.private.key")"
WG1_SERVER_PUB="$(cat /etc/wireguard/wg1-public.key)"
WG2_SERVER_PUB="$(cat /etc/wireguard/wg2-public.key)"

cat > "$WG1_CLIENT_DIR/client1.conf" <<EOF_C1
[Interface]
PrivateKey = ${WG1_C1_PRIV}
Address = ${WG1_CLIENT1}
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = ${WG1_SERVER_PUB}
PresharedKey = ${WG1_C1_PSK}
Endpoint = ${SERVER_IP}:${WG1_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF_C1

cat > "$WG2_CLIENT_DIR/client1.conf" <<EOF_C2
[Interface]
PrivateKey = ${WG2_C1_PRIV}
Address = ${WG2_CLIENT1}
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = ${WG2_SERVER_PUB}
PresharedKey = ${WG2_C1_PSK}
Endpoint = ${SERVER_IP}:${WG2_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF_C2
chmod 600 "$WG1_CLIENT_DIR/client1.conf" "$WG2_CLIENT_DIR/client1.conf"

# Compatibility symlinks for older docs/commands.
ln -sfn "$WG1_CLIENT_DIR/client1.conf" /etc/wireguard/wg1-client1.conf
ln -sfn "$WG2_CLIENT_DIR/client1.conf" /etc/wireguard/wg2-client1.conf

log "Configuring nftables (clean-VPS policy: accept + required NAT)"
backup_if_exists /etc/nftables.conf
cat > /etc/nftables.conf <<EOF_NFT
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter;
        policy accept;
    }
    chain forward {
        type filter hook forward priority filter;
        policy accept;
    }
    chain output {
        type filter hook output priority filter;
        policy accept;
    }
}

table ip vpn_nat {
    chain postrouting {
        type nat hook postrouting priority srcnat;
        policy accept;
        ip saddr ${WG1_NET} oifname "${WAN_IF}" masquerade
        ip saddr ${VETH_NET} oifname "${WAN_IF}" masquerade
    }
}
EOF_NFT
nft -c -f /etc/nftables.conf
systemctl enable nftables >/dev/null
systemctl restart nftables

log "Creating namespace DNS config"
install -d -m 755 /etc/netns/proxy-ns
cat > /etc/netns/proxy-ns/resolv.conf <<'EOF_DNS'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF_DNS

log "Writing sing-box proxy config"
install -d -m 700 /etc/sing-box-proxy
backup_if_exists /etc/sing-box-proxy/config.json

export PROXY_HOST PROXY_PORT PROXY_USER PROXY_PASS TUN_IP
python3 <<'PY_SB'
import json
import os

cfg = {
    "log": {
        "level": "info",
        "timestamp": True
    },
    "inbounds": [
        {
            "type": "socks",
            "tag": "test-socks",
            "listen": "127.0.0.1",
            "listen_port": 1081
        },
        {
            "type": "tun",
            "tag": "proxy-tun",
            "interface_name": "sbtun0",
            "address": [os.environ["TUN_IP"]],
            "mtu": 1400,
            "auto_route": False
        }
    ],
    "outbounds": [
        {
            "type": "socks",
            "tag": "upstream-proxy",
            "server": os.environ["PROXY_HOST"],
            "server_port": int(os.environ["PROXY_PORT"]),
            "username": os.environ["PROXY_USER"],
            "password": os.environ["PROXY_PASS"],
            "version": "5"
        }
    ],
    "route": {
        "final": "upstream-proxy"
    }
}

with open("/etc/sing-box-proxy/config.json", "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY_SB
chmod 600 /etc/sing-box-proxy/config.json
python3 -m json.tool /etc/sing-box-proxy/config.json >/dev/null || die "Generated sing-box config is not valid JSON"
sing-box check -c /etc/sing-box-proxy/config.json || die "Generated sing-box config failed sing-box validation"

# Friendly route-table name; numeric table is used in units so this is cosmetic.
grep -qE "^[[:space:]]*${HOST_POLICY_TABLE}[[:space:]]+wg2proxy$" /etc/iproute2/rt_tables || \
  echo "${HOST_POLICY_TABLE} wg2proxy" >> /etc/iproute2/rt_tables

log "Writing proxy-netns.service"
cat > /etc/systemd/system/proxy-netns.service <<EOF_NETNS
[Unit]
Description=Proxy Network Namespace
After=network-online.target wg-quick@wg2.service
Wants=network-online.target
Requires=wg-quick@wg2.service

[Service]
Type=oneshot
RemainAfterExit=yes

ExecStart=/bin/sh -c 'ip netns add proxy-ns 2>/dev/null || true'
ExecStart=/bin/sh -c 'ip link add veth-host type veth peer name veth-proxy 2>/dev/null || true'
ExecStart=/bin/sh -c 'ip link set veth-proxy netns proxy-ns 2>/dev/null || true'
ExecStart=/bin/sh -c 'ip addr replace ${VETH_HOST_IP} dev veth-host'
ExecStart=/bin/sh -c 'ip link set veth-host up'
ExecStart=/bin/sh -c 'ip netns exec proxy-ns ip addr replace ${VETH_PROXY_IP} dev veth-proxy'
ExecStart=/bin/sh -c 'ip netns exec proxy-ns ip link set veth-proxy up'
ExecStart=/bin/sh -c 'ip netns exec proxy-ns ip link set lo up'
ExecStart=/bin/sh -c 'ip netns exec proxy-ns ip route replace default via 172.31.255.1 dev veth-proxy'
ExecStart=/bin/sh -c 'ip netns exec proxy-ns ip route replace ${WG2_NET} via 172.31.255.1 dev veth-proxy'
ExecStart=/bin/sh -c 'ip route replace ${VETH_NET} dev veth-host src 172.31.255.1 table ${HOST_POLICY_TABLE}'
ExecStart=/bin/sh -c 'ip route replace ${WG2_NET} dev wg2 table ${HOST_POLICY_TABLE}'
ExecStart=/bin/sh -c 'ip route replace default via 172.31.255.2 dev veth-host table ${HOST_POLICY_TABLE}'
ExecStart=/bin/sh -c 'ip rule del from ${WG2_NET} lookup ${HOST_POLICY_TABLE} priority 1000 2>/dev/null || true'
ExecStart=/bin/sh -c 'ip rule add from ${WG2_NET} lookup ${HOST_POLICY_TABLE} priority 1000'

ExecStop=/bin/sh -c 'ip rule del from ${WG2_NET} lookup ${HOST_POLICY_TABLE} priority 1000 2>/dev/null || true'
ExecStop=/bin/sh -c 'ip route flush table ${HOST_POLICY_TABLE} 2>/dev/null || true'
ExecStop=/bin/sh -c 'ip netns del proxy-ns 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF_NETNS

log "Writing proxy-singbox.service"
cat > /etc/systemd/system/proxy-singbox.service <<'EOF_SVC'
[Unit]
Description=sing-box for WG2 Proxy Namespace
Requires=proxy-netns.service
After=proxy-netns.service network-online.target
PartOf=proxy-netns.service

[Service]
Type=simple
ExecStart=/usr/bin/ip netns exec proxy-ns /usr/bin/sing-box run -c /etc/sing-box-proxy/config.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF_SVC

log "Writing proxy-routing.service"
cat > /etc/systemd/system/proxy-routing.service <<EOF_ROUTE
[Unit]
Description=WG2 routing through sing-box TUN
Requires=proxy-singbox.service
After=proxy-singbox.service
PartOf=proxy-singbox.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for i in \$(seq 1 20); do ip netns exec proxy-ns ip link show sbtun0 >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1'
ExecStart=/usr/bin/ip netns exec proxy-ns ip route replace default dev sbtun0 table ${NS_POLICY_TABLE}
ExecStart=/bin/sh -c 'ip netns exec proxy-ns ip rule del from ${WG2_NET} lookup ${NS_POLICY_TABLE} priority 1000 2>/dev/null || true'
ExecStart=/usr/bin/ip netns exec proxy-ns ip rule add from ${WG2_NET} lookup ${NS_POLICY_TABLE} priority 1000
ExecStop=/bin/sh -c 'ip netns exec proxy-ns ip rule del from ${WG2_NET} lookup ${NS_POLICY_TABLE} priority 1000 2>/dev/null || true'
ExecStop=/bin/sh -c 'ip netns exec proxy-ns ip route flush table ${NS_POLICY_TABLE} 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF_ROUTE

log "Validating systemd units"
systemctl daemon-reload
systemd-analyze verify \
  /etc/systemd/system/proxy-netns.service \
  /etc/systemd/system/proxy-singbox.service \
  /etc/systemd/system/proxy-routing.service

log "Starting services"
systemctl enable --now wg-quick@wg1 >/dev/null
systemctl enable --now wg-quick@wg2 >/dev/null
systemctl enable proxy-netns.service proxy-singbox.service proxy-routing.service >/dev/null
systemctl restart proxy-netns.service
systemctl restart proxy-singbox.service
systemctl restart proxy-routing.service

sleep 2

log "Validation"
systemctl is-active --quiet nftables || die "nftables is not active"
systemctl is-active --quiet wg-quick@wg1 || die "wg1 is not active"
systemctl is-active --quiet wg-quick@wg2 || die "wg2 is not active"
systemctl is-active --quiet proxy-netns || die "proxy-netns is not active"
systemctl is-active --quiet proxy-singbox || die "proxy-singbox is not active"
systemctl is-active --quiet proxy-routing || die "proxy-routing is not active"
ip netns exec proxy-ns ip link show sbtun0 >/dev/null || die "sbtun0 missing"
ip netns exec proxy-ns ip route show table "$NS_POLICY_TABLE" | grep -q 'default dev sbtun0' || die "namespace proxy table missing"
python3 -m json.tool /etc/sing-box-proxy/config.json >/dev/null || die "sing-box JSON became invalid"

log "Testing upstream SOCKS5 through sing-box"
PROXY_SEEN_IP=""
for attempt in 1 2 3 4 5; do
  PROXY_SEEN_IP="$(ip netns exec proxy-ns curl -4 -fsS \
    --connect-timeout 10 --max-time 15 \
    --socks5-hostname 127.0.0.1:1081 \
    https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "$PROXY_SEEN_IP" ]]; then
    break
  fi
  warn "Proxy test attempt ${attempt}/5 failed; retrying in 2 seconds..."
  sleep 2
done

if [[ -n "$PROXY_SEEN_IP" ]]; then
  echo "Proxy egress IP: $PROXY_SEEN_IP"
else
  warn "sing-box proxy test failed after 5 attempts."
  warn "Running a direct upstream SOCKS5 diagnostic..."

  DIRECT_PROXY_IP="$(ip netns exec proxy-ns curl -4 -fsS \
    --connect-timeout 10 --max-time 15 \
    --socks5-hostname "${PROXY_HOST}:${PROXY_PORT}" \
    --proxy-user "${PROXY_USER}:${PROXY_PASS}" \
    https://api.ipify.org 2>/dev/null || true)"

  if [[ -n "$DIRECT_PROXY_IP" ]]; then
    warn "Direct upstream SOCKS5 works (${DIRECT_PROXY_IP}), but the local sing-box test failed."
    warn "Check: journalctl -u proxy-singbox -n 100 --no-pager"
  else
    warn "Direct upstream SOCKS5 test also failed."
    warn "Check proxy host/port/login/password and provider availability."
  fi
fi

# Do not keep the password in the shell environment longer than needed.
unset PROXY_PASS

cat <<EOF_SUMMARY

============================================================
DONE
============================================================
VPS IPv4:         ${SERVER_IP}
WAN interface:    ${WAN_IF}
WG1 server:       ${WG1_SERVER} UDP/${WG1_PORT}  (direct VPS egress)
WG2 server:       ${WG2_SERVER} UDP/${WG2_PORT}  (SOCKS5 proxy egress)
SOCKS5 upstream:  ${PROXY_HOST}:${PROXY_PORT}

Client configs:
  ${WG1_CLIENT_DIR}/client1.conf
  ${WG2_CLIENT_DIR}/client1.conf

Compatibility symlinks:
  /etc/wireguard/wg1-client1.conf
  /etc/wireguard/wg2-client1.conf

Show WG1 QR:
  qrencode -t ansiutf8 < ${WG1_CLIENT_DIR}/client1.conf

Show WG2 QR:
  qrencode -t ansiutf8 < ${WG2_CLIENT_DIR}/client1.conf

Temporarily stop proxy path (WG2 loses Internet; VPS/WG1 stay normal):
  systemctl stop proxy-singbox.service

Start it again:
  systemctl start proxy-singbox.service

To change the proxy later, use the separate change-wg2-proxy.sh helper,
or edit /etc/sing-box-proxy/config.json and then run:
  sing-box check -c /etc/sing-box-proxy/config.json && systemctl restart proxy-singbox.service

Status:
  systemctl status proxy-netns proxy-singbox proxy-routing --no-pager
============================================================
EOF_SUMMARY

warn "This script intentionally configures nftables with ACCEPT policies and overwrites /etc/nftables.conf. Use on a clean VPS as requested."
warn "Protect the proxy password and WireGuard private-key files (mode 600)."
