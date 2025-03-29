#!/bin/bash
# /home/pi/pi-offloader/safe_eject.sh
# Attempts to safely unmount the SD card specified in .env

SCRIPT_DIR=$(dirname "$(realpath "$0")")
ENV_FILE="$SCRIPT_DIR/.env"
LOG_FILE="$SCRIPT_DIR/logs/eject.log"

# --- Helper: Notify ---
# (Same notify function as other scripts for consistency)
notify() {
  local message="$1"; local type="${2:-info}"; local data
  if [ -f "$ENV_FILE" ]; then source "$ENV_FILE" > /dev/null 2>&1; fi # Try to load token
  local NOTIFY_TOKEN="$INTERNAL_NOTIFY_TOKEN" # Get loaded token
  local NOTIFY_URL="http://127.0.0.1:5000/internal/notify"
  if [ -z "$NOTIFY_TOKEN" ]; then echo "$(date): Eject Notify Error: Token missing." >> "$LOG_FILE"; return; fi
  if command -v jq > /dev/null; then data=$(jq -nc --arg msg "$message" --arg typ "$type" '{"message": $msg, "type": $typ}'); else message_esc=$(echo "$message" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed 's/&/\\u0026/g' | sed "s/'/\\u0027/g"); data="{\"message\": \"$message_esc\", \"type\": \"$type\"}"; fi
  curl -s -X POST -H "Content-Type: application/json" -H "X-Notify-Token: $NOTIFY_TOKEN" --data "$data" "$NOTIFY_URL" --max-time 5 > /dev/null 2>&1 &
}

echo "$(date): --- Attempting Safe Eject ---" >> "$LOG_FILE"
mkdir -p "$(dirname "$LOG_FILE")"

# Load .env to get SD_MOUNT_PATH
if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
else
  echo "$(date): Error - Environment file $ENV_FILE not found." >> "$LOG_FILE"; exit 1
fi

# Check if SD_MOUNT_PATH is set
if [ -z "$SD_MOUNT_PATH" ]; then
    echo "$(date): Error - SD_MOUNT_PATH is not set in $ENV_FILE." >> "$LOG_FILE"; notify "Eject Error: SD_MOUNT_PATH not set in .env" "error"; exit 1
fi

# Check if it's actually mounted
if mountpoint -q "$SD_MOUNT_PATH"; then
  echo "$(date): Syncing filesystem for $SD_MOUNT_PATH..." >> "$LOG_FILE"
  sync # Ensure all data is written to disk before unmounting
  echo "$(date): Attempting to unmount $SD_MOUNT_PATH..." >> "$LOG_FILE"
  notify "Attempting to eject SD Card ($SD_MOUNT_PATH)..." "info"
  # Requires passwordless sudo permission configured in sudoers!
  sudo umount "$SD_MOUNT_PATH"
  if [ $? -eq 0 ]; then
    echo "$(date): Successfully unmounted $SD_MOUNT_PATH." >> "$LOG_FILE"; notify "SD Card ($SD_MOUNT_PATH) ejected successfully." "success"; exit 0
  else
    ERROR_MSG="Failed to unmount $SD_MOUNT_PATH. It might be busy. Check 'sudo lsof $SD_MOUNT_PATH'."
    echo "$(date): Error - $ERROR_MSG" >> "$LOG_FILE"; notify "Eject Failed: $SD_MOUNT_PATH might be busy." "error"; exit 1
  fi
else
  echo "$(date): $SD_MOUNT_PATH is not currently mounted. Nothing to eject." >> "$LOG_FILE"; notify "Eject Info: SD Card ($SD_MOUNT_PATH) was not mounted." "warning"; exit 0 # Not an error if it wasn't mounted
fi