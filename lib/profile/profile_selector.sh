#!/bin/bash
set -e

# This script displays an interactive menu for the user to select
# an active connection profile.

# This script should be run from the project's root directory.
if [ -f "./.env" ]; then
    ENV_PATH="./.env"
elif [ -f "../../.env" ]; then
    ENV_PATH="../../.env"
else
    echo "❌ ERROR: .env file not found. This script should be run via the 'liberoute' command."
    exit 1
fi
# Load the environment variables to get PROFILE_DIR
source "$ENV_PATH"

if [ -z "${PROFILE_DIR-}" ] || [ ! -d "$PROFILE_DIR" ]; then
    echo "❌ ERROR: Profile directory not found at '$PROFILE_DIR'."
    exit 1
fi

# Get a list of available profiles
cd "$PROFILE_DIR"
profiles=(*.json)
cd "$OLDPWD" # Go back to the previous directory

if [ ${#profiles[@]} -eq 0 ] || [ "${profiles[0]}" == "*.json" ]; then
    echo "❌ No connection profiles found in '$PROFILE_DIR'."
    exit 1
fi

echo "✅ Profiles found. Please choose which one to make active:"
PS3="Select a profile (or enter 'q' to quit): "
select profile_filename in "${profiles[@]}"; do
    if [[ -n "$profile_filename" ]]; then
        # Use sed to replace the line starting with PROFILE= with the new value
        # This is safe even if the line doesn't exist.
        # First, remove the old line if it exists.
        sed -i '/^PROFILE=/d' "$ENV_FILE"
        # Then, add the new line.
        echo "PROFILE=${profile_filename}" >> "$ENV_FILE"
        echo ""
        echo "✅ Success! Active profile set to '$profile_filename'."
        echo "💡 Run 'sudo liberoute restart' to apply the change."
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

# If the user quits without selecting, handle it gracefully.
if [ -z "$profile_filename" ]; then
    echo "No profile selected. Exiting."
fi
