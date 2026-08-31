#!/usr/bin/env bash
set -euo pipefail

WG_DIR="/etc/wireguard"
WG_IF="wg1"
WG_CONF="${WG_DIR}/${WG_IF}.conf"
CLIENT_DIR="${WG_DIR}/clients-${WG_IF}"
DNS_SERVERS="1.1.1.1, 8.8.8.8"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

cleanup_new_client() {
  rm -f "${CLIENT_CONF:-}" "${CLIENT_PRIV:-}" "${CLIENT_PUB:-}" "${CLIENT_PSK:-}" 2>/dev/null || true
}

[[ $EUID -eq 0 ]] || die "Run this script as root."
command -v wg >/dev/null 2>&1 || die "wireguard-tools is not installed."
command -v wg-quick >/dev/null 2>&1 || die "wg-quick was not found."
command -v ip >/dev/null 2>&1 || die "iproute2 was not found."
[[ -f "$WG_CONF" ]] || die "File not found: $WG_CONF"

install -d -m 700 "$CLIENT_DIR"
umask 077

WG_ADDRESS="$(awk -F'= *' '/^Address *=/ {print $2; exit}' "$WG_CONF" | cut -d',' -f1 | xargs)"
WG_LISTEN_PORT="$(awk -F'= *' '/^ListenPort *=/ {print $2; exit}' "$WG_CONF" | xargs)"
SERVER_PUB_FILE="${WG_DIR}/${WG_IF}-public.key"

[[ -n "$WG_ADDRESS" ]] || die "Could not determine the WireGuard Address in $WG_CONF."
[[ -n "$WG_LISTEN_PORT" ]] || die "Could not determine the ListenPort in $WG_CONF."

SERVER_IP="${WG_ADDRESS%/*}"
SERVER_PREFIX="${WG_ADDRESS#*/}"
[[ "$SERVER_PREFIX" == "24" ]] || die "This script currently expects a /24 IPv4 network for $WG_IF."

IFS='.' read -r A B C D <<< "$SERVER_IP"
[[ -n "${A:-}" && -n "${B:-}" && -n "${C:-}" && -n "${D:-}" ]]   || die "Could not parse the IPv4 address for $WG_IF."

NETWORK_PREFIX="${A}.${B}.${C}"

if [[ -s "$SERVER_PUB_FILE" ]]; then
  SERVER_PUB="$(cat "$SERVER_PUB_FILE")"
else
  SERVER_PUB="$(wg show "$WG_IF" public-key 2>/dev/null || true)"
fi
[[ -n "$SERVER_PUB" ]] || die "Could not determine the $WG_IF server public key."

WAN_IF="$(ip -4 route show default | awk 'NR==1 {print $5}')"
[[ -n "$WAN_IF" ]] || die "Could not determine the WAN interface."

ENDPOINT_IP="$(ip -4 addr show dev "$WAN_IF" | awk '/inet / {print $2; exit}' | cut -d/ -f1)"
[[ -n "$ENDPOINT_IP" ]] || die "Could not determine the VPS public IPv4 address."

echo "Creating a new client for $WG_IF"
echo "Client files will be stored in: $CLIENT_DIR"
echo

read -r -p "Client name (for example: phone, laptop): " CLIENT_NAME_RAW
CLIENT_NAME="$(printf '%s' "$CLIENT_NAME_RAW" | tr -cs 'A-Za-z0-9._-' '_' | sed 's/^_*//; s/_*$//')"
[[ -n "$CLIENT_NAME" ]] || die "Client name cannot be empty."

CLIENT_CONF="${CLIENT_DIR}/${CLIENT_NAME}.conf"
CLIENT_PRIV="${CLIENT_DIR}/${CLIENT_NAME}.private.key"
CLIENT_PUB="${CLIENT_DIR}/${CLIENT_NAME}.public.key"
CLIENT_PSK="${CLIENT_DIR}/${CLIENT_NAME}.psk.key"

if [[ -e "$CLIENT_CONF" || -e "$CLIENT_PRIV" || -e "$CLIENT_PUB" || -e "$CLIENT_PSK" ]]; then
  die "Client '$CLIENT_NAME' already exists in $CLIENT_DIR."
fi

# Read all client /32 addresses already assigned in the server configuration.
USED_LAST_OCTETS="$(
  grep -Eo "${NETWORK_PREFIX//./\\.}\.[0-9]+/32" "$WG_CONF" 2>/dev/null \
    | cut -d/ -f1 \
    | awk -F. '{print $4}' \
    | sort -n -u || true
)"

CLIENT_OCTET=""
for n in $(seq 2 254); do
  if ! grep -qx "$n" <<< "$USED_LAST_OCTETS"; then
    CLIENT_OCTET="$n"
    break
  fi
done

[[ -n "$CLIENT_OCTET" ]] || die "No free addresses are available in ${NETWORK_PREFIX}.0/24."
CLIENT_IP="${NETWORK_PREFIX}.${CLIENT_OCTET}"

wg genkey | tee "$CLIENT_PRIV" | wg pubkey > "$CLIENT_PUB"
wg genpsk > "$CLIENT_PSK"

PUB="$(cat "$CLIENT_PUB")"
PSK="$(cat "$CLIENT_PSK")"
PRIV="$(cat "$CLIENT_PRIV")"

BACKUP="${WG_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$WG_CONF" "$BACKUP"

cat >> "$WG_CONF" <<EOF

# client: ${CLIENT_NAME}
[Peer]
PublicKey = ${PUB}
PresharedKey = ${PSK}
AllowedIPs = ${CLIENT_IP}/32
EOF

if ! wg-quick strip "$WG_IF" >/dev/null; then
  cp -a "$BACKUP" "$WG_CONF"
  cleanup_new_client
  die "Updated $WG_CONF failed validation. The previous configuration was restored."
fi

if ip link show "$WG_IF" >/dev/null 2>&1; then
  if ! wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF"); then
    cp -a "$BACKUP" "$WG_CONF"
    wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF") 2>/dev/null || true
    cleanup_new_client
    die "Could not apply the new peer. The previous server configuration was restored."
  fi
else
  echo "WARNING: $WG_IF is not currently running. The peer was saved to $WG_CONF and will be loaded when the interface starts."
fi

cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = ${PRIV}
Address = ${CLIENT_IP}/32
DNS = ${DNS_SERVERS}

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${PSK}
Endpoint = ${ENDPOINT_IP}:${WG_LISTEN_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

chmod 600 "$CLIENT_CONF" "$CLIENT_PRIV" "$CLIENT_PUB" "$CLIENT_PSK"

echo
echo "Done."
echo "Client:        $CLIENT_NAME"
echo "WG interface:  $WG_IF"
echo "Address:       ${CLIENT_IP}/32"
echo "Endpoint:      ${ENDPOINT_IP}:${WG_LISTEN_PORT}"
echo "Config:        $CLIENT_CONF"
echo "Server backup: $BACKUP"
echo
echo "This client uses wg1 -> VPS -> eth0 -> Internet."
echo
echo "Check the peer:"
echo "  wg show $WG_IF"
echo

if command -v qrencode >/dev/null 2>&1; then
  read -r -p "Show the QR code in the terminal? [Y/n]: " SHOW_QR
  SHOW_QR="${SHOW_QR:-Y}"
  if [[ "$SHOW_QR" =~ ^[Yy]$ ]]; then
    qrencode -t ansiutf8 < "$CLIENT_CONF"
  fi
else
  echo "qrencode is not installed. Install it with:"
  echo "  apt install -y qrencode"
fi
