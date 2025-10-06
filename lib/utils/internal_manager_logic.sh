#!/bin/bash
set -e

# --- This is an INTERNAL script called by manager.sh with sudo ---
# It handles all system-level tasks like installing services.

# (Paths are inherited from the calling manager.sh script)

# --- Core Logic Functions ---
_check_root() {
    if [ "$EUID" -ne 0 ]; then echo "❌ Error: This command must be run with sudo." >&2; exit 1; fi
}
_install_services() {
    echo "⚙️  Installing systemd services from templates..."
    [ ! -d "$SERVICES_DIR" ] && { echo "❌ Service templates directory not found." >&2; exit 1; }
    mkdir -p "$SCRIPTS_DIR/logs"
    local services_to_install=()
    for f in "$SERVICES_DIR"/*.template; do [ -e "$f" ] && services_to_install+=("$(basename "$f" .template)"); done
    for service_file in "${services_to_install[@]}"; do
        local template_path="$SERVICES_DIR/$service_file.template"
        local dest_path="$SYSTEMD_DIR/$service_file"
        sed -e "s|__SCRIPTS_DIR__|$SCRIPTS_DIR|g" -e "s|__LINK_PATH__|$LINK_PATH|g" -e "s|__FIREJAIL_PATH__|$FIREJAIL_PATH|g" "$template_path" > "$dest_path"
    done
}
_install_symlink_and_completion() {
    echo "🔗 Creating system-wide command..."
    ln -sf "$SCRIPTS_DIR/manager.sh" "$LINK_PATH"
    echo "⚙️  Installing bash autocompletion..."
    cat > "$COMPLETION_FILE_PATH" << EOF
#!/bin/bash
_liberoute_completions() {
    local cur_word prev_word; cur_word="\${COMP_WORDS[COMP_CWORD]}"; prev_word="\${COMP_WORDS[COMP_CWORD-1]}"
    if [[ \${COMP_CWORD} -eq 1 ]]; then
        local main_commands="install uninstall add select group sub update start stop restart status enable disable help version"
        COMPREPLY=( \$(compgen -W "\${main_commands}" -- \${cur_word}) ); return 0
    fi
    if [[ \${prev_word} == "group" ]]; then
        local sub_commands="list create rename delete"; COMPREPLY=( \$(compgen -W "\${sub_commands}" -- \${cur_word}) ); return 0
    fi
}
complete -F _liberoute_completions liberoute
EOF
    chmod +x "$COMPLETION_FILE_PATH"
}
_merge_env_files() {
    if [ ! -f "$ENV_DIST_FILE" ]; then echo "❌ .env.dist is missing." >&2; exit 1; fi
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
    echo "🛑 Uninstalling $PROJECT_NAME..."
    local services_to_uninstall=()
    if [ -d "$SERVICES_DIR" ]; then for f in "$SERVICES_DIR"/*.template; do [ -e "$f" ] && services_to_uninstall+=("$(basename "$f" .template)"); done; fi
    systemctl stop "${services_to_uninstall[@]}" 2>/dev/null || true
    systemctl disable "${services_to_uninstall[@]}" 2>/dev/null || true
    for service in "${services_to_uninstall[@]}"; do rm -f "$SYSTEMD_DIR/$service"; done
    rm -f "$LINK_PATH" "$COMPLETION_FILE_PATH"
    complete -r $LINK_NAME 2>/dev/null || true
    systemctl daemon-reload
    echo "✅ Uninstallation complete."
}

# --- Internal Root Command Router ---
COMMAND="$1"; shift
case "$COMMAND" in
    install)
        _check_root
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
    uninstall) _check_root; _perform_uninstall ;;
    update)
        _check_root
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
    start) _check_root; systemctl start liberoute-connection.service ;;
    stop) _check_root; systemctl stop liberoute-tunnel.service liberoute-connection.service ;;
    restart) _check_root; systemctl restart liberoute-connection.service ;;
    status) _check_root; systemctl status liberoute-*.service liberoute-*.timer ;;
    enable) _check_root; systemctl enable liberoute-*.service liberoute-*.timer; echo "✅ Services enabled."; ;;
    disable) _check_root; systemctl disable liberoute-*.service liberoute-*.timer; echo "🔕 Services disabled."; ;;
    *) echo "Error: Internal command '$COMMAND' not recognized." >&2; exit 1 ;;
esac
