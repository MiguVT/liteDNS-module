#!/system/bin/sh
# service.sh – Boot-time DNS application for liteDNS

# ─────────────────────────────────────────────────────────────
# 📁 Module paths
MODDIR="${0%/*}"
TEMPLATE="$MODDIR/config.sh.template"
CONFIG="$MODDIR/config.sh"
LOG_DIR="$MODDIR/log"
LOG="$LOG_DIR/service.log"
DOH_LOG="$LOG_DIR/dnscrypt.log"
DOH_FAIL="$LOG_DIR/dnscrypt-fail.log"
BIN="$MODDIR/bin/dnscrypt-proxy"
CONF="$MODDIR/dnscrypt-proxy.toml"

# ─────────────────────────────────────────────────────────────
# 🛠 Bootstrap config and logs
[ ! -d "$LOG_DIR" ] && mkdir -p "$LOG_DIR"
[ ! -f "$CONFIG" ] && cp "$TEMPLATE" "$CONFIG" && chmod 644 "$CONFIG"
# rotate on each boot
[ -f "$LOG" ] && mv "$LOG" "$LOG.old"
: > "$LOG"

# ─────────────────────────────────────────────────────────────
# 📝 Logging helper
log() {
  echo "[liteDNS] $(date '+%F %T') – $*" >> "$LOG"
}

abort() {
  log "ERROR: $*"
  exit 1
}

# ─────────────────────────────────────────────────────────────
# 🔄 Load config values
. "$CONFIG"

# Fallbacks (only needed if TEMPLATE changes)
: "${DNS1:=1.1.1.1}"
: "${DNS2:=1.0.0.1}"
: "${ENABLE_DOH:=0}"
: "${ENABLE_IPV6:=1}"
: "${FAILSAFE_FALLBACK:=1}"
: "${DNS6_1:=2606:4700:4700::1111}"
: "${DNS6_2:=2606:4700:4700::1001}"

# ─────────────────────────────────────────────────────────────
# 🔍 Choose prop tool
if command -v resetprop >/dev/null 2>&1; then
  PROPTOOL='resetprop -n'
else
  PROPTOOL='setprop'
fi

log "service.sh started (DoH=$ENABLE_DOH, IPv6=$ENABLE_IPV6)"

# ─────────────────────────────────────────────────────────────
# 🏃‍♂️ Start DoH service if enabled
start_doh() {
  # override DNS to loopback
  DNS1=127.0.0.1; DNS2=127.0.0.1

  if [ ! -x "$BIN" ] || [ ! -f "$CONF" ]; then
    log "DoH disabled: missing binary or config"
    return
  fi

  # if port 53 busy, skip
  if ss -ltnp 2>/dev/null | grep -q ':53 '; then
    log "Port 53 in use: skipping dnscrypt-proxy"
    return
  fi

  # launch and verify
  "$BIN" -config "$CONF" >>"$DOH_LOG" 2>>"$DOH_FAIL" &
  sleep 1
  if pgrep -f "$BIN" >/dev/null; then
    log "dnscrypt-proxy launched successfully"
  else
    log "dnscrypt-proxy failed to start"
    if [ "$FAILSAFE_FALLBACK" = 1 ]; then
      DNS1=1.1.1.1; DNS2=1.0.0.1
      log "Fallback to $DNS1/$DNS2"
    fi
  fi
}

# ─────────────────────────────────────────────────────────────
# 🌐 Apply DNS props to an interface
apply_dns_iface() {
  local iface=$1
  $PROPTOOL net.$iface.dns1 "$DNS1"
  $PROPTOOL net.$iface.dns2 "$DNS2"
  if [ "$ENABLE_IPV6" = 1 ]; then
    $PROPTOOL net.$iface.dns3 "$DNS6_1"
    $PROPTOOL net.$iface.dns4 "$DNS6_2"
  fi
  log "Applied DNS to $iface: $DNS1/$DNS2"
}

# ─────────────────────────────────────────────────────────────
# 🎬 Main execution

# 1) If DoH enabled, start it
if [ "$ENABLE_DOH" = 1 ]; then
  start_doh
else
  log "DoH not enabled: using $DNS1/$DNS2"
fi

# 2) Discover mobile interfaces: rmnet*, pdp*, ppp*, and generic cellular 
IFS='
'
for iface in $(ls /sys/class/net 2>/dev/null | grep -E '^(rmnet|pdp|ppp)'); do
  apply_dns_iface "$iface"
done
unset IFS

# 3) Global props
$PROPTOOL net.dns1 "$DNS1"
$PROPTOOL net.dns2 "$DNS2"
log "Global DNS set to $DNS1/$DNS2"

if [ "$ENABLE_IPV6" = 1 ]; then
  $PROPTOOL net.dns3 "$DNS6_1"
  $PROPTOOL net.dns4 "$DNS6_2"
  log "Global IPv6 DNS set to $DNS6_1/$DNS6_2"
fi

log "service.sh completed successfully"
