#!/bin/bash
set -e

# Manages profile groups (basic/subscription) and their associated files.

# --- Setup ---
# Get the absolute path of this script's directory
SCRIPT_DIR_HELPER=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# The project root is one level up from the lib/ directory
PROJECT_ROOT="$SCRIPT_DIR_HELPER/../.."
ENV_PATH="$PROJECT_ROOT/.env"

if [ ! -f "$ENV_PATH" ]; then
    echo "❌ ERROR: .env file not found at '$ENV_PATH'." >&2
    exit 1
fi
# Load the environment variables to get configuration
source "$ENV_PATH"

# --- Internal Functions ---
_get_group_type() {
    local group_name="$1"; local type_file="$PROFILES_DIR/$group_name/.type"
    if [ -f "$type_file" ]; then cat "$type_file"; else echo "none"; fi
}
_create_group_internal() {
    local group_name="$1"; local group_type="${2:-basic}"; local group_dir="$PROFILES_DIR/$group_name"
    if [ -d "$group_dir" ]; then return; fi
    mkdir -p "$group_dir"; echo "$group_type" > "$group_dir/.type"
    if [ "$group_type" == "basic" ]; then echo "{}" > "$group_dir/links.json"; fi
}
_get_remark_from_link() {
    local link="$1"; local remark=""
    remark=$(echo "$link" | sed -n 's/.*#\(.*\)/\1/p' | sed 's/[^a-zA-Z0-9._-]/_/g')
    if [ -z "$remark" ]; then
        local base64_payload=$(echo "$link" | sed -E 's/^(vmess|vless):\/\///')
        local decoded_json=$(echo "$base64_payload" | tr -d '\n\r' | base64 --decode 2>/dev/null || echo "")
        if [ -n "$decoded_json" ]; then
            remark=$(echo "$decoded_json" | jq -r '.ps // ""' | sed 's/[^a-zA-Z0-9._-]/_/g')
        fi
    fi
    [ -z "$remark" ] && remark="link-$(date +%s)"; echo "$remark"
}

# --- Exposed Functions ---
create_group() {
    local group_name="$1"; local group_type="$2"; local group_dir="$PROFILES_DIR/$group_name"
    if [ -d "$group_dir" ]; then echo "❌ Error: Group '$group_name' already exists." >&2; exit 1; fi
    _create_group_internal "$group_name" "$group_type"; echo "✅ Group '$group_name' (type: $group_type) created successfully."
}
add_link() {
    local group_name="$1"; local link="$2"; local group_type=$(_get_group_type "$group_name")
    if [ "$group_type" == "subscription" ]; then echo "❌ Error: Cannot add a basic link to a 'subscription' group." >&2; exit 1; fi
    if [ "$group_type" == "none" ]; then _create_group_internal "$group_name" "basic"; fi
    local links_file="$PROFILES_DIR/$group_name/links.json"; local remark=$(_get_remark_from_link "$link")
    local temp_json=$(mktemp); jq --arg key "$remark" --arg value "$link" '.[$key] = $value' "$links_file" > "$temp_json"
    mv "$temp_json" "$links_file"; echo "✅ Link '$remark' saved to group '$group_name'."
}
add_sub() {
    local group_name="$1"; local url="$2"; local group_type=$(_get_group_type "$group_name")
    if [ "$group_type" == "basic" ]; then echo "❌ Error: Cannot add a subscription to a 'basic' group." >&2; exit 1; fi
    if [ "$group_type" == "none" ]; then _create_group_internal "$group_name" "subscription"; fi
    local subs_file="$PROFILES_DIR/$group_name/subscriptions.txt"
    if ! grep -qF "$url" "$subs_file" 2>/dev/null; then echo "$url" >> "$subs_file"; echo "✅ Subscription URL added."; else echo "🤔 Subscription URL already exists."; fi
}
update_sub() {
    local group_name="$1"; local group_type=$(_get_group_type "$group_name")
    if [ "$group_type" != "subscription" ]; then echo "❌ Error: Group '$group_name' is not a subscription group." >&2; exit 1; fi
    local group_dir="$PROFILES_DIR/$group_name"; local subs_file="$group_dir/subscriptions.txt"; local links_file="$group_dir/links.json"
    if [ ! -f "$subs_file" ]; then echo "🤷 No subscriptions found for '$group_name'." >&2; return; fi
    echo "🔄 Updating subscriptions for group '$group_name'..."
    local temp_links=$(mktemp); while IFS= read -r url; do echo "  -> Fetching from $url"; curl -L --fail -s "$url" | base64 --decode >> "$temp_links"; done < "$subs_file"
    local new_json="{}"; while IFS= read -r link; do
        if [ -n "$link" ]; then local remark=$(_get_remark_from_link "$link"); new_json=$(echo "$new_json" | jq --arg key "$remark" --arg value "$link" '. + {($key): $value}'); fi
    done < "$temp_links"; echo "$new_json" > "$links_file"; rm "$temp_links"; echo "✅ Subscription links for '$group_name' updated."
}
delete_link_by_remark() {
    local group_name="$1"; local remark="$2"; local links_file="$PROFILES_DIR/$group_name/links.json"
    if [ ! -f "$links_file" ]; then echo "❌ No links found for group '$group_name'." >&2; exit 1; fi
    if ! jq -e --arg key "$remark" 'has($key)' "$links_file" > /dev/null; then echo "❌ Link with remark '$remark' not found in group '$group_name'." >&2; exit 1; fi
    local temp_json=$(mktemp); jq --arg key "$remark" 'del(.[$key])' "$links_file" > "$temp_json"
    mv "$temp_json" "$links_file"; echo "✅ Link '$remark' deleted from group '$group_name'."
}
delete_group() {
    local group_name="$1"; if [ "$group_name" == "default" ]; then echo "❌ The 'default' group cannot be deleted." >&2; exit 1; fi
    local group_dir="$PROFILES_DIR/$group_name"; if [ ! -d "$group_dir" ]; then echo "❌ Group '$group_name' does not exist." >&2; exit 1; fi
    read -p "❓ Delete group '$group_name'? (y/N) " -n 1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then rm -rf "$group_dir"; echo "✅ Group '$group_name' deleted."; else echo "Aborted."; fi
}
list_groups() {
    if [ ! -d "$PROFILES_DIR" ] || [ -z "$(ls -A "$PROFILES_DIR" 2>/dev/null)" ]; then echo "🤷 No profile groups found."; return; fi
    echo "Available profile groups:";
    local current_link=""; [ -f "$LAST_SELECTED_LINK_FILE" ] && current_link=$(cat "$LAST_SELECTED_LINK_FILE")
    for d in "$PROFILES_DIR"/*; do
        if [ -d "$d" ]; then
            local group_name=$(basename "$d"); local group_type=$(_get_group_type "$group_name");
            local active_marker=" "; [ "$group_name" == "$ACTIVE_GROUP" ] && active_marker="*"
            printf " -> %s %-20s (type: %s)\n" "$active_marker" "$group_name" "$group_type"
        fi
    done
}
list_links_in_group() {
    local group_name="$1"; local links_file="$PROFILES_DIR/$group_name/links.json"
    if [ ! -f "$links_file" ] || ! [ -s "$links_file" ] || [[ $(jq 'length' "$links_file") -eq 0 ]]; then echo "🤷 No links found in group '$group_name'."; return; fi
    echo "Links in group '$group_name':";
    local current_link=""; [ -f "$LAST_SELECTED_LINK_FILE" ] && current_link=$(cat "$LAST_SELECTED_LINK_FILE")
    jq -r 'keys[] as $k | "\($k)"' "$links_file" | while IFS= read -r remark; do
        local link=$(jq -r --arg key "$remark" '.[$key]' "$links_file");
        local active_marker=" "; [ "$link" == "$current_link" ] && active_marker="*"
        printf "  %s %s\n" "$active_marker" "$remark"
    done
}
get_link_by_remark() {
    local group_name="$1"; local remark="$2"; local links_file="$PROFILES_DIR/$group_name/links.json"
    if [ -f "$links_file" ] && jq -e --arg key "$remark" 'has($key)' "$links_file" > /dev/null; then
        jq -r --arg key "$remark" '.[$key]' "$links_file"
    else return 1; fi
}
rename_group() {
    local old_name="$1"; local new_name="$2"; if [ -z "$old_name" ] || [ -z "$new_name" ]; then echo "❌ Missing arguments." >&2; exit 1; fi
    if [ "$old_name" == "default" ]; then echo "❌ The 'default' group cannot be renamed." >&2; exit 1; fi
    local old_dir="$PROFILES_DIR/$old_name"; local new_dir="$PROFILES_DIR/$new_name"
    if [ ! -d "$old_dir" ]; then echo "❌ Group '$old_name' does not exist." >&2; exit 1; fi
    if [ -d "$new_dir" ]; then echo "❌ Group '$new_name' already exists." >&2; exit 1; fi
    mv "$old_dir" "$new_dir"; echo "✅ Group '$old_name' renamed to '$new_name'."
}

# --- Command Router ---
case "$1" in
    add_link) add_link "$2" "$3" ;;
    add_sub) add_sub "$2" "$3" ;;
    update_sub) update_sub "$2" ;;
    delete_link_by_remark) delete_link_by_remark "$2" "$3" ;;
    delete_group) delete_group "$2" ;;
    list_groups) list_groups ;;
    list_links_in_group) list_links_in_group "$2" ;;
    get_link_by_remark) get_link_by_remark "$2" "$3" ;;
    create_group) create_group "$2" "$3" ;;
    rename_group) rename_group "$2" "$3" ;;
    *) echo "Unknown command for profile_manager: $1" >&2; exit 1 ;;
esac
