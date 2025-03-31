#!/bin/bash
# /home/pi/pi-offloader/offload.sh
# Wrapper script. Can be triggered by udev (passing mount point as $1)
# or manually (will try to use SD_MOUNT_PATH from .env if set).
# Loads .env and calls upload_and_cleanup.sh, passing the mount point.

SCRIPT_DIR=$(dirname "$(realpath "$0")")
ENV_FILE="$SCRIPT_DIR/.env"
UPLOAD_SCRIPT="$SCRIPT_DIR/upload_and_cleanup.sh"
LOG_FILE_WRAPPER="$SCRIPT_DIR/logs/offload_wrapper.log"
LAST_RUN_FILE="$SCRIPT_DIR/logs/last_run.txt"

# --- Logging for Wrapper ---
log_wrapper() { echo "$(date '+%Y-%m-%d %H:%M:%S') - Wrapper: $1" >> "$LOG_FILE_WRAPPER"; }
mkdir -p "$(dirname "$LOG_FILE_WRAPPER")" # Ensure log dir exists
log_wrapper "--- Offload Wrapper Started ---"

# --- Determine Mount Point ---
SD_MOUNT_PATH_EFFECTIVE=""

# 1. Check if an argument was passed (likely from udev's %E{MOUNT_POINT})
if [ -n "$1" ]; then
  # Basic check: is it a non-empty string and does it look like a path?
  if [[ "$1" == /* ]] && [ -d "$1" ]; then
      # More robust check: Is it actually a mount point?
      if mountpoint -q "$1"; then
          SD_MOUNT_PATH_EFFECTIVE="$1"
          log_wrapper "Using mount point passed as argument: $SD_MOUNT_PATH_EFFECTIVE"
      else
          log_wrapper "Warning: Argument '$1' exists but is not currently a mount point. Ignoring."
      fi
  else
      log_wrapper "Warning: Argument '$1' received but is not a valid directory path. Ignoring."
  fi
fi

# 2. If no valid argument, try loading from .env (for manual runs or fallback)
if [ -z "$SD_MOUNT_PATH_EFFECTIVE" ]; then
    log_wrapper "No valid mount point from argument, checking .env file..."
    if [ -f "$ENV_FILE" ]; then
        # Source .env within a subshell to avoid polluting parent environment if not needed later
        # Then explicitly read the variable we need.
        # shellcheck disable=SC1090
        SD_MOUNT_PATH_FROM_ENV=$(source "$ENV_FILE" >/dev/null 2>&1 && echo "$SD_MOUNT_PATH")

        if [ -n "$SD_MOUNT_PATH_FROM_ENV" ]; then
            log_wrapper "Found SD_MOUNT_PATH in .env: '$SD_MOUNT_PATH_FROM_ENV'"
            # Verify the path from .env is actually mounted NOW
            if mountpoint -q "$SD_MOUNT_PATH_FROM_ENV"; then
                 SD_MOUNT_PATH_EFFECTIVE="$SD_MOUNT_PATH_FROM_ENV"
                 log_wrapper "Using currently mounted path from .env: $SD_MOUNT_PATH_EFFECTIVE"
            else
                 log_wrapper "Path '$SD_MOUNT_PATH_FROM_ENV' from .env is not currently mounted. Cannot use."
            fi
        else
            log_wrapper "SD_MOUNT_PATH variable not defined or empty in $ENV_FILE."
        fi
        # Load all env vars now for the child script if needed (after potentially using one)
        set -a; source "$ENV_FILE"; set +a
    else
        log_wrapper "Error: Environment file $ENV_FILE not found. Cannot load settings."
        # Cannot proceed without settings
        exit 1
    fi
fi

# 3. Final Check - Abort if no valid mount point found
if [ -z "$SD_MOUNT_PATH_EFFECTIVE" ]; then
    log_wrapper "Error: No valid & currently mounted SD card mount point found. Aborting."
    # Notify UI about the failure
    if command -v curl > /dev/null && command -v jq > /dev/null && [ -n "$INTERNAL_NOTIFY_TOKEN" ]; then
        message="Offload Error: No valid SD mount point found (checked args & .env)."
        data=$(jq -nc --arg msg "$message" --arg typ "error" '{"message": $msg, "type": $typ}')
        curl -s -X POST -H "Content-Type: application/json" -H "X-Notify-Token: $INTERNAL_NOTIFY_TOKEN" \
             --data "$data" "http://127.0.0.1:5000/internal/notify" --max-time 5 --connect-timeout 3 > /dev/null 2>&1 &
    fi
    exit 1
fi


# --- Execute Main Script ---
if [ -x "$UPLOAD_SCRIPT" ]; then
  log_wrapper "Executing $UPLOAD_SCRIPT with mount point $SD_MOUNT_PATH_EFFECTIVE"
  # Pass the determined mount point as the FIRST argument to the main script
  bash "$UPLOAD_SCRIPT" "$SD_MOUNT_PATH_EFFECTIVE" >> "$LOG_FILE_WRAPPER" 2>&1
  EXIT_CODE=$?
  log_wrapper "Upload script finished with exit code: $EXIT_CODE"

  # Write timestamp on completion (consider only writing on EXIT_CODE 0?)
  echo "$(date '+%Y-%m-%d %H:%M:%S %Z')" > "$LAST_RUN_FILE"
  log_wrapper "Timestamp written to $LAST_RUN_FILE"

else
  log_wrapper "Error: Upload script $UPLOAD_SCRIPT not found or not executable."
  exit 1
fi

log_wrapper "--- Offload Wrapper Finished ---"
exit 0