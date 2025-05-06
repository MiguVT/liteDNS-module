#!/system/bin/sh
# customize.sh for liteDNS – DoH setup with dynamic release fetching

MODDIR=${0%/*}
CONFIG="$MODDIR/config.sh"
BIN_DIR="$MODDIR/bin"
BIN_ZIP="$BIN_DIR/dnscrypt-proxy.zip"
BIN_PATH="$BIN_DIR/dnscrypt-proxy"
CONF_FILE="$MODDIR/dnscrypt-proxy.toml"
API_URL="https://api.github.com/repos/DNSCrypt/dnscrypt-proxy/releases/latest"

# ─────────────────────────────────────────────────────────────
# 🛠️ Config file check
if [ -f "$CONFIG" ]; then
  ui_print "⚙️ Existing config.sh detected."
  ui_print "If you're simply updating liteDNS, press Volume - (NO)."
  ui_print "To reset and reconfigure DoH, press Volume + (YES)."
  chooseport 443
  OVERWRITE=$?

  if [ "$OVERWRITE" = "0" ]; then
    ui_print "🗑️ Removing old config..."
    rm -f "$CONFIG"
  else
    ui_print "✅ Keeping existing config. Skipping reconfiguration."
    exit 0
  fi
fi

# ─────────────────────────────────────────────────────────────
# 🔍 Detect architecture
ABI=$(getprop ro.product.cpu.abi)
case "$ABI" in
  arm64-v8a) ARCH="android_arm64" ;;
  armeabi-v7a) ARCH="android_arm" ;;
  x86) ARCH="android_i386" ;;
  x86_64) ARCH="android_x86_64" ;;
  *)
    ui_print "⚠️ Unknown architecture: $ABI"
    ui_print "Falling back to android_arm64 (most compatible)."
    ARCH="android_arm64"
    ;;
esac
ui_print "📦 Detected architecture: $ABI → $ARCH"

# 🔎 Ensure required tools exist
for cmd in curl unzip; do
  if ! command -v $cmd >/dev/null 2>&1; then
    abort "❌ Required command '$cmd' is missing. Aborting."
  fi
done

# ─────────────────────────────────────────────────────────────
# 🔐 DoH prompt
ui_print "🛡️ liteDNS DoH Integration"
ui_print "Would you like to enable DNS over HTTPS using dnscrypt-proxy?"
ui_print "    [Volume +] Yes (recommended)"
ui_print "    [Volume -] No"

chooseport 443
CHOICE=$?

if [ "$CHOICE" = "0" ]; then
  ui_print "✔️ DoH installation selected."
  ENABLE_DOH="1"
elif [ "$CHOICE" = "1" ]; then
  ui_print "❌ DoH skipped by user."
  ENABLE_DOH="0"
else
  ui_print "⚠️ No input detected. Assuming YES by default (recommended)."
  ENABLE_DOH="1"
fi

# Save config
echo "ENABLE_DOH=$ENABLE_DOH" > "$CONFIG"
echo "VERBOSE_LOG=1" >> "$CONFIG"
echo "FAILSAFE_FALLBACK=1" >> "$CONFIG"
echo "ENABLE_IPV6=1" >> "$CONFIG"

# ─────────────────────────────────────────────────────────────
# 🌐 Download & setup dnscrypt-proxy
if [ "$ENABLE_DOH" = "1" ]; then
  ui_print "🌐 Fetching latest dnscrypt-proxy version..."

  VERSION=$(curl -fsSL "$API_URL" | grep -o '"tag_name": *"[^"]*"' | head -n1 | cut -d'"' -f4)
  [ -z "$VERSION" ] && abort "❌ Failed to fetch version from GitHub."

  ZIP_NAME="dnscrypt-proxy-${ARCH}-${VERSION}.zip"
  ZIP_URL="https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/${VERSION}/${ZIP_NAME}"

  ui_print "⬇️ Downloading: $ZIP_NAME"

  mkdir -p "$BIN_DIR"
  if ! curl -fsSL -o "$BIN_ZIP" "$ZIP_URL"; then
    abort "❌ Failed to download $ZIP_NAME."
  fi

  if ! unzip -o "$BIN_ZIP" -d "$BIN_DIR" >/dev/null 2>&1; then
    rm -f "$BIN_ZIP"
    abort "❌ Failed to unzip $ZIP_NAME."
  fi

  [ ! -f "$BIN_PATH" ] && abort "❌ dnscrypt-proxy binary missing after extraction."

  chmod -R 755 "$BIN_DIR"
  rm -f "$BIN_ZIP"

  ui_print "✅ dnscrypt-proxy $VERSION installed successfully."

  if [ ! -f "$CONF_FILE" ]; then
    ui_print "🧩 Creating default configuration (dnscrypt-proxy.toml)..."

    cat <<EOF > "$CONF_FILE"
listen_addresses = ['127.0.0.1:53']
server_names = ['cloudflare']
ipv4_servers = true
require_dnssec = true
require_nolog = true
require_nofilter = true
dnscrypt_servers = false
doh_servers = true
odoh_servers = false
fallback_resolvers = ['9.9.9.9:53', '1.1.1.1:53']
max_clients = 250
keepalive = 30
log_level = 2
EOF

    chmod 644 "$CONF_FILE"
    ui_print "✅ Default config created."
  fi
fi
