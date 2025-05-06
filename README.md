# liteDNS

**liteDNS** is a minimalist, systemless DNS configuration module for rooted Android devices (Magisk or KernelSU). It applies custom DNS settings at boot—overriding only mobile‐data interfaces—and can optionally enable **DNS-over-HTTPS (DoH)** via `dnscrypt-proxy`. Built for privacy, reliability, and compatibility with root-sensitive apps.

---

## ✅ Key Features

* ⚙️ **Magisk & KernelSU compatible** (uses `resetprop -n` or `setprop` fallback)
* 🔧 **Systemless DNS override**—no writes to `/system`, `/vendor`, or `/product`
* 🔍 **Interface-aware**: applies DNS only to mobile‐data interfaces (`rmnet*`, `pdp*`, `ppp*`)
* 🌐 **Optional DoH** via auto-downloaded `dnscrypt-proxy` (latest GitHub release)
* 🌱 **IPv4 & IPv6 support**—configurable upstream servers
* 🪵 **Verbose, rotatable logs** (`litedns-service.log`, `dnscrypt.log`, `dnscrypt-fail.log`)
* 🔁 **Failsafe fallback** to standard DNS if DoH fails to start
* 🔐 No root-detection hooks, Zygisk bypass, or SELinux modifications

---

## 📦 Installation

1. **Flash** the `liteDNS.zip` installer via Magisk Manager or KernelSU manager.
2. **Interact** when prompted:

   * Overwrite existing config? (NO to keep, YES to reset)
   * Enable DoH? (YES recommended)
3. **Reboot**. The module auto‐detects CPU architecture, downloads `dnscrypt-proxy`, and configures DNS.

---

## ⚙️ Configuration

After install, edit `/data/adb/modules/liteDNS/config.sh` to tweak behavior:

```bash
# Whether to enable DNS-over-HTTPS (1=Yes, 0=No)
ENABLE_DOH=1

# Whether to apply IPv6 DNS (1=Yes, 0=No)
ENABLE_IPV6=1

# Verbose logging (1=On, 0=Off)
VERBOSE_LOG=1

# Fallback to standard DNS if DoH fails (1=Yes, 0=No)
FAILSAFE_FALLBACK=1

# Custom IPv4 DNS upstream (used if DoH disabled or fallback)
DNS1=1.1.1.1
DNS2=1.0.0.1

# Custom IPv6 DNS upstream (used if ENABLE_IPV6=1)
DNS6_1=2606:4700:4700::1111
DNS6_2=2606:4700:4700::1001
```

**Notes:**

* Editing these variables and **rebooting** is all that’s required.
* Removing `config.sh` and reflashing triggers the interactive installer again.

---

## 🧪 Logs & Debugging

* **Module log**:

  ```bash
  cat /data/adb/modules/liteDNS/litedns-service.log
  ```

* **DoH proxy stdout**:

  ```bash
  cat /data/adb/modules/liteDNS/dnscrypt.log
  ```

* **DoH proxy stderr**:

  ```bash
  cat /data/adb/modules/liteDNS/dnscrypt-fail.log
  ```

Logs rotate at each boot (`.bak` backup).

---

## 🔒 Privacy & Safety

* **No SELinux rule changes**, no system-level modifications.
* **Does not trigger** SafetyNet, Play Integrity, banking app checks, or Zygisk detection.
* **Fully systemless** via Magisk overlay or KernelSU’s OverlayFS.

---

## 🔄 Uninstallation

* **Via Magisk/KernelSU Manager**: remove module, reboot.
* **Manual**: create an empty `remove` file in `/data/adb/modules/liteDNS/` and reboot.

---

## 🛠 Advanced Considerations

* **Customizing `dnscrypt-proxy.toml`**: tweak server names, DNSSEC, logging, filters.
* **Updating `dnscrypt-proxy`**: reflashing the module installs the latest release.
* **Extending features**: you can add UI actions (`action.sh`) or watchdog scripts for `dnscrypt-proxy`.

---

## 📜 License & Credits

* **liteDNS** is licensed under the GPLv3.
* `dnscrypt-proxy` is maintained by [jedisct1](https://github.com/jedisct1/dnscrypt-proxy) under the ISC license.
