#!/bin/bash
set -e

# --- This is an INTERNAL script called by manager.sh with sudo ---
# It handles all system-level tasks like installing services.

# --- Setup ---
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$( cd -P "$( dirname "$SOURCE" )" &>/dev/null && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPTS_DIR="$( cd -P "$( dirname "$SOURCE" )" &>/dev/null && pwd )"

# Define paths
ENV_FILE="$SCRIPTS_DIR/.env"
ENV_DIST_FILE="$SCRIPTS_DIR/.env.dist"
LIB_DIR="$SCRIPTS_DIR/lib"
SERVICES_DIR="$SCRIPTS_DIR/services"
SYSTEMD_DIR="/etc/systemd/system"
FIREJAIL_PATH="/usr/local/bin/firejail"
LINK_PATH="/usr/local/bin/liberoute"
COMPLETION_FILE_PATH="/etc/bash_completion.d/liberoute-completion.sh"

# Dynamically build service list
SERVICES=()
if [ -d "$SERVICES_DIR" ]; then
    for f in "$SERVICES_DIR"/*.template; do
        [ -e "$f" ] && SERVICES+=("$(basename "$f" .template)")
    done
fi

# --- Core Logic (Copied from previous manager.sh) ---
# ... (All _install_services, _install_symlink, etc. functions go here) ...
_install_services() {
    echo "⚙️  Installing systemd services from templates..."
    if [ ${#SERVICES[@]} -eq 0 ]; then echo "❌ No service templates found." >&2; exit 1; fi
    mkdir -p "$SCRIPTS_DIR/logs"
    for service_file in "${SERVICES[@]}"; do
        local template_path="$SERVICES_DIR/$service_file.template"
        local dest_path="$SYSTEMD_DIR/$service_file"
        echo "  -> Processing $service_file..."
        sed -e "s|__SCRIPTS_DIR__|$SCRIPTS_DIR|g" \
            -e "s|__LINK_PATH__|$LINK_PATH|g" \
            -e "s|__FIREJAIL_PATH__|$FIREJAIL_PATH|g" \
            "$template_path" > "$dest_path"
    done
}
_install_symlink_and_completion() {
    echo "🔗 Creating system-wide command..."
    ln -sf "$SCRIPTS_DIR/manager.sh" "$LINK_PATH"
    echo "   -> Linked $LINK_PATH to manager.sh"
    echo "⚙️  Installing bash autocompletion..."
    cat > "$COMPLETION_FILE_PATH" << EOF
#!/bin/bash
_liberoute_completions() {
    local cur_word prev_word
    cur_word="\${COMP_WORDS[COMP_CWORD]}"
    prev_word="\${COMP_WORDS[COMP_CWORD-1]}"

    if [[ \${COMP_CWORD} -eq 1 ]]; then
        local main_commands="install uninstall add select group sub update start stop restart status enable disable help version"
        COMPREPLY=( \$(compgen -W "\${main_commands}" -- \${cur_word}) )
        return 0
    fi
    if [[ \${prev_word} == "group" ]]; then
        local sub_commands="list create rename delete"
        COMPREPLY=( \$(compgen -W "\${sub_commands}" -- \${cur_word}) )
        return 0
    fi
}
complete -F _liberoute_completions liberoute
EOF
    chmod +x "$COMPLETION_FILE_PATH"
}
_merge_env_files() {
    echo "🔎 Checking for configuration updates..."
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^([a-zA-Z_]+)=.*$ ]]; then
            local var_name="${BASH_REMATCH[1]}"
            if ! grep -q -E "^${var_name}=" "$ENV_FILE"; then
                echo "  -> Adding new variable '$var_name' to .env"
                echo "" >> "$ENV_FILE"; echo "$line" >> "$ENV_FILE"
            fi
        fi
    done < "$ENV_DIST_FILE"
    echo "✅ .env check complete."
}
_perform_uninstall() {
    echo "🛑 Stopping all services..."
    systemctl stop "${SERVICES[@]}" 2>/dev/null || true
    echo "🧹 Disabling all services..."
    systemctl disable "${SERVICES[@]}" 2>/dev/null || true
    echo "🗑️  Removing systemd files..."
    for service in "${SERVICES[@]}"; do rm -f "$SYSTEMD_DIR/$service"; done
    echo "🗑️  Removing system-wide command..."
    rm -f "$LINK_PATH"
    if [ -f "$COMPLETION_FILE_PATH" ]; then
        echo "🗑️  Removing bash autocompletion..."
        rm -f "$COMPLETION_FILE_PATH"
        complete -r liberoute 2>/dev/null || true
    fi
    systemctl daemon-reload
    echo "✅ Uninstallation complete."
}

# --- Internal Command Router ---
COMMAND="$1"
shift || true
case "$COMMAND" in
    install)
        echo "🚀 Starting $PROJECT_NAME installation..."
        if [ ! -f "$ENV_FILE" ]; then
            echo "  -> No .env file found. Creating one..."
            cp "$ENV_DIST_FILE" "$ENV_FILE"
        fi
        echo "🔧 Verifying configuration paths..."
        sed -i "s|__ABSOLUTE_PATH_TO_SCRIPTS__|$SCRIPTS_DIR|g" "$ENV_FILE"
        _merge_env_files
        bash "$LIB_DIR/system/asset_downloader.sh"
        _install_services
        _install_symlink_and_completion
        systemctl daemon-reload
        echo "✅ Installation complete. Run 'sudo liberoute enable' to enable services."
        ;;
    uninstall) _perform_uninstall ;;
    update)
        echo "🔄 Starting full update..."
        sed -i "s|__ABSOLUTE_PATH_TO_SCRIPTS__|$SCRIPTS_DIR|g" "$ENV_FILE"
        _merge_env_files
        _install_services
        _install_symlink_and_completion
        systemctl daemon-reload
        echo "--- Updating data assets ---"
        bash "$LIB_DIR/system/asset_downloader.sh" --force
        bash "$LIB_DIR/system/whitelist_fetch.sh"
        echo "✅ Update complete. Run 'sudo liberoute restart' to apply all changes."
        ;;
    start) systemctl start liberoute-connection.service ;;
    stop) systemctl stop liberoute-tunnel.service liberoute-connection.service ;;
    restart) systemctl restart liberoute-connection.service ;;
    status)
        echo "📊 Checking $PROJECT_NAME service status..."
        for service in "${SERVICES[@]}"; do
            if [ -f "$SYSTEMD_DIR/$service" ]; then
                if systemctl is-active --quiet "$service"; then echo "  -> $service: active"; else echo "  -> $service: inactive"; fi
            fi
        done
        ;;
    enable)
        systemctl enable liberoute-connection.service liberoute-tunnel.service liberoute-health-check.timer liberoute-log-cleaner.timer liberoute-geo-update.timer
        echo "✅ Services enabled to start on boot."
        ;;
    disable)
        systemctl disable liberoute-connection.service liberoute-tunnel.service liberoute-health-check.timer liberoute-log-cleaner.timer liberoute-geo-update.timer
        echo "🔕 Services disabled."
        ;;
    *) echo "Error: Internal command '$COMMAND' not recognized." >&2; exit 1 ;;
esac
