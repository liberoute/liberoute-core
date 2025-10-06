#!/bin/bash

echo "🧹 Uninstalling Liberoute..."

systemctl stop liberoute-connection.service 2>/dev/null
systemctl stop liberoute-tunnel.service 2>/dev/null
systemctl disable liberoute-connection.service 2>/dev/null
systemctl disable liberoute-tunnel.service 2>/dev/null
rm -f /etc/systemd/system/liberoute-*.service
rm -f /etc/systemd/system/liberoute-*.timer
systemctl daemon-reexec
systemctl daemon-reload

echo "🗑 Removing logs and config..."
rm -rf logs/*
rm -f .last_selected_link
rm -rf data/profiles/*

echo "✅ Liberoute has been removed."
