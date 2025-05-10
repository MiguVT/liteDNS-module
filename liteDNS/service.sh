#!/system/bin/sh
# service.sh – Boot-time DNS application for liteDNS

# ─────────────────────────────────────────────────────────────
# Module paths and files
MODDIR="${0%/*}"
TEMPLATE_CONF="$MODDIR/dnscrypt-proxy.toml.template"
TARGET_CONF="$MODDIR/dnscrypt-proxy.toml"
CONFIG="$MODDIR/config.sh"
LOG_DIR="$MODDIR/log"
LOG="$LOG_DIR/service.log"
DOH_LOG="$LOG_DIR/dnscrypt.log"
BIN="$MODDIR/bin/dnscrypt-proxy"

# ─────────────────────────────────────────────────────────────
# Bootstrap config and logs
[ ! -d "$LOG_DIR" ] && mkdir -p "$LOG_DIR"
[ ! -f "$CONFIG" ] && cp "$MODDIR/config.sh.template" "$CONFIG" && chmod 644 "$CONFIG"
# rotate on each boot
[ -f "$LOG" ] && mv "$LOG" "$LOG.old"
: > "$LOG"

# ─────────────────────────────────────────────────────────────
# Logging helpers
date_stamp() { date '+%F %T'; }
log() {
  echo "[liteDNS] $(date_stamp) – $*" >> "$LOG"
}
abort() {
  log "ERROR: $*"
  exit 1
}

# ─────────────────────────────────────────────────────────────
# Load config values (new config.sh provides a single DNS and DNS flags for Wi‑Fi and Mobile)
. "$CONFIG"
: "${VERBOSE_LOG:=1}"
: "${WIFI_CUSTOM_DNS:=1}"
: "${MOBILE_CUSTOM_DNS:=1}"
: "${ENABLE_DOH:=0}"
: "${DOH_SERVERS_NAME:='cloudflare'}"
: "${FAILSAFE_FALLBACK:=1}"
: "${DNS:=1.1.1.1}"
: "${GLOBAL_DNS_OVERRIDE:=1}"

log "service.sh started (DoH=$ENABLE_DOH, DNS=$DNS, WIFI_CUSTOM_DNS=$WIFI_CUSTOM_DNS, MOBILE_CUSTOM_DNS=$MOBILE_CUSTOM_DNS)"

# ─────────────────────────────────────────────────────────────
# Prepare dnscrypt-proxy.toml from template if DoH is enabled
if [ "$ENABLE_DOH" -eq 1 ]; then
  if [ ! -f "$TARGET_CONF" ]; then
    cp "$TEMPLATE_CONF" "$TARGET_CONF" || abort "Could not copy toml template"
    chmod 644 "$TARGET_CONF"
  fi
  # Patch server_names with the list from DOH_SERVERS_NAME
  ESC_NAMES=$(printf '%s' "$DOH_SERVERS_NAME" | sed "s/,/','/g")
  sed -i "s|^server_names *=.*|server_names = ['$ESC_NAMES']|" "$TARGET_CONF" \
    || abort "Failed to update server_names"
  # set bootstrap_resolvers to the configured DNS
  sed -i "s|^bootstrap_resolvers *=.*|bootstrap_resolvers = ['$DNS']|" "$TARGET_CONF" \
    || abort "Failed to update bootstrap_resolvers"
  log "Patched TOML → SERVERS=$DOH_SERVERS_NAME"
fi

# ─────────────────────────────────────────────────────────────
# Start DoH service if enabled
start_doh() {
  # When DoH starts successfully, use localhost as DNS; otherwise fallback to $DNS
  LOCAL_DNS="127.0.0.1"
  if [ ! -x "$BIN" ] || [ ! -f "$TARGET_CONF" ]; then
    log "DoH disabled: missing binary or config"
    return
  fi
  if ss -ltnp 2>/dev/null | grep -q ':53 '; then
    log "Port 53 in use: skipping dnscrypt-proxy"
    return
  fi
  # Apply iptables to allow fallback DNS for resolve dnscrypt-proxy
  iptables -t nat -A OUTPUT -p udp --dport 53 -d $DNS -j RETURN
  iptables -t nat -A OUTPUT -p tcp --dport 53 -d $DNS -j RETURN
  # Add more for other bootstrap IPs if needed
  "$BIN" -config "$TARGET_CONF" >>"$DOH_LOG" 2>&1 &
  sleep 1
  if pgrep -f "$BIN" >/dev/null; then
    log "dnscrypt-proxy launched successfully"
    DNS="$LOCAL_DNS"
  else
    log "dnscrypt-proxy failed to start"
    if [ "$FAILSAFE_FALLBACK" -eq 1 ]; then
      DNS="$DNS"
      log "Fallback to configured DNS: $DNS"
    fi
  fi
}

if [ "$ENABLE_DOH" -eq 1 ]; then
  start_doh
else
  log "DoH not enabled: using configured DNS $DNS"
fi

# ─────────────────────────────────────────────────────────────
# Function to apply iptables-based DNS redirection on an interface
apply_dns_iptables() {
  local iface="$1"
  local target_dns="$2"
  # Redirect both UDP and TCP destined to port 53 on the given interface
  iptables -t nat -A OUTPUT -o "$iface" -p udp --dport 53 -j DNAT --to-destination "${target_dns}:53" \
    || log "Failed to apply iptables rule (UDP) on $iface"
  iptables -t nat -A OUTPUT -o "$iface" -p tcp --dport 53 -j DNAT --to-destination "${target_dns}:53" \
    || log "Failed to apply iptables rule (TCP) on $iface"
  log "Applied iptables DNS redirection on $iface to ${target_dns}"
}

# ─────────────────────────────────────────────────────────────
# Apply iptables rules based on interface type

# For mobile-data interfaces (rmnet, pdp, ppp)
if [ "$MOBILE_CUSTOM_DNS" -eq 1 ]; then
  for iface in $(ls /sys/class/net 2>/dev/null | grep -E '^(rmnet|pdp|ppp)'); do
    apply_dns_iptables "$iface" "$DNS"
  done
fi

# For Wi‑Fi interfaces (typically starting with wlan)
if [ "$WIFI_CUSTOM_DNS" -eq 1 ]; then
  for iface in $(ls /sys/class/net 2>/dev/null | grep -E '^wlan'); do
    apply_dns_iptables "$iface" "$DNS"
  done
fi

# ─────────────────────────────────────────────────────────────
# Global DNS override (if needed, e.g. for processes that use the default route)
if [ "$GLOBAL_DNS_OVERRIDE" -eq 1 ]; then
  # Apply to default OUTPUT if interface detection fails
  iptables -t nat -A OUTPUT -p udp --dport 53 -j DNAT --to-destination "${DNS}:53" \
    || log "Failed to apply global iptables rule (UDP)"
  iptables -t nat -A OUTPUT -p tcp --dport 53 -j DNAT --to-destination "${DNS}:53" \
    || log "Failed to apply global iptables rule (TCP)"
  log "Global DNS redirect applied to all outgoing traffic to ${DNS}"
fi