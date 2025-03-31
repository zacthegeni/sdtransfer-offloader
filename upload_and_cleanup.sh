#!/bin/bash
# /home/pi/pi-offloader/upload_and_cleanup.sh
# Copies files, tracks state, uploads. Expects Mount Point as $1.

# --- Load Environment & Setup ---
SCRIPT_DIR=$(dirname "$(realpath "$0")")
ENV_FILE="$SCRIPT_DIR/.env"

# Load .env for settings OTHER than the mount point itself
if [ -f "$ENV_FILE" ]; then set -a; source "$ENV_FILE"; set +a; else echo "$(date): Error - Env file $ENV_FILE not found." >> "$SCRIPT_DIR/logs/error.log"; exit 1; fi

# --- Get Mount Point from Argument ---
ARG_MOUNT_POINT="$1"
if [ -z "$ARG_MOUNT_POINT" ]; then echo "$(date): Error - Mount point argument not provided." >> "$SCRIPT_DIR/logs/error.log"; exit 1; fi
if ! mountpoint -q "$ARG_MOUNT_POINT"; then echo "$(date): Error - Provided path '$ARG_MOUNT_POINT' is not a valid mount point." >> "$SCRIPT_DIR/logs/error.log"; exit 1; fi
SD_MOUNT_PATH="$ARG_MOUNT_POINT" # Use the validated argument
# --- End Mount Point Handling ---

# Define remaining variables based on loaded .env and argument
LOG_FILE="$OFFLOAD_LOG"; RCLONE_LOG="$UPLOAD_LOG"; NOTIFY_TOKEN="$INTERNAL_NOTIFY_TOKEN"; NOTIFY_URL="http://127.0.0.1:5000/internal/notify"
LOCAL_VIDEO_DEST="${LOCAL_FOOTAGE_PATH}/videos"; LOCAL_PHOTO_DEST="${LOCAL_FOOTAGE_PATH}/photos"
VIDEO_SOURCE_FULL="${SD_MOUNT_PATH}/${VIDEO_SUBDIR}"; PHOTO_SOURCE_FULL="${SD_MOUNT_PATH}/${PHOTO_SUBDIR}"
RCLONE_VIDEO_DEST="${RCLONE_REMOTE_NAME}:${RCLONE_REMOTE_BASE_PATH}/videos/"; RCLONE_PHOTO_DEST="${RCLONE_REMOTE_NAME}:${RCLONE_REMOTE_BASE_PATH}/photos/"

# --- Helper Functions (Unchanged) ---
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"; }
notify() {
  local message="$1"; local type="${2:-info}"; local data; if [ -z "$NOTIFY_TOKEN" ]; then log "Notify Error: Token missing."; return; fi
  if command -v jq > /dev/null; then data=$(jq -nc --arg msg "$message" --arg typ "$type" '{"message": $msg, "type": $typ}'); else message_esc=$(echo "$message" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed 's/&/\\u0026/g' | sed "s/'/\\u0027/g"); data="{\"message\": \"$message_esc\", \"type\": \"$type\"}"; fi
  curl -s -X POST -H "Content-Type: application/json" -H "X-Notify-Token: $NOTIFY_TOKEN" --data "$data" "$NOTIFY_URL" --max-time 5 --connect-timeout 3 > /dev/null 2>&1 &
}
create_marker() { local filepath="$1"; local type="$2"; touch "${filepath}.${type}"; }
check_marker() { local filepath="$1"; local type="$2"; [ -f "${filepath}.${type}" ]; }
# --- End Helpers ---

# --- Start Script ---
log "===== Starting Offload/Upload Process for $SD_MOUNT_PATH ====="; notify "Starting Offload for $SD_MOUNT_PATH..." "info"
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$RCLONE_LOG")" "$LOCAL_VIDEO_DEST" "$LOCAL_PHOTO_DEST"
log "SD Card mounted at $SD_MOUNT_PATH."

# --- Copy NEW files (Unchanged Logic) ---
log "Starting file copy and marking..."; COPY_COUNT=0; COPY_ERRORS=0
process_source_dir() {
    local source_dir="$1"; local dest_dir="$2"; local file_type="$3"
    if [ ! -d "$source_dir" ]; then log "$file_type source dir not found: $source_dir"; return; fi
    log "Processing $file_type from $source_dir to $dest_dir"; local found_files=0
    find "$source_dir" -type f -print0 | while IFS= read -r -d $'\0' source_file; do
        found_files=1; filename=$(basename "$source_file"); dest_file="$dest_dir/$filename"
        if check_marker "$dest_file" "copied"; then continue; fi
        log "Copying $filename to $dest_dir"; rsync -W --info=progress2 "$source_file" "$dest_dir/"
        if [ $? -eq 0 ]; then log "Creating .copied marker for $filename"; create_marker "$dest_file" "copied"; COPY_COUNT=$((COPY_COUNT + 1)); else log "Error copying $filename."; COPY_ERRORS=$((COPY_ERRORS + 1)); notify "Error copying $filename from SD." "error"; fi
    done
    if [ $found_files -eq 0 ]; then log "No files found in $source_dir to process."; fi; log "$file_type copy processing finished."
}
process_source_dir "$VIDEO_SOURCE_FULL" "$LOCAL_VIDEO_DEST" "Videos"; process_source_dir "$PHOTO_SOURCE_FULL" "$LOCAL_PHOTO_DEST" "Photos"
log "File copy phase complete. Copied: $COPY_COUNT files. Errors: $COPY_ERRORS."; if [ $COPY_ERRORS -gt 0 ]; then notify "Encountered $COPY_ERRORS errors during file copy." "warning"; fi

# --- Upload files (Unchanged Logic) ---
log "Starting upload phase for non-uploaded files..."; UPLOAD_COUNT=0; UPLOAD_ERRORS=0
process_upload_dir() {
    local local_dir="$1"; local remote_dest="$2"; local file_type="$3"
    log "Checking $file_type in $local_dir for upload..."; local found_files_to_upload=0
    find "$local_dir" -maxdepth 1 -type f -print0 | while IFS= read -r -d $'\0' local_file; do
        filename=$(basename "$local_file"); [[ "$filename" == .* ]] && continue # Skip hidden/markers
        if check_marker "$local_file" "copied" && ! check_marker "$local_file" "uploaded"; then
            found_files_to_upload=1; log "Uploading $filename to $remote_dest"; notify "Uploading $filename..." "info"
            # Add --log-file here if needed for individual file logs
            rclone copyto --config "$RCLONE_CONFIG_PATH" "$local_file" "${remote_dest}${filename}" $RCLONE_COPY_FLAGS --log-file "$RCLONE_LOG"
            if [ $? -eq 0 ]; then log "Creating .uploaded marker for $filename"; create_marker "$local_file" "uploaded"; UPLOAD_COUNT=$((UPLOAD_COUNT + 1)); notify "$filename uploaded successfully." "success"; else log "Error uploading $filename. Check rclone log: $RCLONE_LOG"; UPLOAD_ERRORS=$((UPLOAD_ERRORS + 1)); notify "Error uploading $filename." "error"; fi
        fi
    done
    if [ $found_files_to_upload -eq 0 ]; then log "No $file_type files found in $local_dir needing upload."; fi; log "$file_type upload processing finished."
}
process_upload_dir "$LOCAL_VIDEO_DEST" "$RCLONE_VIDEO_DEST" "Videos"; process_upload_dir "$LOCAL_PHOTO_DEST" "$RCLONE_PHOTO_DEST" "Photos"
log "Upload phase complete. Uploaded: $UPLOAD_COUNT files. Errors: $UPLOAD_ERRORS."; if [ $UPLOAD_ERRORS -gt 0 ]; then notify "Encountered $UPLOAD_ERRORS errors during file upload." "warning"; fi

# --- Final Outcome (Unchanged Logic) ---
FINAL_MSG="Offload/Upload process finished."; FINAL_TYPE="info"
if [ $COPY_ERRORS -eq 0 ] && [ $UPLOAD_ERRORS -eq 0 ]; then if [ $COPY_COUNT -gt 0 ] || [ $UPLOAD_COUNT -gt 0 ]; then FINAL_MSG="Offload completed (Copied: $COPY_COUNT, Uploaded: $UPLOAD_COUNT)."; FINAL_TYPE="success"; else FINAL_MSG="Offload finished. No new files found/processed."; FINAL_TYPE="info"; fi
elif [ $UPLOAD_ERRORS -gt 0 ]; then FINAL_MSG="Offload finished with UPLOAD errors (Errors: $UPLOAD_ERRORS)."; FINAL_TYPE="error"
else FINAL_MSG="Offload finished with COPY errors (Errors: $COPY_ERRORS)."; FINAL_TYPE="warning"; fi
log "$FINAL_MSG"; notify "$FINAL_MSG" "$FINAL_TYPE"
log "===== Offload and Upload Process Finished for $SD_MOUNT_PATH ====="
exit 0