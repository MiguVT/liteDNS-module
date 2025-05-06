#!/system/bin/sh

# Get module base path dynamically
MODDIR=${0%/*}
CONFIG="$MODDIR/config.sh"

# Load config or fallback to default
[ -f "$CONFIG" ] && . "$CONFIG" || {
  DNS1="1.1.1.1"
  DNS2="1.0.0.1"
}

# Detect resetprop availability (Magisk or KernelSU environment)
if command -v resetprop >/dev/null 2>&1; then
  PROPTOOL="resetprop -n"
else
  PROPTOOL="setprop"
fi

# Reapply DNS on mobile interfaces just in case
for IFACE in rmnet0 rmnet1 ppp0 pdpbr1; do
  ip link show "$IFACE" >/dev/null 2>&1 && {
    $PROPTOOL net.$IFACE.dns1 "$DNS1"
    $PROPTOOL net.$IFACE.dns2 "$DNS2"
  }
done

# Optional log
echo "[liteDNS] boot-completed.sh reapplied DNS $DNS1 / $DNS2 on mobile interfaces" > "$MODDIR/litedns-boot.log"
