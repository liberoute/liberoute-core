#!/bin/bash
set -e

# --- Configuration ---
VERSION="1.6.9" # Unified script, fixed all dispatch and 'local' variable bugs
PROJECT_NAME="Liberoute"
LINK_NAME="liberoute"

# --- Setup ---
# Get the absolute path of the script's directory, resolving any symlinks.
SCRIPTS_DIR=$(dirname "$(readlink -f "$0")")

# Define paths
ENV_FILE="$SCRIPTS_DIR/.env"
ENV_DIST_FILE="$SCRIPTS_DIR/.env.dist"
LIB_DIR="$SCRIPTS_DIR/lib"
SERVICES_DIR="$SCRIPTS_DIR/services"
SYSTEMD_DIR="/etc/systemd/system"
FIREJAIL_PATH="/usr/local/bin/firejail"
LINK_PATH="/usr/local/bin/$LINK_NAME"
COMPLETION_FILE_NAME="liberoute-completion.sh"
COMPLETION_FILE_PATH="/etc/bash_completion.d/$COMPLETION_FILE_NAME"

# --- Help Text ---
show_help() {
    echo "$PROJECT_NAME - Service Manager - Version $VERSION"
    echo
    echo "Usage: $LINK_NAME <command> [options] [arguments]"
    echo "       (use 'sudo' for commands that require root privileges)"
    echo
    echo "Profile & Link Management:"
    echo "  add [-g GROUP] <link>            Add a basic vmess/vless link."
    echo "  select [-g GROUP]                Interactively select the active link for connection."
    echo "  link list [-g GROUP]             List links in a group, marking the active one."
    echo "  link active [-g GROUP] -n REMARK Set a link as the active connection by its name."
    echo "  link delete [-g GROUP] [-n REMARK] Delete a link by its name or interactively."
    echo
    echo "Group Management:"
    echo "  group list                       List all available profile groups."
    echo "  group active <GROUP>             Set the active profile group."
    echo "  group create [-t TYPE] NAME      Create a new group ('basic' or 'subscription')."
    echo "  group rename <OLD> <NEW>         Rename a group."
    echo "  group delete <GROUP>             Delete a group."
    echo
    echo "Subscription Management:"
    echo "  sub add [-g GROUP] <url>         Add a subscription URL to a group."
    echo "  sub update [GROUP]               Update links from subscriptions."
    echo
    echo "Lifecycle & Service Control (requires sudo):"
    echo "  install                  Install or repair the Liberoute system."
    echo "  uninstall                Remove all Liberoute components from the system."
    echo "  update                   Update service definitions and data assets."
    echo "  start, stop, restart     Control the Liberoute services."
    echo "  status                   View the status of all Liberoute services."
    echo "  enable, disable          Control services starting on boot."
    echo
}
show_version() {
    echo "$PROJECT_NAME Manager version $VERSION"
}

# --- Internal Core Logic ---
_check_root() {
    if [ "$EUID" -ne 0 ]; then
      echo "❌ Error: This command must be run with sudo."
      exit 1
    fi
}

_handle_dependencies() {
    _check_root
    echo "🔍 Checking for required system dependencies..."

    local missing_packages
    missing_packages=$(bash "$LIB_DIR/utils/dependency_checker.sh" 2>/dev/null || true)

    if [ -n "$missing_packages" ]; then
        echo
        echo "⚠️  The following dependencies are missing: $missing_packages"
        read -p "Do you want to try and install them now? (y/N) " -n 1 -r; echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "🔧 Attempting to install missing packages via apt-get..."
            if command -v apt-get &> /dev/null; then
                apt-get update
                # shellcheck disable=SC2155
                # shellcheck disable=SC2001
                local packages_to_install=$(echo "$missing_packages" | sed 's/(manual install needed for sing-box)//g')
                apt-get install -y "$packages_to_install"
                echo "Re-checking dependencies..."
                if ! bash "$LIB_DIR/utils/dependency_checker.sh" >/dev/null 2>&1; then
                    echo "❌ Some dependencies could still not be installed. Please install them manually." >&2; exit 1
                fi
            else
                echo "❌ 'apt-get' not found. Please install dependencies manually." >&2; exit 1
            fi
        else
            echo "Aborted. Please install dependencies manually." >&2; exit 1
        fi
    fi
    echo "✅ All dependencies are satisfied."

    # shellcheck disable=SC2155

    local iptables_path=$(command -v iptables); local ip6tables_path=$(command -v ip6tables)
    if [ -f "$ENV_FILE" ]; then
        sed -i -e "s|^IPTABLES=.*|IPTABLES=$iptables_path|" -e "s|^IP6TABLES=.*|IP6TABLES=$ip6tables_path|" "$ENV_FILE"
    fi
}

_enable_sysctl_forwarding() {
    echo "🌐 Ensuring system-wide IP forwarding is enabled..."

    SYSCTL_CONF="/etc/sysctl.conf"
    FORWARD_IPV4="net.ipv4.ip_forward=1"
    FORWARD_IPV6="net.ipv6.conf.all.forwarding=1"

    # Append if not present
    grep -qF "$FORWARD_IPV4" "$SYSCTL_CONF" || echo "$FORWARD_IPV4" | sudo tee -a "$SYSCTL_CONF" >/dev/null
    grep -qF "$FORWARD_IPV6" "$SYSCTL_CONF" || echo "$FORWARD_IPV6" | sudo tee -a "$SYSCTL_CONF" >/dev/null

    # Apply settings
    sudo sysctl --system
}


_install_services() {
    _check_root
    echo "⚙️  Installing systemd services from templates..."
    [ ! -d "$SERVICES_DIR" ] && { echo "❌ Service templates directory not found." >&2; exit 1; }
    mkdir -p "$SCRIPTS_DIR/logs"
    local services_to_install=(); for f in "$SERVICES_DIR"/*.template; do [ -e "$f" ] && services_to_install+=("$(basename "$f" .template)"); done
    for service_file in "${services_to_install[@]}"; do
        sed -e "s|__SCRIPTS_DIR__|$SCRIPTS_DIR|g" -e "s|__LINK_PATH__|$LINK_PATH|g" -e "s|__FIREJAIL_PATH__|$FIREJAIL_PATH|g" "$SERVICES_DIR/$service_file.template" > "$SYSTEMD_DIR/$service_file"
    done
}

_install_symlink_and_completion() {
    _check_root
    echo "🔗 Creating system-wide command..."
    ln -sf "$SCRIPTS_DIR/manager.sh" "$LINK_PATH"
    echo "⚙️  Installing bash autocompletion..."
    cat > "$COMPLETION_FILE_PATH" << EOF
#!/bin/bash
_liberoute_completions() {
    local cur_word prev_word; cur_word="\${COMP_WORDS[COMP_CWORD]}"; prev_word="\${COMP_WORDS[COMP_CWORD-1]}"
    if [[ \${COMP_CWORD} -eq 1 ]]; then
        local main_commands="install uninstall add select link group sub update start stop restart status enable disable help version"
        COMPREPLY=( \$(compgen -W "\${main_commands}" -- \${cur_word}) ); return 0
    fi
}
complete -F _liberoute_completions liberoute
EOF
    chmod +x "$COMPLETION_FILE_PATH"
}

_merge_env_files() {
    _check_root
    if [ ! -f "$ENV_DIST_FILE" ]; then echo "❌ ERROR: Default configuration file '.env.dist' is missing." >&2; exit 1; fi
    echo "🔎 Checking for configuration updates in .env..."
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^([a-zA-Z_]+)=.*$ ]]; then
            local var_name="${BASH_REMATCH[1]}"
            if ! grep -q -E "^${var_name}=" "$ENV_FILE" 2>/dev/null; then
                echo "  -> Adding new variable '$var_name' to .env"
                echo "" >> "$ENV_FILE"; echo "# Added from .env.dist" >> "$ENV_FILE"; echo "$line" >> "$ENV_FILE"
            fi
        fi
    done < "$ENV_DIST_FILE"
}

_perform_uninstall() {
    _check_root
    local services_to_uninstall=(); if [ -d "$SERVICES_DIR" ]; then for f in "$SERVICES_DIR"/*.template; do [ -e "$f" ] && services_to_uninstall+=("$(basename "$f" .template)"); done; fi
    if [ ${#services_to_uninstall[@]} -eq 0 ] && [ ! -L "$LINK_PATH" ]; then echo "🤔 Liberoute does not appear to be installed."; exit 0; fi
    read -p "❓ Are you sure you want to permanently uninstall Liberoute? (y/N) " -n 1 -r; echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then echo "Aborted."; exit 0; fi

    echo "🗑️  Uninstalling..."; systemctl stop "${services_to_uninstall[@]}" 2>/dev/null || true
    systemctl disable "${services_to_uninstall[@]}" 2>/dev/null || true
    for service in "${services_to_uninstall[@]}"; do rm -f "$SYSTEMD_DIR/$service"; done
    rm -f "$LINK_PATH"; if [ -f "$COMPLETION_FILE_PATH" ]; then rm -f "$COMPLETION_FILE_PATH"; complete -r $LINK_NAME 2>/dev/null || true; fi
    systemctl daemon-reload; echo "✅ Uninstallation complete."
}

_perform_enable() {
    _check_root
    echo "🔔 Enabling Liberoute services...";
    local services_to_enable=(); if [ -d "$SERVICES_DIR" ]; then for f in "$SERVICES_DIR"/*.template; do [ -e "$f" ] && services_to_enable+=("$(basename "$f" .template)"); done; fi
    systemctl enable "${services_to_enable[@]}"; echo "✅ Services enabled."
}

_perform_disable() {
    _check_root
    echo "🔕 Disabling Liberoute services...";
    local services_to_disable=(); if [ -d "$SERVICES_DIR" ]; then for f in "$SERVICES_DIR"/*.template; do [ -e "$f" ] && services_to_disable+=("$(basename "$f" .template)"); done; fi
    systemctl disable "${services_to_disable[@]}"; echo "✅ Services disabled."
}

# --- Main Command Handler Functions ---
handle_link_command() {
    local SUB_COMMAND="$1"; shift || true;
    # shellcheck disable=SC1090
    [ -f "$ENV_FILE" ] && source "$ENV_FILE"
    local GROUP="${ACTIVE_GROUP:-default}"; local REMARK=""

    OPTIND=1
    while getopts ":g:n:" opt; do
        case $opt in g) GROUP="$OPTARG" ;; n) REMARK="$OPTARG" ;; \?) echo "Invalid option: -$OPTARG" >&2; exit 1;; esac
    done; shift $((OPTIND -1))

    case "$SUB_COMMAND" in
        list) bash "$LIB_DIR/profile/profile_manager.sh" list_links_in_group "$GROUP" ;;
        delete)
            if [ -n "$REMARK" ]; then bash "$LIB_DIR/profile/profile_manager.sh" delete_link_by_remark "$GROUP" "$REMARK"; else bash "$LIB_DIR/link_deleter.sh" "$GROUP"; fi
            ;;
        active)
            [ -z "$REMARK" ] && { echo "Error: Missing link remark. Use -n <remark>." >&2; exit 1; }
            local link_to_activate; link_to_activate=$(bash "$LIB_DIR/profile/profile_manager.sh" get_link_by_remark "$GROUP" "$REMARK")
            if [ -z "$link_to_activate" ]; then echo "Error: Link '$REMARK' not found in group '$GROUP'." >&2; exit 1; fi
            local last_link_file_path="$SCRIPTS_DIR/data/.last_selected_link"
            mkdir -p "$(dirname "$last_link_file_path")"; echo "$link_to_activate" > "$last_link_file_path"
            sed -i "s/^ACTIVE_GROUP=.*/ACTIVE_GROUP=$GROUP/" "$ENV_FILE"; echo "✅ Active link set to '$REMARK' in group '$GROUP'."; echo "💡 Run 'sudo liberoute restart' to connect."
            ;;
        *) echo "Error: Unknown 'link' command '$SUB_COMMAND'." >&2; show_help; exit 1 ;;
    esac
}

# --- Main Command Router ---
COMMAND="$1"
if [ -z "$COMMAND" ]; then show_help; exit 0; fi
shift

case "$COMMAND" in
    add)
        # shellcheck disable=SC1090
        [ -f "$ENV_FILE" ] && source "$ENV_FILE"
        # shellcheck disable=SC2220
        GROUP="default"; while getopts ":g:" opt; do case $opt in g) GROUP="$OPTARG" ;; esac; done; shift $((OPTIND -1))
        LINK="$1"; [ -z "$LINK" ] && { echo "Error: Missing link." >&2; exit 1; }
        bash "$LIB_DIR/profile/profile_manager.sh" add_link "$GROUP" "$LINK"
        ;;
    sub)
        # shellcheck disable=SC1090
        [ -f "$ENV_FILE" ] && source "$ENV_FILE"
        # shellcheck disable=SC2220
        SUB_COMMAND="$1"; shift || true; GROUP="default"; while getopts ":g:" opt; do case $opt in g) GROUP="$OPTARG" ;; esac; done; shift $((OPTIND -1))
        case "$SUB_COMMAND" in
            add) URL="$1"; [ -z "$URL" ] && { echo "Error: Missing URL." >&2; exit 1; }; bash "$LIB_DIR/profile/profile_manager.sh" add_sub "$GROUP" "$URL" ;;
            update) [ -n "$1" ] && GROUP="$1"; bash "$LIB_DIR/profile/profile_manager.sh" update_sub "$GROUP" ;;
            *) echo "Error: Unknown 'sub' command." >&2; exit 1 ;;
        esac
        ;;
    group)
        # shellcheck disable=SC1090
        [ -f "$ENV_FILE" ] && source "$ENV_FILE"
        SUB_COMMAND="$1"; shift || true
        case "$SUB_COMMAND" in
            create)
                # shellcheck disable=SC2220
                TYPE="basic"; while getopts ":t:" opt; do case $opt in t) TYPE="$OPTARG" ;; esac; done; shift $((OPTIND-1));
                GROUP_NAME="$1"; [ -z "$GROUP_NAME" ] && { echo "Error: Missing group name." >&2; exit 1; }; bash "$LIB_DIR/profile/profile_manager.sh" create_group "$GROUP_NAME" "$TYPE"
                ;;
            rename) OLD="$1"; NEW="$2"; [ -z "$OLD" ] || [ -z "$NEW" ] && { echo "Error: Missing arguments." >&2; exit 1; }; bash "$LIB_DIR/profile/profile_manager.sh" rename_group "$OLD" "$NEW" ;;
            delete) GROUP_NAME="$1"; [ -z "$GROUP_NAME" ] && { echo "Error: Missing group name." >&2; exit 1; }; bash "$LIB_DIR/profile/profile_manager.sh" delete_group "$GROUP_NAME" ;;
            list) bash "$LIB_DIR/profile/profile_manager.sh" list_groups ;;
            active)
                GROUP_TO_ACTIVATE="$1"; [ -z "$GROUP_TO_ACTIVATE" ] && { echo "Error: Missing group name." >&2; exit 1; }
                if [ ! -d "$PROFILES_DIR/$GROUP_TO_ACTIVATE" ]; then echo "Error: Group '$GROUP_TO_ACTIVATE' does not exist." >&2; exit 1; fi
                sed -i "s/^ACTIVE_GROUP=.*/ACTIVE_GROUP=$GROUP_TO_ACTIVATE/" "$ENV_FILE"; echo "✅ Active group set to '$GROUP_TO_ACTIVATE'."
                ;;
            *) echo "Error: Unknown 'group' command." >&2; exit 1 ;;
        esac
        ;;
    link)
        handle_link_command "$@"
        ;;
    select)
        [ -f "$ENV_FILE" ] && source "$ENV_FILE"
        GROUP="${ACTIVE_GROUP:-default}"; while getopts ":g:" opt; do case $opt in g) GROUP="$OPTARG" ;; esac; done; shift $((OPTIND -1));
        [ -n "$1" ] && GROUP="$1"
        bash "$LIB_DIR/profile/link_selector.sh" "$GROUP"
        ;;
    install)
        _check_root
        echo "🚀 Starting $PROJECT_NAME installation..."
        if [ ! -f "$ENV_DIST_FILE" ]; then echo "❌ CRITICAL: '.env.dist' template file is missing." >&2; exit 1; fi
        if [ ! -f "$ENV_FILE" ]; then
            echo "  -> No .env file found. Creating one from template..."
            cp "$ENV_DIST_FILE" "$ENV_FILE"
        fi
        echo "🔧 Verifying configuration paths..."
        sed -i "s|__ABSOLUTE_PATH_TO_SCRIPTS__|$SCRIPTS_DIR|g" "$ENV_FILE"
        _merge_env_files
        _handle_dependencies
	_enable_sysctl_forwarding
        bash "$LIB_DIR/system/asset_downloader.sh"
        _install_services
        _install_symlink_and_completion
        systemctl daemon-reload
        echo "✅ Installation complete. Run 'sudo $LINK_NAME enable' to enable services."
        ;;
    uninstall)
        _perform_uninstall
        ;;
    update)
        _check_root
        echo "🔄 Starting full update..."
        sed -i "s|__ABSOLUTE_PATH_TO_SCRIPTS__|$SCRIPTS_DIR|g" "$ENV_FILE"
        _merge_env_files
        _handle_dependencies
        _install_services
        _install_symlink_and_completion
        systemctl daemon-reload
        echo "--- Updating data assets ---"
        bash "$LIB_DIR/system/asset_downloader.sh" --force
        bash "$LIB_DIR/system/whitelist_fetch.sh"
        echo "✅ Update complete."
        ;;
    start) _check_root; echo "🚀 Starting Liberoute..."; systemctl start liberoute-connection.service liberoute-tunnel.service ;;
    stop) _check_root; echo "🛑 Stopping Liberoute..."; systemctl stop liberoute-tunnel.service liberoute-connection.service ;;
    restart) _check_root; echo "🔄 Restarting Liberoute..."; systemctl restart liberoute-connection.service ;;
    status) _check_root; systemctl status liberoute-*.service liberoute-*.timer ;;
    enable)
        _perform_enable
        ;;
    disable)
        _perform_disable
        ;;
    -h|--help|help) show_help ;;
    -v|--version|version) show_version ;;
    *) echo "Error: Unknown command '$COMMAND'" >&2; show_help; exit 1 ;;
esac
