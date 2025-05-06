# liteDNS

**liteDNS** is a lightweight DNS configuration module for rooted Android devices using either **KernelSU** or **Magisk**.  
It applies custom DNS settings during early boot using `resetprop`, `system.prop`, and interface detection.

## ✅ Features

- Fully compatible with both Magisk and KernelSU environments
- Compatible with KernelSU’s OverlayFS and BusyBox environment
- Systemless DNS configuration (no /system writes)
- Safe `post-fs-data` application with fallback
- Clean configuration via `config.sh`
- No background daemons or runtime overhead

## 🔧 Installation

1. Flash via KernelSU or Magisk Manager.  
   You're done if you want to use Cloudflare DNS by default.
2. To customize, edit `/data/adb/modules/liteDNS/config.sh`.
3. Reboot your device.

## 🔐 Security & Root Detection

`liteDNS` is designed to be fully compatible with root-sensitive apps and does **not trigger detection mechanisms** such as SafetyNet, Play Integrity, or banking app checks.

It strictly modifies **non-sensitive system properties** (`net.dns1`, `net.dns2`, etc.) in a systemless manner and does **not**:

- Hook into Zygisk or inject native code
- Modify or replace files in `/system`, `/vendor`, or `/product`
- Change SELinux contexts or policies
- Include background services, binaries, or overlays
- Spoof root status or interfere with detection frameworks

As a result, `liteDNS` poses **no risk to root concealment** when used alongside Magisk’s DenyList or KernelSU’s app isolation features.

You can verify its safety using tools like **Play Integrity Checker**, **RootBeer**, or directly with sensitive apps.

## ⚠️ Notes for Developers

- Do **not** use `setprop` in `post-fs-data.sh` under KernelSU – it may freeze boot.
- Always use `resetprop -n` in early boot stages.
- Always verify compatibility with the current versions of KernelSU and Magisk during development.

## 🔄 Uninstall

Remove the module via your root manager, or create a `remove` file inside the module folder and reboot.
