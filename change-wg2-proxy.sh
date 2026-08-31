#!/usr/bin/env bash
set -euo pipefail

CONFIG="/etc/sing-box-proxy/config.json"
SERVICE="proxy-singbox.service"
ROUTING_SERVICE="proxy-routing.service"
NETNS="proxy-ns"
LOCAL_SOCKS_HOST="127.0.0.1"
LOCAL_SOCKS_PORT="1081"
BACKUP_DIR="/etc/sing-box-proxy/backups"
TEST_URL="https://api.ipify.org"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARNING: $*" >&2
}

info() {
  echo "[+] $*"
}

rollback() {
  local backup="$1"

  warn "Rolling back to the previous proxy configuration..."
  cp -a "$backup" "$CONFIG"
  chmod 600 "$CONFIG"

  if ! python3 -m json.tool "$CONFIG" >/dev/null 2>&1; then
    die "Rollback failed: restored config is not valid JSON."
  fi

  if ! sing-box check -c "$CONFIG" >/dev/null 2>&1; then
    die "Rollback failed: restored config did not pass sing-box validation."
  fi

  systemctl restart "$SERVICE" || true
  sleep 2

  if systemctl list-unit-files "$ROUTING_SERVICE" >/dev/null 2>&1; then
    systemctl restart "$ROUTING_SERVICE" >/dev/null 2>&1 || true
  fi

  warn "Previous configuration restored."
}

[[ $EUID -eq 0 ]] || die "Run this script as root."
command -v sing-box >/dev/null 2>&1 || die "sing-box is not installed."
command -v python3 >/dev/null 2>&1 || die "python3 was not found."
command -v systemctl >/dev/null 2>&1 || die "systemctl was not found."
command -v ip >/dev/null 2>&1 || die "iproute2 was not found."
command -v curl >/dev/null 2>&1 || die "curl was not found."

[[ -f "$CONFIG" ]] || die "File not found: $CONFIG"

install -d -m 700 "$BACKUP_DIR"

info "Checking current sing-box configuration"

python3 -m json.tool "$CONFIG" >/dev/null \
  || die "Current $CONFIG is not valid JSON. Fix it before changing the proxy."

sing-box check -c "$CONFIG" >/dev/null \
  || die "Current $CONFIG does not pass sing-box validation."

echo
echo "Change SOCKS5 proxy for wg2"
echo

read -r -p "Proxy IP/Host: " PROXY_HOST
read -r -p "Proxy port: " PROXY_PORT
read -r -p "Proxy login: " PROXY_USER
read -r -s -p "Proxy password: " PROXY_PASS
printf '\n'

[[ -n "$PROXY_HOST" ]] || die "Proxy IP/Host cannot be empty."
[[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || die "Proxy port must be numeric."
(( PROXY_PORT >= 1 && PROXY_PORT <= 65535 )) || die "Proxy port must be between 1 and 65535."
[[ -n "$PROXY_USER" ]] || die "Proxy login cannot be empty."
[[ -n "$PROXY_PASS" ]] || die "Proxy password cannot be empty."

echo
echo "New proxy:"
echo "  Host:  $PROXY_HOST"
echo "  Port:  $PROXY_PORT"
echo "  Login: $PROXY_USER"
echo "  Pass:  ********"
echo

read -r -p "Apply this proxy? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
[[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Cancelled."

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${BACKUP_DIR}/config.json.${STAMP}.bak"

cp -a "$CONFIG" "$BACKUP"
chmod 600 "$BACKUP"

info "Backup created: $BACKUP"

export CONFIG PROXY_HOST PROXY_PORT PROXY_USER PROXY_PASS

python3 <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(os.environ["CONFIG"])

with path.open("r", encoding="utf-8") as f:
    cfg = json.load(f)

target = None

for outbound in cfg.get("outbounds", []):
    if outbound.get("tag") == "upstream-proxy":
        target = outbound
        break

if target is None:
    for outbound in cfg.get("outbounds", []):
        if outbound.get("type") == "socks":
            target = outbound
            break

if target is None:
    print("ERROR: SOCKS outbound was not found in config.json", file=sys.stderr)
    sys.exit(2)

target["type"] = "socks"
target["tag"] = target.get("tag") or "upstream-proxy"
target["server"] = os.environ["PROXY_HOST"]
target["server_port"] = int(os.environ["PROXY_PORT"])
target["username"] = os.environ["PROXY_USER"]
target["password"] = os.environ["PROXY_PASS"]
target["version"] = "5"

tmp = path.with_suffix(path.suffix + ".tmp")

with tmp.open("w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")

tmp.replace(path)
PY

chmod 600 "$CONFIG"

info "Validating new JSON"

if ! python3 -m json.tool "$CONFIG" >/dev/null; then
  unset PROXY_PASS
  rollback "$BACKUP"
  die "The new configuration is not valid JSON."
fi

info "Running sing-box config validation"

if ! sing-box check -c "$CONFIG"; then
  unset PROXY_PASS
  rollback "$BACKUP"
  die "The new configuration failed sing-box validation."
fi

info "Restarting $SERVICE"

if ! systemctl restart "$SERVICE"; then
  unset PROXY_PASS
  rollback "$BACKUP"
  die "Could not restart $SERVICE."
fi

sleep 2

if ! systemctl is-active --quiet "$SERVICE"; then
  unset PROXY_PASS
  rollback "$BACKUP"
  die "$SERVICE is not active after restart."
fi

# The TUN interface is recreated by sing-box. Ensure routing is restored as well.
if systemctl list-unit-files "$ROUTING_SERVICE" >/dev/null 2>&1; then
  if ! systemctl is-active --quiet "$ROUTING_SERVICE"; then
    info "Restarting $ROUTING_SERVICE"
    systemctl restart "$ROUTING_SERVICE" || {
      unset PROXY_PASS
      rollback "$BACKUP"
      die "Could not restore proxy routing."
    }
  fi
fi

if ! ip netns list 2>/dev/null | grep -q "^${NETNS}\b"; then
  unset PROXY_PASS
  rollback "$BACKUP"
  die "Network namespace '$NETNS' was not found."
fi

info "Testing the new proxy through local sing-box"

PROXY_SEEN_IP=""

for attempt in 1 2 3 4 5; do
  PROXY_SEEN_IP="$(
    ip netns exec "$NETNS" curl -4 -fsS \
      --connect-timeout 10 \
      --max-time 15 \
      --socks5-hostname "${LOCAL_SOCKS_HOST}:${LOCAL_SOCKS_PORT}" \
      "$TEST_URL" 2>/dev/null || true
  )"

  if [[ -n "$PROXY_SEEN_IP" ]]; then
    break
  fi

  warn "Local sing-box test attempt ${attempt}/5 failed; retrying in 2 seconds..."
  sleep 2
done

if [[ -z "$PROXY_SEEN_IP" ]]; then
  warn "The local sing-box test failed after 5 attempts."
  warn "Testing the upstream SOCKS5 proxy directly..."

  DIRECT_PROXY_IP="$(
    ip netns exec "$NETNS" curl -4 -fsS \
      --connect-timeout 10 \
      --max-time 15 \
      --socks5-hostname "${PROXY_HOST}:${PROXY_PORT}" \
      --proxy-user "${PROXY_USER}:${PROXY_PASS}" \
      "$TEST_URL" 2>/dev/null || true
  )"

  if [[ -n "$DIRECT_PROXY_IP" ]]; then
    warn "The upstream SOCKS5 proxy works directly (${DIRECT_PROXY_IP}), but the local sing-box path failed."
    unset PROXY_PASS
    rollback "$BACKUP"
    die "New proxy was not kept because the wg2 proxy path did not pass validation."
  else
    warn "The upstream SOCKS5 proxy also failed the direct test."
    unset PROXY_PASS
    rollback "$BACKUP"
    die "New proxy was not applied. Check host, port, login, password, and provider availability."
  fi
fi

unset PROXY_PASS

info "Verifying wg2 routing"

if systemctl list-unit-files "$ROUTING_SERVICE" >/dev/null 2>&1; then
  if ! ip netns exec "$NETNS" ip route show table 202 2>/dev/null | grep -q 'default dev sbtun0'; then
    rollback "$BACKUP"
    die "Proxy routing table 202 does not contain 'default dev sbtun0'."
  fi
fi

echo
echo "Proxy change completed successfully."
echo
echo "Active proxy:"
echo "  Host:      $PROXY_HOST"
echo "  Port:      $PROXY_PORT"
echo "  Login:     $PROXY_USER"
echo "  Password:  ********"
echo "  Egress IP: $PROXY_SEEN_IP"
echo
echo "Backup:"
echo "  $BACKUP"
echo
echo "Service status:"
echo "  $SERVICE: $(systemctl is-active "$SERVICE" 2>/dev/null || true)"
if systemctl list-unit-files "$ROUTING_SERVICE" >/dev/null 2>&1; then
  echo "  $ROUTING_SERVICE: $(systemctl is-active "$ROUTING_SERVICE" 2>/dev/null || true)"
fi
