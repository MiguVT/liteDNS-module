#!/system/bin/sh
# service.sh – Boot-time DNS application for liteDNS
# Applies DNS settings on mobile interfaces and optionally starts DoH (dnscrypt-proxy)

# ─────────────────────────────────────────────────────────────
# 📁 Paths and config
MODDIR=${0%/*}
CONFIG="$MODDIR/config.sh"
LOG="$MODDIR/litedns-service.log"
DNSCRYPT_BIN="$MODDIR/bin/dnscrypt-proxy"
DNSCRYPT_CONF="$MODDIR/dnscrypt-proxy.toml"

# ─────────────────────────────────────────────────────────────
# 🔄 Load user config
[ -f "$CONFIG" ] && . "$CONFIG"

# Fallback defaults
[ -z "$DNS1" ] && DNS1="1.1.1.1"
[ -z "$DNS2" ] && DNS2="1.0.0.1"
[ -z "$ENABLE_DOH" ] && ENABLE_DOH="0"
[ -z "$ENABLE_IPV6" ] && ENABLE_IPV6="1"
[ -z "$VERBOSE_LOG" ] && VERBOSE_LOG="1"
[ -z "$FAILSAFE_FALLBACK" ] && FAILSAFE_FALLBACK="1"
[ -z "$DNS6_1" ] && DNS6_1="2606:4700:4700::1111"
[ -z "$DNS6_2" ] && DNS6_2="2606:4700:4700::1001"

# ───── Log rotation ─────
if [ "$VERBOSE_LOG" = "1" ]; then
  [ -f "$LOG" ] && mv "$LOG" "$LOG.bak"
  touch "$LOG"
fi

# ─────────────────────────────────────────────────────────────
# 📝 Logging function (respects VERBOSE_LOG)
log() {
  [ "$VERBOSE_LOG" = "1" ] && echo "[liteDNS] $*" >> "$LOG"
}

# ─────────────────────────────────────────────────────────────
# 🔍 Determine correct property tool
if command -v resetprop >/dev/null 2>&1; then
  PROPTOOL="resetprop -n"
else
  PROPTOOL="setprop"  # Only safe in late stages (like service.sh)
fi

log "Starting service.sh..."

# ───── Check if port 53 is already in use
check_port_53() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp | grep -q ":53 "
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tuln | grep -q ":53 "
  elif command -v lsof >/dev/null 2>&1; then
    lsof -i :53 | grep -q LISTEN
  else
    log "⚠️ No tool available to check port 53. Assuming it's free."
    return 1  # default to not blocking
  fi
}

# ─────────────────────────────────────────────────────────────
# 🔐 DoH logic: override DNS and launch dnscrypt-proxy if enabled
if [ "$ENABLE_DOH" = "1" ]; then
  DNS1="127.0.0.1"
  DNS2="127.0.0.1"
  log "DoH mode enabled."

  if [ -x "$DNSCRYPT_BIN" ] && [ -f "$DNSCRYPT_CONF" ]; then
    if check_port_53; then
      log "❌ Port 53 is already in use. Skipping dnscrypt-proxy startup."
    else
      "$DNSCRYPT_BIN" -config "$DNSCRYPT_CONF" >> "$MODDIR/dnscrypt.log" 2>> "$MODDIR/dnscrypt-fail.log" &
      sleep 1

      if pgrep -f "$DNSCRYPT_BIN" >/dev/null 2>&1; then
        log "✅ dnscrypt-proxy is running."
      else
        log "❌ dnscrypt-proxy failed to start."
        if [ "$FAILSAFE_FALLBACK" = "1" ]; then
          DNS1="1.1.1.1"
          DNS2="1.0.0.1"
          log "🔄 Fallback activated: using $DNS1 / $DNS2"
        fi
      fi
    fi
  else
    log "❌ dnscrypt-proxy binary or config not found. Skipping DoH."
  fi
else
  log "DoH disabled. Using fallback DNS: $DNS1 / $DNS2"
fi

# ─────────────────────────────────────────────────────────────
# 🌐 Apply DNS to mobile data interfaces dynamically
for IFACE in $(ip -o link show | awk -F': ' '{print $2}' | grep -E '^rmnet|^pdp|^ppp'); do
  $PROPTOOL net.$IFACE.dns1 "$DNS1"
  $PROPTOOL net.$IFACE.dns2 "$DNS2"
  [ "$ENABLE_IPV6" = "1" ] && {
    $PROPTOOL net.$IFACE.dns3 "$DNS6_1"
    $PROPTOOL net.$IFACE.dns4 "$DNS6_2"
  }
  log "Applied DNS to $IFACE: $DNS1 / $DNS2"
done

# Apply global DNS props
$PROPTOOL net.dns1 "$DNS1"
$PROPTOOL net.dns2 "$DNS2"
log "Global DNS set to $DNS1 / $DNS2"

if [ "$ENABLE_IPV6" = "1" ]; then
  $PROPTOOL net.dns3 "$DNS6_1"
  $PROPTOOL net.dns4 "$DNS6_2"
  log "Global IPv6 DNS set to $DNS6_1 / $DNS6_2"
fi

[ "$FAILSAFE_FALLBACK" = "1" ] && log "Failsafe fallback is enabled."

# ─────────────────────────────────────────────────────────────
