#!/bin/bash
set -e

# This script checks for required system dependencies and reports what's missing.

# Array of commands that Liberoute requires
REQUIRED_COMMANDS=("jq" "curl" "firejail" "ipset" "iptables" "danted" "privoxy" "ip6tables" "sing-box" "xray" "v2ray")
MISSING_PACKAGES=() # To suggest installation commands

# Don't echo anything here except the final list of missing packages
# so the parent script can capture it.

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        # Suggest packages for Debian-based systems
        case "$cmd" in
            jq) MISSING_PACKAGES+=("jq") ;;
            curl) MISSING_PACKAGES+=("curl") ;;
            firejail) MISSING_PACKAGES+=("firejail") ;;
            ipset) MISSING_PACKAGES+=("ipset") ;;
            iptables) MISSING_PACKAGES+=("iptables") ;;
            ip6tables) MISSING_PACKAGES+=("iptables") ;;
            danted) MISSING_PACKAGES+=("dante-server") ;; # Package name is dante-server
            privoxy) MISSING_PACKAGES+=("privoxy") ;;
            sing-box) MISSING_PACKAGES+=("(manual install needed for sing-box)") ;;
        esac
    fi
done

if [ ${#MISSING_PACKAGES[@]} -ne 0 ]; then
    # Print a unique, space-separated list of packages to stdout
    # This will be captured by the parent script.
    echo "${MISSING_PACKAGES[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '
    exit 10 # Use a special exit code to indicate missing dependencies
fi

exit 0 # All dependencies are present

