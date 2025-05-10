#!/system/bin/sh
# liteDNS - Advanced DNS Management for Android
# This script provides a robust solution for DNS management on Android devices.
# It handles both static DNS configurations and dynamic interface monitoring.
# Features:
# - Dynamic DNS redirection for Wi-Fi and mobile-data interfaces.
# - Optional support for encrypted DNS (DNS over HTTPS) using dnscrypt-proxy.
# - Global DNS override for outgoing traffic.
# - Adaptive monitoring of network interfaces with fallback mechanisms.

# ─────────────────────────────────────────────────────────────
# Constants and Configuration Paths
# These variables define file paths, constants, and configuration options.

MODDIR="${0%/*}"                           # Directory where the script resides
TEMPLATE_CONF="$MODDIR/dnscrypt-proxy.toml.template" # Path to the TOML template for dnscrypt-proxy
TARGET_CONF="$MODDIR/dnscrypt-proxy.toml"  # Generated TOML configuration for dnscrypt-proxy
CONFIG="$MODDIR/config.sh"                 # User configuration file
LOG_DIR="$MODDIR/log"                      # Directory for log files
LOG="$LOG_DIR/service.log"                 # Main log file for the script
DOH_LOG="$LOG_DIR/dnscrypt.log"            # Log file for dnscrypt-proxy
BIN="$MODDIR/bin/dnscrypt-proxy"           # Path to the dnscrypt-proxy binary
IFACES_FILE="$MODDIR/active_interfaces.txt" # File to store active network interfaces
LOCK_FILE="$MODDIR/litedns.lock"           # Lock file to prevent multiple instances
PID_FILE="$MODDIR/litedns.pid"             # PID file for the main process
MONITOR_PID_FILE="$MODDIR/monitor.pid"     # PID file for the interface monitor process

# ─────────────────────────────────────────────────────────────
# Bootstrap Configuration and Logs
# Ensure necessary directories and files are in place, and initialize logs.

[ ! -d "$LOG_DIR" ] && mkdir -p "$LOG_DIR" # Create log directory if it doesn't exist
[ ! -f "$CONFIG" ] && cp "$MODDIR/config.sh.template" "$CONFIG" && chmod 644 "$CONFIG" # Initialize default config
# Rotate the main log file on each boot
[ -f "$LOG" ] && mv "$LOG" "$LOG.old"
: > "$LOG" # Create a fresh log file

# ─────────────────────────────────────────────────────────────
# Logging Helpers
# Functions to log events and handle errors with timestamps.

date_stamp() {
  # Generate a timestamp in the format YYYY-MM-DD HH:MM:SS
  date '+%F %T'
}

log() {
  # Log a message to the main log file with a timestamp
  echo "[liteDNS] $(date_stamp) – $*" >> "$LOG"
}

abort() {
  # Log an error message and terminate the script
  log "ERROR: $*"
  exit 1
}

# ─────────────────────────────────────────────────────────────
# Load Configuration Values
# Load user-defined settings from the configuration file. Provide defaults if missing.

. "$CONFIG"
: "${VERBOSE_LOG:=1}"             # Enable verbose logging (default: enabled)
: "${WIFI_CUSTOM_DNS:=1}"         # Enable custom DNS for Wi-Fi interfaces
: "${MOBILE_CUSTOM_DNS:=1}"       # Enable custom DNS for mobile-data interfaces
: "${ENABLE_DOH:=0}"              # Enable DNS over HTTPS (default: disabled)
: "${DOH_SERVERS_NAME:='cloudflare'}" # Default DoH server names
: "${FAILSAFE_FALLBACK:=1}"       # Enable fallback to default DNS
: "${DNS:=1.1.1.1}"               # Default DNS server
: "${GLOBAL_DNS_OVERRIDE:=1}"     # Apply global DNS override (default: enabled)

log "service.sh started (DoH=$ENABLE_DOH, DNS=$DNS, WIFI_CUSTOM_DNS=$WIFI_CUSTOM_DNS, MOBILE_CUSTOM_DNS=$MOBILE_CUSTOM_DNS)"

# ─────────────────────────────────────────────────────────────
# Prepare dnscrypt-proxy.toml Configuration
# Generate and customize the dnscrypt-proxy TOML configuration file if DoH is enabled.

if [ "$ENABLE_DOH" -eq 1 ]; then
  if [ ! -f "$TARGET_CONF" ]; then
    cp "$TEMPLATE_CONF" "$TARGET_CONF" || abort "Could not copy TOML template"
    chmod 644 "$TARGET_CONF"
  fi
  # Update server_names in the TOML file with the configured DoH servers
  ESC_NAMES=$(printf '%s' "$DOH_SERVERS_NAME" | sed "s/,/','/g")
  sed -i "s|^server_names *=.*|server_names = ['$ESC_NAMES']|" "$TARGET_CONF" \
    || abort "Failed to update server_names"
  # Configure bootstrap resolvers in the TOML file
  if echo "$DNS" | grep -q ':'; then
    sed -i "s|^bootstrap_resolvers *=.*|bootstrap_resolvers = ['$DNS']|" "$TARGET_CONF"
  else
    sed -i "s|^bootstrap_resolvers *=.*|bootstrap_resolvers = ['$DNS:53']|" "$TARGET_CONF"
  fi
  log "Patched TOML → SERVERS=$DOH_SERVERS_NAME BOOTSTRAP=$DNS"
fi

# ─────────────────────────────────────────────────────────────
# Start DNS over HTTPS (DoH) Service
# Launch dnscrypt-proxy if DoH is enabled and set up necessary iptables rules.

start_doh() {
  # Start the dnscrypt-proxy service and configure fallback mechanisms
  LOCAL_DNS="127.0.0.1" # Use localhost for DNS if dnscrypt-proxy starts successfully
  if [ ! -x "$BIN" ] || [ ! -f "$TARGET_CONF" ]; then
    log "DoH disabled: missing binary or config"
    return
  fi
  if ss -ltnp 2>/dev/null | grep -q ':53 '; then
    log "Port 53 in use: skipping dnscrypt-proxy"
    return
  fi
  # Allow fallback DNS for resolving dnscrypt-proxy's bootstrap
  iptables -t nat -A OUTPUT -p udp --dport 53 -d $DNS -j RETURN
  iptables -t nat -A OUTPUT -p tcp --dport 53 -d $DNS -j RETURN
  "$BIN" -config "$TARGET_CONF" >>"$DOH_LOG" 2>&1 &
  sleep 1
  if pgrep -f "$BIN" >/dev/null; then
    log "dnscrypt-proxy launched successfully"
    DNS="$LOCAL_DNS"
  else
    log "dnscrypt-proxy failed to start"
    [ "$FAILSAFE_FALLBACK" -eq 1 ] && log "Fallback to configured DNS: $DNS"
  fi
}

if [ "$ENABLE_DOH" -eq 1 ]; then
  start_doh
else
  log "DoH not enabled: using configured DNS $DNS"
fi
log "Exiting start_doh function"

# ─────────────────────────────────────────────────────────────
# Apply iptables DNS Redirection
# Redirect DNS traffic on specific interfaces to the configured DNS server.

apply_dns_iptables() {
  local iface="$1"
  local target_dns="$2"
  local base_iface
  
  base_iface=$(echo "$iface" | cut -d '@' -f 1) # Extract base interface name
  [ ! -d "/sys/class/net/$base_iface" ] && [ "$VERBOSE_LOG" -eq 1 ] && log "Interface $base_iface does not exist, skipping" && return 1
  
  sleep 0.5 # Allow time for interface initialization
  if iptables -t nat -C OUTPUT -o "$base_iface" -p udp --dport 53 -j DNAT --to-destination "${target_dns}:53" 2>/dev/null; then
    [ "$VERBOSE_LOG" -eq 1 ] && log "Rules already exist for $base_iface, skipping"
    return 0
  fi
  iptables -t nat -A OUTPUT -o "$base_iface" -p udp --dport 53 -j DNAT --to-destination "${target_dns}:53" || log "Failed to apply iptables rule (UDP) on $base_iface"
  iptables -t nat -A OUTPUT -o "$base_iface" -p tcp --dport 53 -j DNAT --to-destination "${target_dns}:53" || log "Failed to apply iptables rule (TCP) on $base_iface"
  log "Applied iptables DNS redirection on $base_iface to ${target_dns}"
  return 0
}

# ─────────────────────────────────────────────────────────────
# Interface Monitoring System
# Dynamically monitor and manage DNS rules for active network interfaces.

cleanup_previous_monitors() {
  if [ -f "$MONITOR_PID_FILE" ]; then
    local old_pid=$(cat "$MONITOR_PID_FILE" 2>/dev/null)
    [ -n "$old_pid" ] && kill "$old_pid" >/dev/null 2>&1
    rm -f "$MONITOR_PID_FILE"
  fi
}

process_new_interface() {
  local iface="$1"
  local base_iface=$(echo "$iface" | cut -d '@' -f 1)
  if ! echo "$base_iface" | grep -qE '^(wlan|rmnet|pdp|ppp|rmnet_data)'; then
    return 0
  fi
  case "$base_iface" in
    wlan*) [ "$WIFI_CUSTOM_DNS" -eq 1 ] && apply_dns_iptables "$base_iface" "$DNS" ;;
    rmnet*|pdp*|ppp*|rmnet_data*) [ "$MOBILE_CUSTOM_DNS" -eq 1 ] && apply_dns_iptables "$base_iface" "$DNS" ;;
  esac
}

start_interface_monitor() {
  cleanup_previous_monitors
  log "Processing existing network interfaces..."
  for iface in $(ls /sys/class/net 2>/dev/null | grep -E '^(wlan|rmnet|pdp|ppp|rmnet_data)'); do
    local base_iface=$(echo "$iface" | cut -d '@' -f 1)
    log "Processing existing interface: $base_iface"
    process_new_interface "$base_iface"
  done

  ip -o link show | awk -F': ' '{print $2}' | cut -d '@' -f 1 | grep -E '^(wlan|rmnet|pdp|ppp|rmnet_data)' > "$IFACES_FILE"
  log "Initial interface list created with $(wc -l < "$IFACES_FILE") interfaces"
  
  (
    if command -v ip >/dev/null; then
      log "Using ip monitor for interface monitoring"
      ip monitor link 2>/dev/null | while read -r line; do
        [ "$VERBOSE_LOG" -eq 1 ] && log "Network event: $line"
        if echo "$line" | grep -q "state UP"; then
          local iface=$(echo "$line" | awk '{print $2}' | cut -d '@' -f 1 | sed 's/://g')
          if echo "$iface" | grep -qE '^(wlan|rmnet|pdp|ppp|rmnet_data)'; then
            log "Active interface detected: $iface"
            process_new_interface "$iface"
            ip -o link show | awk -F': ' '{print $2}' | cut -d '@' -f 1 | grep -E '^(wlan|rmnet|pdp|ppp|rmnet_data)' > "$IFACES_FILE"
          fi
        fi
      done
    else
      log "ip monitor not available, using adaptive polling"
      local sleep_time=5
      local changes_detected=0
      while true; do
        for iface in $(ls /sys/class/net/ 2>/dev/null); do
          local base_iface=$(echo "$iface" | cut -d '@' -f 1)
          if echo "$base_iface" | grep -qE '^(wlan|rmnet|pdp|ppp|rmnet_data)'; then
            if [ -f "/sys/class/net/$iface/operstate" ] && [ "$(cat "/sys/class/net/$iface/operstate")" = "up" ] && ! grep -q "^$base_iface$" "$IFACES_FILE" 2>/dev/null; then
              log "New active interface detected: $base_iface"
              process_new_interface "$base_iface"
              echo "$base_iface" >> "$IFACES_FILE"
              changes_detected=1
            fi
          fi
        done
        if [ "$changes_detected" -eq 1 ]; then
          sleep_time=5
          changes_detected=0
        else
          [ "$sleep_time" -lt 30 ] && sleep_time=$((sleep_time + 5))
        fi
        sleep $sleep_time
      done
    fi
  ) &
  
  echo $! > "$MONITOR_PID_FILE"
  log "Interface monitor started (PID: $(cat "$MONITOR_PID_FILE"))"
  trap 'log "Trap triggered: Cleaning up interface monitor"; cleanup_previous_monitors' EXIT
}

# ─────────────────────────────────────────────────────────────
# Apply Initial DNS Rules
# Apply DNS redirection rules for active Wi-Fi and mobile-data interfaces.

if [ "$MOBILE_CUSTOM_DNS" -eq 1 ]; then
  for iface in $(ls /sys/class/net 2>/dev/null | grep -E '^(rmnet|pdp|ppp|rmnet_data)'); do
    local base_iface=$(echo "$iface" | cut -d '@' -f 1)
    apply_dns_iptables "$base_iface" "$DNS"
  done
fi
log "🔍 (A) applying mobile rules"
if [ "$WIFI_CUSTOM_DNS" -eq 1 ]; then
  for iface in $(ls /sys/class/net 2>/dev/null | grep -E '^wlan'); do
    local base_iface=$(echo "$iface" | cut -d '@' -f 1)
    apply_dns_iptables "$base_iface" "$DNS"
  done
fi
log "🔍 (B) applying wifi rules"
# ─────────────────────────────────────────────────────────────
# Apply Global DNS Override
# Redirect all outgoing DNS traffic to the configured DNS server if enabled.

if [ "$GLOBAL_DNS_OVERRIDE" -eq 1 ]; then
  iptables -t nat -A OUTPUT -p udp --dport 53 -j DNAT --to-destination "${DNS}:53" || log "Failed to apply global iptables rule (UDP)"
  iptables -t nat -A OUTPUT -p tcp --dport 53 -j DNAT --to-destination "${DNS}:53" || log "Failed to apply global iptables rule (TCP)"
  log "Global DNS redirect applied to all outgoing traffic to ${DNS}"
fi

# ─────────────────────────────────────────────────────────────
# Start Interface Monitoring
# Begin dynamic monitoring of network interfaces after initial configuration.
log "🔍 before starting interface monitor"
start_interface_monitor
log "🔍 after start_interface_monitor?"