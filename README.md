# liteDNS

> 🧠 A systemless, root-safe DNS configuration module for Android devices using KernelSU or Magisk.

**liteDNS** is a lightweight DNS setter that applies custom system DNS properties early at boot time using `resetprop`, `system.prop`, and interface-based detection.

Designed to be **clean, fast, and invisible**, it avoids background processes, overlays, and root detection issues.

---

## ✅ Features

- ⚙️ **Full support for KernelSU and Magisk**
- 📦 Uses KernelSU’s **OverlayFS** and **BusyBox** environment
- 📁 Systemless — no modifications to `/system`, `/vendor`, or `/product`
- 🧼 Clean configuration via `config.sh`
- 🚫 No background daemons, services, or overlays
- 🔒 Root-safe: no impact on SafetyNet, Play Integrity or banking apps

---

## 📥 Installation

1. Flash the module via **KernelSU Manager** or **Magisk Manager**.
2. (Optional) Customize your DNS settings by editing:

   ```bash
   /data/adb/modules/liteDNS/config.sh
   ```

3. Reboot your device. That’s it!

By default, liteDNS applies **Cloudflare DNS (1.1.1.1 / 1.0.0.1)** if no config is changed.

---

## 🔐 Root Detection Compatibility

> ✨ Works out of the box with SafetyNet, Play Integrity, and root-sensitive apps.

liteDNS only modifies **non-sensitive system properties** like:

```bash
net.dns1=1.1.1.1
net.dns2=1.0.0.1
```

It does **not**:

- Hook into Zygisk or inject native code
- Modify protected system partitions
- Change SELinux contexts or policies
- Add overlays or persistent processes
- Spoof root status or affect DenyList/App Isolation

You can verify this using tools like **Play Integrity Checker**, **RootBeer**, or your favorite banking app.

---

## 🛠️ Developer Notes

- ❌ Avoid using `setprop` in `post-fs-data.sh` with KernelSU — it can **freeze boot**.
- ✅ Use `resetprop -n` to set properties safely at early boot.
- 🔄 Always validate compatibility against the current **Magisk** and **KernelSU** versions.
- 🧪 For advanced users: customize interfaces, fallback behavior and more via `config.sh`.

---

## 🧼 Uninstallation

You can:

- Remove the module through KernelSU or Magisk Manager
- Or: create a `remove` file in the module folder:

  ```bash
  /data/adb/modules/liteDNS/remove
  ```

Then reboot. Done.

---

## 💚 Contributing / Feedback

liteDNS is a minimalistic project, but feedback, improvements, and pull requests are always welcome.

---

## 📄 License

MIT — do whatever you want, just don’t break things for others.
