#!/system/bin/sh
# Handler script for inotifyd to process network interface events

# Source the main service script to access its functions
. "${0%/*}/service.sh"

while read -r event; do
  iface=$(echo "$event" | awk '{print $3}')
  log "DEBUG: Detected new interface: $iface"
  process_new_interface "$iface"
done
