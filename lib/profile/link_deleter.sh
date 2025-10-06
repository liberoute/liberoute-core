#!/bin/bash
set -e

# Displays an interactive menu for the user to select and delete a link from a group.

# --- Setup ---
SCRIPT_DIR_HELPER=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
PROJECT_ROOT="$SCRIPT_DIR_HELPER/../.."
ENV_PATH="$PROJECT_ROOT/.env"
[ ! -f "$ENV_PATH" ] && { echo "❌ ERROR: .env file not found." >&2; exit 1; }
source "$ENV_PATH"

GROUP_TO_EDIT="${1:-$ACTIVE_GROUP}"
LINKS_FILE="$PROFILES_DIR/$GROUP_TO_EDIT/links.json"

echo "🔎 Listing links from group: '$GROUP_TO_EDIT'..."

if [ ! -f "$LINKS_FILE" ] || ! [ -s "$LINKS_FILE" ] || [[ $(jq 'length' "$LINKS_FILE") -eq 0 ]]; then
    echo "🤷 No links found in group '$GROUP_TO_EDIT' to delete."
    exit 0
fi

# Use jq to create the menu options (the remarks/keys)
mapfile -t menu_options < <(jq -r 'keys[]' "$LINKS_FILE")

PS3="Select a link to DELETE (or 'q' to quit): "
select remark_to_delete in "${menu_options[@]}"; do
    if [[ -n "$remark_to_delete" ]]; then
        read -p "❓ Are you sure you want to delete the link '$remark_to_delete'? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Call the profile manager to perform the deletion
            bash "$LIB_DIR/profile/profile_manager.sh" delete_link "$GROUP_TO_EDIT" "$remark_to_delete"
        else
            echo "Aborted."
        fi
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

if [ -z "$remark_to_delete" ]; then echo "No selection made."; fi
