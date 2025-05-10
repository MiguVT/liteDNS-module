#!/system/bin/sh
# liteDNS - Advanced DNS management for Android
# Handles both static configuration and dynamic interface monitoring

# ─────────────────────────────────────────────────────────────
# Constants and configuration paths
MODDIR="${0%/*}"
TEMPLATE_CONF="$MODDIR/dnscrypt-proxy.toml.template"
TARGET_CONF="$MODDIR/dnscrypt-proxy.toml"
CONFIG="$MODDIR/config.sh"
LOG_DIR="$MODDIR/log"
LOG="$LOG_DIR/service.log"
DOH_LOG="$LOG_DIR/dnscrypt.log"
BIN="$MODDIR/bin/dnscrypt-proxy"
IFACES_FILE="$MODDIR/active_interfaces.txt"
LOCK_FILE="$MODDIR/litedns.lock"
PID_FILE="$MODDIR/litedns.pid"
MONITOR_PID_FILE="$MODDIR/monitor.pid"

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
  if echo "$DNS" | grep -q ':'; then
    # DNS already has a port
    sed -i "s|^bootstrap_resolvers *=.*|bootstrap_resolvers = ['$DNS']|" "$TARGET_CONF"
  else
    # No port specified, append default port 53
    sed -i "s|^bootstrap_resolvers *=.*|bootstrap_resolvers = ['$DNS:53']|" "$TARGET_CONF"
  fi
  log "Patched TOML → SERVERS=$DOH_SERVERS_NAME BOOTSTRAP=$DNS"
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
  
  # Check if interface exists
  if [ ! -d "/sys/class/net/$iface" ]; then
    [ "$VERBOSE_LOG" -eq 1 ] && log "Interface $iface does not exist, skipping"
    return 1
  fi
  
  # Wait a moment for interface to initialize fully (important for dynamic interfaces)
  sleep 0.5
  
  # Check if rules already exist to avoid duplicates
  if iptables -t nat -C OUTPUT -o "$iface" -p udp --dport 53 -j DNAT --to-destination "${target_dns}:53" 2>/dev/null; then
    [ "$VERBOSE_LOG" -eq 1 ] && log "Rules already exist for $iface, skipping"
    return 0
  fi
  
  # Redirect both UDP and TCP destined to port 53 on the given interface
  iptables -t nat -A OUTPUT -o "$iface" -p udp --dport 53 -j DNAT --to-destination "${target_dns}:53" \
    || log "Failed to apply iptables rule (UDP) on $iface"
  iptables -t nat -A OUTPUT -o "$iface" -p tcp --dport 53 -j DNAT --to-destination "${target_dns}:53" \
    || log "Failed to apply iptables rule (TCP) on $iface"
  log "Applied iptables DNS redirection on $iface to ${target_dns}"
  return 0
}

# ─────────────────────────────────────────────────────────────
# Interface monitoring system

# Clean up any previous monitoring processes
cleanup_previous_monitors() {
  if [ -f "$MONITOR_PID_FILE" ]; then
    local old_pid=$(cat "$MONITOR_PID_FILE" 2>/dev/null)
    [ -n "$old_pid" ] && kill "$old_pid" >/dev/null 2>&1
    rm -f "$MONITOR_PID_FILE"
  fi
}

# Update the list of currently active interfaces
update_interface_list() {
  ip -o link show | awk -F': ' '{print $2}' | grep -E '^(wlan|rmnet|pdp|ppp|rmnet_data)' > "$IFACES_FILE"
}

# Process a newly detected interface
process_new_interface() {
  local iface="$1"
  
  # Skip if not a network interface we care about
  if ! echo "$iface" | grep -qE '^(wlan|rmnet|pdp|ppp|rmnet_data)'; then
    return 0
  fi
  
  # Apply rules based on interface type
  case "$iface" in
    wlan*)
      [ "$WIFI_CUSTOM_DNS" -eq 1 ] && apply_dns_iptables "$iface" "$DNS"
      ;;
    rmnet*|pdp*|ppp*|rmnet_data*)
      [ "$MOBILE_CUSTOM_DNS" -eq 1 ] && apply_dns_iptables "$iface" "$DNS"
      ;;
  esac
}

# Start interface monitoring
start_interface_monitor() {
  # Clean up previous monitors
  cleanup_previous_monitors
  
  # Create initial interface list
  update_interface_list
  log "Initial interface list created with $(wc -l < "$IFACES_FILE") interfaces"
  
  # Start the interface monitor in background
  (
    # Use inotifyd if available (most efficient)
    if command -v inotifyd >/dev/null; then
      log "Using inotifyd for interface monitoring"
      
      # Monitor /sys/class/net directory for create events
      inotifyd - /sys/class/net:n 2>/dev/null | while read -r line; do
        # Parse the inotifyd event line (format: /path e mask)
        local path=$(echo "$line" | awk '{print $1}')
        local event=$(echo "$line" | awk '{print $2}')
        
        # Extract interface name from path
        local iface=$(basename "$path")
        
        # Process interface if it's a creation event
        if [ "$event" = "c" ] || [ "$event" = "C" ]; then
          log "Detected new interface via inotifyd: $iface"
          process_new_interface "$iface"
          
          # Update our interface list
          update_interface_list
        fi
      done
    else
      # Fallback to efficient polling
      log "inotifyd not available, using polling for interface monitoring"
      
      while true; do
        # Get current interfaces
        local current_ifaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(wlan|rmnet|pdp|ppp|rmnet_data)')
        
        # Find new interfaces by comparing with saved list
        for iface in $current_ifaces; do
          if ! grep -q "^$iface$" "$IFACES_FILE" 2>/dev/null; then
            log "Detected new interface via polling: $iface"
            process_new_interface "$iface"
          fi
        done
        
        # Update interface list
        echo "$current_ifaces" > "$IFACES_FILE"
        
        # Sleep to reduce battery impact (10 seconds is a good balance)
        sleep 10
      done
    fi
  ) &
  
  # Save monitor PID
  echo $! > "$MONITOR_PID_FILE"
  log "Started interface monitor (PID: $(cat "$MONITOR_PID_FILE"))"
}

# ─────────────────────────────────────────────────────────────
# Apply iptables rules based on interface type

# For mobile-data interfaces (rmnet, pdp, ppp, rmnet_data)
if [ "$MOBILE_CUSTOM_DNS" -eq 1 ]; then
  for iface in $(ls /sys/class/net 2>/dev/null | grep -E '^(rmnet|pdp|ppp|rmnet_data)'); do
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

# ─────────────────────────────────────────────────────────────
# Start the interface monitor after all initial rules are applied
start_interface_monitor
