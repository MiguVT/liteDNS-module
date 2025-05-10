# liteDNS

**liteDNS** is a minimalist, systemless DNS configuration module for rooted Android devices (Magisk or KernelSU). It applies custom DNS settings at boot—overriding only mobile‐data interfaces—and can optionally enable **DNS-over-HTTPS (DoH)** via `dnscrypt-proxy`. Built for privacy, reliability, and compatibility with root-sensitive apps.

---

## ✅ Key Features

* ⚙️ **Magisk & KernelSU compatible** (uses `iptables` for DNS redirection, that is present in all Android kernels)
* 🔧 **Systemless DNS override**—no writes to `/system`, `/vendor`, or `/product`
* 🔍 **Interface-aware**: applies DNS only to mobile‐data interfaces (`rmnet*`, `pdp*`, `ppp*`)
* 🌐 **Optional DoH** via auto-downloaded `dnscrypt-proxy` (latest GitHub release)
* 🌱 **IPv4 & IPv6 support**—configurable upstream servers
* 🪵 **Verbose, rotatable logs** (`litedns-service.log`, `dnscrypt.log`, `dnscrypt-fail.log`)
* 🔁 **Failsafe fallback** to standard DNS if DoH fails to start
* 🔐 No root-detection hooks, Zygisk bypass, or SELinux modifications

---

## 📦 Installation

1. Flash `liteDNS.zip` via Magisk or KernelSU Manager.
2. First-time run will copy `config.sh.template` → `config.sh` and prompt:
   * Overwrite existing config? (NO to keep, YES to reset)
   * Enable DoH? (YES recommended)
3. Reboot.

---

## ⚙️ Configuration

After install, edit `/data/adb/modules/liteDNS/config.sh` to tweak behavior. Everything is commented for clarity.

**Notes:**

* Editing the file and **rebooting** is all that’s required.
* Reflashing give you the option to launch the interactive config wizard again.

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

Logs rotate at each boot.

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
