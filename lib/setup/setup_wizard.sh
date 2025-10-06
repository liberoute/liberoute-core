#!/bin/bash

echo "🔧 Welcome to Liberoute Setup Wizard"

while true; do
  echo ""
  echo "1) Automatic install"
  echo "2) Manual install (customize .env)"
  echo "3) Uninstall Liberoute"
  echo "4) Exit"
  read -rp "> Choose an option [1-4]: " choice

  case "$choice" in
    1)
      echo "📦 Running automatic install..."
      bash lib/utils/dependency_checker.sh
      sudo bash manager.sh enable
      sudo bash manager.sh start
      echo "✅ Installed and started Liberoute"
      ;;
    2)
      echo "⚙️ Manual config:"
      read -rp "Enter SOCKS5 port [1080]: " port
      port=${port:-1080}
      read -rp "Enter whitelist countries (comma-separated, e.g. ir,us): " wl
      wl=${wl:-}
      sed -i "s/^INBOUNDS=.*/INBOUNDS='[{"listen_port":$port}]'/" .env
      sed -i "s/^WHITELIST_COUNTRIES=.*/WHITELIST_COUNTRIES=$wl/" .env
      echo "✅ Updated .env with port $port and whitelist '$wl'"
      sudo bash manager.sh enable
      sudo bash manager.sh start
      ;;
    3)
      bash lib/setup/uninstall.sh
      ;;
    4)
      echo "👋 Exiting setup wizard."
      exit 0
      ;;
    *)
      echo "❌ Invalid option"
      ;;
  esac
done
