#!/bin/bash
# /home/pi/pi-offloader/retry_offload.sh
# Retries uploading files marked as copied but not uploaded.

# --- Load Environment & Setup ---
SCRIPT_DIR=$(dirname "$(realpath "$0")")
ENV_FILE="$SCRIPT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE"
  set +a
else
  echo "$(date): Error - Environment file $ENV_FILE not found." >> "$SCRIPT_DIR/logs/error.log"
  exit 1
fi

LOG_FILE="$SCRIPT_DIR/logs/retry_offload.log" # Use a specific log for retries
RCLONE_LOG="$UPLOAD_LOG" # Rclone still logs to its main file
NOTIFY_TOKEN="$INTERNAL_NOTIFY_TOKEN"
NOTIFY_URL="http://127.0.0.1:5000/internal/notify"

LOCAL_VIDEO_DEST="${LOCAL_FOOTAGE_PATH}/videos"
LOCAL_PHOTO_DEST="${LOCAL_FOOTAGE_PATH}/photos"

RCLONE_VIDEO_DEST="${RCLONE_REMOTE_NAME}:${RCLONE_REMOTE_BASE_PATH}/videos/"
RCLONE_PHOTO_DEST="${RCLONE_REMOTE_NAME}:${RCLONE_REMOTE_BASE_PATH}/photos/"

# --- Helper Functions ---
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"; }
notify() {
  local message="$1"; local type="${2:-info}"; local data
  if [ -z "$NOTIFY_TOKEN" ]; then log "Notify Error: Token missing."; return; fi
  if command -v jq > /dev/null; then data=$(jq -nc --arg msg "$message" --arg typ "$type" '{"message": $msg, "type": $typ}'); else message_esc=$(echo "$message" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed 's/&/\\u0026/g' | sed "s/'/\\u0027/g"); data="{\"message\": \"$message_esc\", \"type\": \"$type\"}"; fi
  curl -s -X POST -H "Content-Type: application/json" -H "X-Notify-Token: $NOTIFY_TOKEN" --data "$data" "$NOTIFY_URL" --max-time 5 > /dev/null 2>&1 &
}
create_marker() { local filepath="$1"; local type="$2"; touch "${filepath}.${type}"; }
check_marker() { local filepath="$1"; local type="$2"; [ -f "${filepath}.${type}" ]; }
# --- End Helpers ---

# --- Start Retry Script ---
log "===== Starting Retry Upload Process ====="
notify "Starting retry upload process..." "info"
mkdir -p "$(dirname "$LOG_FILE")"

RETRY_FOUND=0; RETRY_SUCCESS=0; RETRY_ERRORS=0

process_retry_dir() {
    local local_dir="$1"; local remote_dest="$2"; local file_type="$3"
    log "Checking $file_type in $local_dir for retries..."
    local found_needing_retry=0
    find "$local_dir" -maxdepth 1 -type f -print0 | while IFS= read -r -d $'\0' local_file; do
        filename=$(basename "$local_file")
        [[ "$filename" == .* ]] && continue # Skip hidden/marker files

        if check_marker "$local_file" "copied" && ! check_marker "$local_file" "uploaded"; then
            found_needing_retry=1; RETRY_FOUND=$((RETRY_FOUND + 1))
            log "Retrying upload for $filename to $remote_dest"
            notify "Retrying upload for $filename..." "info"

            rclone copyto --config "$RCLONE_CONFIG_PATH" "$local_file" "${remote_dest}${filename}" $RCLONE_COPY_FLAGS --log-file "$RCLONE_LOG"
            if [ $? -eq 0 ]; then
                log "Retry successful. Creating .uploaded marker for $filename"
                create_marker "$local_file" "uploaded"; RETRY_SUCCESS=$((RETRY_SUCCESS + 1))
                notify "$filename uploaded successfully on retry." "success"
            else
                log "Retry FAILED for $filename. Check rclone log: $RCLONE_LOG"
                RETRY_ERRORS=$((RETRY_ERRORS + 1)); notify "Retry failed for $filename." "error"
            fi
        fi
    done
    if [ $found_needing_retry -eq 0 ]; then log "No $file_type files found in $local_dir needing retry."; fi
    log "$file_type retry processing finished."
}

process_retry_dir "$LOCAL_VIDEO_DEST" "$RCLONE_VIDEO_DEST" "Videos"
process_retry_dir "$LOCAL_PHOTO_DEST" "$RCLONE_PHOTO_DEST" "Photos"

# --- Final Outcome ---
log "Retry phase complete. Files found needing retry: $RETRY_FOUND. Succeeded: $RETRY_SUCCESS. Failed: $RETRY_ERRORS."
if [ $RETRY_FOUND -eq 0 ]; then notify "Retry check complete. No files found needing retry." "info"
elif [ $RETRY_ERRORS -eq 0 ]; then notify "Retry process completed successfully (Processed: $RETRY_SUCCESS files)." "success"
else notify "Retry process finished with errors (Succeeded: $RETRY_SUCCESS, Failed: $RETRY_ERRORS)." "warning"; fi

log "===== Retry Upload Process Finished ====="
exit 0