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
# Set debug mode if DEBUG is enabled
if [ "$VERBOSE_LOG" -eq 1 ]; then
  set -x # Enable debug mode for verbose logging
else
  set +x # Disable debug mode
  set +v # Enable verbose mode for logging
fi

# ─────────────────────────────────────────────────────────────
# Logging Helpers
# Functions to log events and handle errors with timestamps.

date_stamp() {
  # Generate a timestamp in the format YYYY-MM-DD HH:MM:SS
  date '+%F %T'
}

log() {
  # if DEBUG is disabled, check if $* starts with "DEBUG", then not log and return
  if [ "$VERBOSE_LOG" -eq 0 ] && [[ "$*" == DEBUG* ]]; then
    return
  fi
  # Log a message to the main log file with a timestamp
  echo "[liteDNS] $(date_stamp) – $*" >> "$LOG"
}

abort() {
  # Log an error message and terminate the script
  log "ERROR: $*"
  exit 1
}

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
  log "DEBUG: Entering start_doh function"
  # Start the dnscrypt-proxy service and configure fallback mechanisms
  LOCAL_DNS="127.0.0.1" # Use localhost for DNS if dnscrypt-proxy starts successfully
  
  if [ ! -x "$BIN" ] || [ ! -f "$TARGET_CONF" ]; then
    log "DoH disabled: missing binary or config"
    log "DEBUG: Binary exists: $( [ -x "$BIN" ] && echo "yes" || echo "no" )"
    log "DEBUG: Config exists: $( [ -f "$TARGET_CONF" ] && echo "yes" || echo "no" )"
    return
  fi
  
  log "DEBUG: Checking if port 53 is in use"
  if ss -ltnp 2>/dev/null | grep -q ':53 '; then
    log "Port 53 in use: skipping dnscrypt-proxy"
    return
  fi
  
  log "DEBUG: Adding iptables rules for bootstrap DNS"
  # Allow fallback DNS for resolving dnscrypt-proxy's bootstrap
  iptables -t nat -A OUTPUT -p udp --dport 53 -d $DNS -j RETURN || log "DEBUG: Failed to add UDP bootstrap rule"
  iptables -t nat -A OUTPUT -p tcp --dport 53 -d $DNS -j RETURN || log "DEBUG: Failed to add TCP bootstrap rule"
  
  log "DEBUG: Launching dnscrypt-proxy"
  "$BIN" -config "$TARGET_CONF" >>"$DOH_LOG" 2>&1 &
  sleep 1
  
  log "DEBUG: Checking if dnscrypt-proxy is running"
  if pgrep -f "$BIN" >/dev/null; then
    log "dnscrypt-proxy launched successfully"
    log "DEBUG: Setting DNS to localhost ($LOCAL_DNS)"
    DNS="$LOCAL_DNS"
  else
    log "dnscrypt-proxy failed to start"
    log "DEBUG: dnscrypt-proxy process not found"
    [ "$FAILSAFE_FALLBACK" -eq 1 ] && log "Fallback to configured DNS: $DNS"
  fi
  
  log "DEBUG: Exiting start_doh function"
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

# Enhance logging in apply_dns_iptables to debug rule application
apply_dns_iptables() {
  local iface="$1"
  local target_dns="$2"

  log "DEBUG: Entering apply_dns_iptables for interface $iface with DNS $target_dns"

  if [ ! -d "/sys/class/net/$iface" ]; then
    log "ERROR: Interface $iface does not exist, skipping"
    return 1
  fi

  log "DEBUG: Interface $iface exists, proceeding with iptables rules"

  # Remove existing rules to avoid conflicts
  iptables -t nat -D OUTPUT -o "$iface" -p udp --dport 53 -j DNAT --to-destination "${target_dns}:53" 2>/dev/null
  iptables -t nat -D OUTPUT -o "$iface" -p tcp --dport 53 -j DNAT --to-destination "${target_dns}:53" 2>/dev/null

  # Add new rules
  iptables -t nat -A OUTPUT -o "$iface" -p udp --dport 53 -j DNAT --to-destination "${target_dns}:53" || {
    log "ERROR: Failed to apply iptables rule (UDP) on $iface";
    return 1;
  }

  iptables -t nat -A OUTPUT -o "$iface" -p tcp --dport 53 -j DNAT --to-destination "${target_dns}:53" || {
    log "ERROR: Failed to apply iptables rule (TCP) on $iface";
    return 1;
  }

  log "Applied iptables DNS redirection on $iface to ${target_dns}"
  log "DEBUG: Exiting apply_dns_iptables successfully"
  return 0
}

# Update process_new_interface to recognize rmnet_ipa0 as a valid mobile interface
process_new_interface() {
  local iface="$1"
  log "DEBUG: Entering process_new_interface for $iface"

  # Check for mobile data interface
  if echo "$iface" | grep -qE "^rmnet"; then
    log "DEBUG: Processing mobile interface $iface (MOBILE_CUSTOM_DNS=$MOBILE_CUSTOM_DNS)"
    [ "$MOBILE_CUSTOM_DNS" -eq 1 ] && apply_dns_iptables "$iface" "$DNS"
  # Check for Wi-Fi interface
  elif echo "$iface" | grep -q "wlan"; then
    log "DEBUG: Processing WiFi interface $iface (WIFI_CUSTOM_DNS=$WIFI_CUSTOM_DNS)"
    [ "$WIFI_CUSTOM_DNS" -eq 1 ] && apply_dns_iptables "$iface" "$DNS"
  else
    log "DEBUG: Interface $iface is not a supported type, skipping"
  }

  log "DEBUG: Exiting process_new_interface for $iface"
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

# Function to start monitoring network interfaces
# Monitors for changes in interface states and processes them dynamically
# Add debug logs to confirm monitoring subprocess is running
start_interface_monitor() {
  log "DEBUG: Entering start_interface_monitor"
  cleanup_previous_monitors
  log "DEBUG: Previous monitors cleaned up"

  # Process existing interfaces at startup
  log "DEBUG: Processing existing network interfaces at startup"
  for iface in $(ls /sys/class/net 2>/dev/null); do
    log "DEBUG: Found existing interface: $iface"
    process_new_interface "$iface"
  done

  # Start monitoring for interface changes
  log "DEBUG: Starting interface monitor subprocess"
  (
    if command -v ip >/dev/null; then
      log "DEBUG: Using ip monitor for interface monitoring"
      ip monitor link 2>/dev/null | while read -r line; do
        log "DEBUG: Network event detected: $line"
        if echo "$line" | grep -q "state UP"; then
          local iface=$(echo "$line" | awk '{print $2}' | cut -d '@' -f 1 | sed 's/://g')
          log "DEBUG: Detected interface state change: $iface"
          process_new_interface "$iface"
        fi
      done
    else
      log "DEBUG: ip monitor not available, using adaptive polling"
      while true; do
        for iface in $(ls /sys/class/net/ 2>/dev/null); do
          if [ -f "/sys/class/net/$iface/operstate" ] && [ "$(cat "/sys/class/net/$iface/operstate")" = "up" ]; then
            log "DEBUG: Detected active interface: $iface"
            process_new_interface "$iface"
          fi
        done
        sleep 5
      done
    fi
  ) &

  echo $! > "$MONITOR_PID_FILE"
  log "DEBUG: Interface monitor started (PID: $(cat "$MONITOR_PID_FILE"))"
  log "DEBUG: Exiting start_interface_monitor"
  trap 'log "Trap triggered: Cleaning up interface monitor"; cleanup_previous_monitors' EXIT
}

# ─────────────────────────────────────────────────────────────
# Apply Initial DNS Rules
# Apply DNS redirection rules for active Wi-Fi and mobile-data interfaces.
log "DEBUG: Starting initial DNS rules application"

# Update mobile interface detection in initial DNS rules application
if [ "$MOBILE_CUSTOM_DNS" -eq 1 ]; then
  log "DEBUG: Processing mobile interfaces for initial setup"
  mobile_interfaces=$(ls /sys/class/net 2>/dev/null | grep -E '^rmnet')
  log "DEBUG: Found mobile interfaces: $mobile_interfaces"

  for iface in $mobile_interfaces; do
    base_iface=$(echo "$iface" | cut -d '@' -f 1)
    log "DEBUG: Processing mobile interface: $base_iface"
    apply_dns_iptables "$base_iface" "$DNS"
  done
  log "DEBUG: Completed mobile interface processing"
fi

if [ "$WIFI_CUSTOM_DNS" -eq 1 ]; then
  log "DEBUG: Processing WiFi interfaces for initial setup"
  wifi_interfaces=$(ls /sys/class/net 2>/dev/null | grep -E '^wlan')
  log "DEBUG: Found WiFi interfaces: $wifi_interfaces"
  
  for iface in $wifi_interfaces; do
    base_iface=$(echo "$iface" | cut -d '@' -f 1)
    log "DEBUG: Processing WiFi interface: $base_iface"
    apply_dns_iptables "$base_iface" "$DNS"
  done
  log "DEBUG: Completed WiFi interface processing"
fi

log "DEBUG: Finished initial DNS rules application"

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
start_interface_monitor