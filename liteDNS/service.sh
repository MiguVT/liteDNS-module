#!/system/bin/sh
# service.sh – Boot-time DNS application for liteDNS

# ─────────────────────────────────────────────────────────────
# 📁 Module paths
MODDIR="$MODPATH"
TEMPLATE_CONF="$MODDIR/dnscrypt-proxy.toml.template"
TARGET_CONF="$MODDIR/dnscrypt-proxy.toml"
CONFIG="$MODDIR/config.sh"
LOG_DIR="$MODDIR/log"
LOG="$LOG_DIR/service.log"
DOH_LOG="$LOG_DIR/dnscrypt.log"
DOH_FAIL="$LOG_DIR/dnscrypt-fail.log"
BIN="$MODDIR/bin/dnscrypt-proxy"

# ─────────────────────────────────────────────────────────────
# 🛠 Bootstrap config and logs
[ ! -d "$LOG_DIR" ] && mkdir -p "$LOG_DIR"
[ ! -f "$CONFIG" ] && cp "$MODDIR/config.sh.template" "$CONFIG" && chmod 644 "$CONFIG"
# rotate on each boot
[ -f "$LOG" ] && mv "$LOG" "$LOG.old"
: > "$LOG"

# ─────────────────────────────────────────────────────────────
# 📝 Logging helper
date_stamp() { date '+%F %T'; }
log() {
  echo "[liteDNS] $(date_stamp) – $*" >> "$LOG"
}
abort() {
  log "ERROR: $*"
  exit 1
}

# ─────────────────────────────────────────────────────────────
# 🔄 Load config values
. "$CONFIG"
# set defaults if missing
: "${VERBOSE_LOG:=1}"
: "${ENABLE_IPV6:=1}"
: "${ENABLE_DOH:=0}"
: "${DOH_SERVER:='https://cloudflare-dns.com/dns-query'}"
: "${FAILSAFE_FALLBACK:=1}"
: "${DNS1:=1.1.1.1}"
: "${DNS2:=1.0.0.1}"
: "${DNS6_1:=2606:4700:4700::1111}"
: "${DNS6_2:=2606:4700:4700::1001}"
: "${WIFI_CUSTOM_DNS:=1}"

# ─────────────────────────────────────────────────────────────
# 🔍 Choose prop tool
if command -v resetprop >/dev/null 2>&1; then
  PROPTOOL='resetprop -n'
else
  PROPTOOL='setprop'
fi

log "service.sh started (DoH=$ENABLE_DOH, IPv6=$ENABLE_IPV6, WIFI_CUSTOM_DNS=$WIFI_CUSTOM_DNS)"

# ─────────────────────────────────────────────────────────────
# 🛠 Prepare dnscrypt-proxy.toml from template if DoH enabled
if [ "$ENABLE_DOH" -eq 1 ]; then
  # copy default template on first run
  if [ ! -f "$TARGET_CONF" ]; then
    cp "$TEMPLATE_CONF" "$TARGET_CONF" || abort "Could not copy toml template"
    chmod 644 "$TARGET_CONF"
  fi
  # patch ipv6_servers
  IPV6_FLAG=false; [ "$ENABLE_IPV6" -eq 1 ] && IPV6_FLAG=true
  sed -i "s|^ipv6_servers *=.*|ipv6_servers = $IPV6_FLAG|" "$TARGET_CONF" || abort "Failed to update ipv6_servers"
  # patch doh_servers
  ESC_SERVER=$(printf '%s' "$DOH_SERVER" | sed 's/[\/&]/\\&/g')
  sed -i "s|^doh_servers *=.*|doh_servers = ['$ESC_SERVER']|" "$TARGET_CONF" || abort "Failed to update doh_servers"
  log "Patched TOML → DOH=$DOH_SERVER, IPv6=$IPV6_FLAG"
fi

# ─────────────────────────────────────────────────────────────
# 🏃‍♂️ Start DoH service if enabled
start_doh() {
  DNS1=127.0.0.1; DNS2=127.0.0.1
  if [ ! -x "$BIN" ] || [ ! -f "$TARGET_CONF" ]; then
    log "DoH disabled: missing binary or config"
    return
  fi
  if ss -ltnp 2>/dev/null | grep -q ':53 '; then
    log "Port 53 in use: skipping dnscrypt-proxy"
    return
  fi
  "$BIN" -config "$TARGET_CONF" >>"$DOH_LOG" 2>>"$DOH_FAIL" &
  sleep 1
  if pgrep -f "$BIN" >/dev/null; then
    log "dnscrypt-proxy launched successfully"
  else
    log "dnscrypt-proxy failed to start"
    if [ "$FAILSAFE_FALLBACK" -eq 1 ]; then
      DNS1=1.1.1.1; DNS2=1.0.0.1
      log "Fallback to $DNS1/$DNS2"
    fi
  fi
}

# ─────────────────────────────────────────────────────────────
# 🌐 Apply DNS props to an interface
apply_dns_iface() {
  local iface="$1"
  $PROPTOOL net.$iface.dns1 "$DNS1"
  $PROPTOOL net.$iface.dns2 "$DNS2"
  if [ "$ENABLE_IPV6" -eq 1 ]; then
    $PROPTOOL net.$iface.dns3 "$DNS6_1"
    $PROPTOOL net.$iface.dns4 "$DNS6_2"
  fi
  log "Applied DNS to $iface: $DNS1/$DNS2"
}

# ─────────────────────────────────────────────────────────────
# 🎬 Main execution

if [ "$ENABLE_DOH" -eq 1 ]; then
  start_doh
else
  log "DoH not enabled: using $DNS1/$DNS2"
fi

# handle mobile interfaces
IFS=$'\n'
for iface in $(ls /sys/class/net 2>/dev/null | grep -E '^(rmnet|pdp|ppp)'); do
  apply_dns_iface "$iface"
done
unset IFS

# ───── Global DNS override (affects Wi-Fi)
if [ "$WIFI_CUSTOM_DNS" -eq 1 ]; then
  $PROPTOOL net.dns1 "$DNS1"
  $PROPTOOL net.dns2 "$DNS2"
  log "Global DNS set to $DNS1/$DNS2 (Wi-Fi overridden)"
els