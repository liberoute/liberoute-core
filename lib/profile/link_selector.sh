#!/bin/bash
set -e

# Displays an interactive menu for the user to select an active link from a group.
# Saves the selection to the state file.

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
# We still source this to get ACTIVE_GROUP and PROFILES_DIR
source "$ENV_PATH"

GROUP_TO_LIST="${1:-$ACTIVE_GROUP}"
LINKS_FILE="$PROFILES_DIR/$GROUP_TO_LIST/links.json"

# Construct the path to the state file directly to avoid errors if .env is malformed.
LAST_SELECTED_LINK_FILE="$PROJECT_ROOT/data/.last_selected_link"

echo "🔎 Listing links from group: '$GROUP_TO_LIST'..."

if [ ! -f "$LINKS_FILE" ] || ! [ -s "$LINKS_FILE" ] || [[ $(jq 'length' "$LINKS_FILE") -eq 0 ]]; then
    echo "🤷 No links found in group '$GROUP_TO_LIST'."
    echo "   -> Try adding one with 'liberoute add ...' or updating subscriptions."
    exit 0
fi

# Load the currently selected link to mark it as active
CURRENTLY_SELECTED_LINK=""
if [ -f "$LAST_SELECTED_LINK_FILE" ]; then
    CURRENTLY_SELECTED_LINK=$(cat "$LAST_SELECTED_LINK_FILE")
fi

# Use jq to create the menu options (the remarks/keys)
mapfile -t menu_options < <(jq -r 'keys[] as $k | "\($k)"' "$LINKS_FILE")
mapfile -t links < <(jq -r 'values[]' "$LINKS_FILE") # Get an array of the raw links

# Prepare the final menu with active marker
final_menu=()
for i in "${!menu_options[@]}"; do
    remark="${menu_options[$i]}"
    link="${links[$i]}"
    active_marker=" "
    if [ "$link" == "$CURRENTLY_SELECTED_LINK" ]; then
        active_marker="*"
    fi
    final_menu+=("$active_marker $remark")
done


PS3="Select a link to make active (or 'q' to quit): "
select menu_item in "${final_menu[@]}"; do
    if [[ -n "$menu_item" ]]; then
        # The REPLY variable holds the number of the selection
        selected_index=$((REPLY - 1))
        selected_link="${links[$selected_index]}"

        echo "✅ Saving selection..."
        mkdir -p "$(dirname "$LAST_SELECTED_LINK_FILE")"
        echo "$selected_link" > "$LAST_SELECTED_LINK_FILE"
        
        REMARK_TO_SHOW="${menu_options[$selected_index]}"
        echo "  -> Active link set to: $REMARK_TO_SHOW"
        
        # Also update the active group in the .env file
        sed -i "s/^ACTIVE_GROUP=.*/ACTIVE_GROUP=$GROUP_TO_LIST/" "$ENV_PATH"
        echo "  -> Active group set to: '$GROUP_TO_LIST'"
        
        echo "💡 Run 'sudo liberoute restart' to connect using this link."
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

if [ -z "$menu_item" ]; then echo "No selection made."; fi
