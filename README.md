# Liberoute

Liberoute is a secure and modular routing system for Linux that enables selective proxying and transparent tunneling via `sing-box`, `firejail`, and `iptables`.

### ✨ Features

- Auto-detect and route traffic through proxy
- Health check and failover support
- Profile & group management (vmess/vless/etc.)
- Iran-aware time sync and proxy fallback
- CLI management with Bash auto-completion
- Fully systemd-based service lifecycle
- GeoIP and whitelist updates with SOCKS5 fallback

### 🔧 Quick Start

```bash
# Run setup wizard
bash lib/setup/setup_wizard.sh
```

```bash
# Or use liberoute CLI
./manager.sh install
./manager.sh start
```

### 📁 Folder Structure

```
lib/
├── core/         # Startup logic
├── profile/      # Profiles, groups, links
├── system/       # Health, network, geoip
├── utils/        # Dependency checks
└── setup/        # Installer, uninstall, completion
```

---

### 📚 Documentation

- `.env.dist` contains all configurable values
- `services/` contains systemd unit templates
- Uses `firejail`, `sing-box`, `privoxy`, `danted`

---

### 💬 License

MIT — see [LICENSE](LICENSE)

