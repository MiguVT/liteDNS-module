#!/system/bin/sh
# customize.sh for liteDNS – DoH setup with dynamic release fetching

MODDIR=$MODPATH
TEMPLATE="$MODDIR/config.sh.template"
CONFIG="$MODDIR/config.sh"
BIN_DIR="$MODDIR/bin"
BIN_ZIP="$BIN_DIR/dnscrypt-proxy.zip"
BIN_PATH="$BIN_DIR/dnscrypt-proxy"
CONF_FILE="$MODDIR/dnscrypt-proxy.toml"
API_URL="https://api.github.com/repos/DNSCrypt/dnscrypt-proxy/releases/latest"
TIMEOUT=10
BRANCH="dev"
CONF_DELETED=1


MODID=$(grep 'id=' "$MODPATH/module.prop" | cut -d= -f2)
FINAL_DIR="/data/adb/modules/$MODID"
FINAL_CONFIG="$FINAL_DIR/config.sh"

ui_print "Final config path: $FINAL_CONFIG"

# ─────────────────────────────────────────────────────────────
# 🔨 Simple functions
newline(){
  local n="$1"
  for i in $(seq 1 "$n"); do
    echo
  done
}

# ─────────────────────────────────────────────────────────────
# 0️⃣ Init Debug (Not for production only for dev branch)
if [ "$BRANCH" = "dev" ]; then
  ui_print "⚠️ You are in dev branch, please use with caution. If you are not a developer, please switch download the module from github release page."
  ui_print "🔍 Module files at $MODDIR:"
  ls -1 "$MODDIR" >&2 | while read f; do ui_print "  • $f"; done
fi

# ─────────────────────────────────────────────────────────────
# 1️⃣ Volume-key prompt using timeout + getevent
choose_option(){
  local prompt="$1"
  ui_print "$prompt"
  ui_print " waiting up to ${TIMEOUT}s…"
  while :; do
    event=$(timeout ${TIMEOUT} getevent -qlc 1 2>/dev/null)
    code=$?
    # timeout returns 124 (toybox) or 143 (BusyBox)
    if [ $code -eq 124 ] || [ $code -eq 143 ]; then
      return 2
    fi
    echo "$event" | grep -q "KEY_VOLUMEUP.*DOWN"    && return 0
    echo "$event" | grep -q "KEY_VOLUMEDOWN.*DOWN"  && return 1
  done
}
if [ "$BRANCH" = "dev" ]; then
  ui_print "ℹ️ Step 1 success"
fi

# ─────────────────────────────────────────────────────────────
# 2️⃣ If config found, offer reset vs keep
if [ -f "$FINAL_CONFIG" ]; then
  ui_print "⚙️ Existing config detected."
  ui_print "🔼 VOL+ → reset, 🔽 VOL- → keep"
  choose_option " Make a choice:"
  case $? in
    0)
      ui_print "🗑️ Resetting config…"
      rm -f "$FINAL_CONFIG" \
        || abort "❌ Failed to delete config.sh (Step 2)"
      # print config.sh removed success
      ui_print "✅ Config reset to template."

      # ask if delete the entire module (For fresh install)
      ui_print "❗️ Do you want to delete the entire module? (for fresh install, recommended if config deleted)"
      ui_print "🔼 VOL+ → yes, 🔽 VOL- → no"
      choose_option " Make a choice:"
      case $? in
        0)
          ui_print "🗑️ Deleting module…"
          rm -rf "$FINAL_DIR" \
            || abort "❌ Failed to delete module (Step 2)"
          # print module removed success
          ui_print "✅ Module deleted."
          ;;
        1)
          ui_print "✅ Keeping module."
          ;;
        *)
          ui_print "⚠️ No input: keeping module. reflash module if you want to delete it."
          ;;
      esac
      ;;
    1)
      ui_print "✅ Keeping existing config."
      CONF_DELETED=0
      ;;
    *)
      ui_print "⚠️ No input: keeping config."
      CONF_DELETED=0
      ;;
  esac
fi
if [ "$BRANCH" = "dev" ]; then
  ui_print "ℹ️ Step 2 success"
fi



# ─────────────────────────────────────────────────────────────
# 3️⃣ Bootstrap config.sh from template on first install
if [ ! -f "$CONFIG" ]; then
  cp "$TEMPLATE" "$CONFIG" \
    || abort "❌ Could not copy config.sh.template → config.sh (Step 3)"
  chmod 644 "$CONFIG"
fi
if [ "$BRANCH" = "dev" ]; then
  ui_print "ℹ️ Step 3 success"
fi

# ─────────────────────────────────────────────────────────────
# 4️⃣ Detect CPU architecture
ABI=$(getprop ro.product.cpu.abi)
case "$ABI" in
  arm64-v8a)   ARCH="android_arm64"   ;;
  armeabi-v7a) ARCH="android_arm"      ;;
  x86)         ARCH="android_i386"     ;;
  x86_64)      ARCH="android_x86_64"   ;;
  *)
    ui_print "⚠️ Unknown ABI: $ABI → defaulting to android_arm64"
    ARCH="android_arm64"
    ;;
esac
ui_print "📦 ABI: $ABI → $ARCH"
if [ "$BRANCH" = "dev" ]; then
  ui_print "ℹ️ Step 4 success"
fi

# ─────────────────────────────────────────────────────────────
# 5️⃣ Ensure required binaries are present
for cmd in curl unzip getevent timeout; do
  command -v $cmd >/dev/null 2>&1 || abort "❌ '$cmd' is required, but missing. (Step 5)"
done
if [ "$BRANCH" = "dev" ]; then
  ui_print "ℹ️ Step 5 success"
fi

# ─────────────────────────────────────────────────────────────
# 6️⃣ Prompt DoH enable/disable (if config deleted in step 5)
if [ "$CONF_DELETED" -eq 1 ]; then
  newline 4
  ui_print "🛡️ liteDNS DoH Setup"
  ui_print "🔼 VOL+ → enable DoH (recommended)"
  ui_print "🔽 VOL- → disable DoH"
  choose_option ""
  case $? in
    0)  
      ui_print "✔️ Enabling DoH."
      CHOICE=1
      ;;
    1)  
      ui_print "❌ Disabling DoH."
      CHOICE=0
      ;;
    *)
      ui_print "⚠️ Timeout: enabling DoH by default."
      CHOICE=1
      ;;
  esac
fi
if [ "$BRANCH" = "dev" ]; then
  ui_print "ℹ️ Step 6 success"
fi
newline 2

# ─────────────────────────────────────────────────────────────
# 7️⃣ Persist only the ENABLE_DOH flag in config.sh
if [ "$CONF_DELETED" -eq 1 ]; then
  sed -i "s|^ENABLE_DOH=.*|ENABLE_DOH=$CHOICE|" "$CONFIG" \
    || abort "❌ Failed to update ENABLE_DOH in config.sh (Step 7)"
fi
if [ "$BRANCH" = "dev" ]; then
  ui_print "ℹ️ Step 7 success"
fi

# ─────────────────────────────────────────────────────────────
# 8️⃣ Download & install dnscrypt-proxy if opted-in or if DoH is enabled on FINAL_CONFIG (if config wasnt deleted)
if [ "$CONF_DELETED" -eq 1 ]; then
  if [ "$CHOICE" -eq 1 ]; then
    ui_print "🔌 DoH enabled, installing dnscrypt-proxy…"
  else
    ui_print "❌ DoH disabled, skipping dnscrypt-proxy installation."
  fi
else
  # Check if DoH is enabled in FINAL_CONFIG
  . "$FINAL_CONFIG"
  if [ "$ENABLE_DOH" -eq 1 ]; then
    CHOICE=1
    ui_print "🔌 DoH enabled, installing dnscrypt-proxy…"
  else
    ui_print "❌ DoH disabled, skipping dnscrypt-proxy installation."
  fi
fi

if [ "$CHOICE" -eq 1 ]; then
  ui_print "🔌 Checking internet connectivity…"
  curl -fsSL --head https://api.github.com >/dev/null 2>&1 \
    || abort "❌ No Internet connection. (Step 8)"

  ui_print "🌐 Fetching latest dnscrypt-proxy version…"
  VERSION=$(curl -fsSL "$API_URL" \
    | grep -o '"tag_name":[^"]*"[^\"]*"' \
    | head -n1 | cut -d\" -f4)
  [ -z "$VERSION" ] && abort "❌ Failed to fetch version. (Step 8)"

  ZIP_NAME="dnscrypt-proxy-${ARCH}-${VERSION}.zip"
  ui_print "⬇️ Downloading $ZIP_NAME"
  mkdir -p "$BIN_DIR"
  curl -fsSL -o "$BIN_ZIP" \
    "https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/${VERSION}/${ZIP_NAME}" \
    || abort "❌ Download failed. (Step 8)"

  unzip -j "$BIN_ZIP" \
    "android-${ARCH#android_}/${BIN_PATH##*/}" -d "$BIN_DIR" \
    || { rm -f "$BIN_ZIP"; abort "❌ Unzip failed. (Step 8)"; }

  [ -f "$BIN_PATH" ] || abort "❌ dnscrypt-proxy binary missing! (Step 8)"
  chmod 755 "$BIN_PATH"
  rm -f "$BIN_ZIP"
  ui_print "✅ dnscrypt-proxy $VERSION installed successfully."
fi
if [ "$BRANCH" = "dev" ]; then
  ui_print "ℹ️ Step 8 success"
fi

# ─────────────────────────────────────────────────────────────
# 9️⃣ Ensure scripts and binaries are executable
for script in "${MODDIR}/service.sh" "${MODDIR}/customize.sh"; do
  [ -f "$script" ] && chmod +x "$script" \
    || ui_print "⚠️ Could not chmod +x $script (Step 9)"
done

if [ -f "$BIN_PATH" ]; then
  chmod +x "$BIN_PATH" \
    || ui_print "⚠️ Could not chmod +x $BIN_PATH (Step 9)"
fi

if [ "$BRANCH" = "dev" ]; then
  ui_print "ℹ️ Step 9 success"
fi

# ─────────────────────────────────────────────────────────────
# 🥳 Done
ui_print ""
ui_print "✅ Configuration saved to config.sh."
ui_print "🔄 Please reboot to apply changes."
