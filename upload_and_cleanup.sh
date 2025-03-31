#!/bin/bash
# Ensure this file is saved with Unix LF line endings and without a BOM!

# --- Enhanced Debugging & Error Handling ---
# Uncomment set -e or set -x if desired for stricter error handling or more verbose output.
# set -e
# set -x

echo "--- [$(date)] Script: upload_and_cleanup.sh --- START ---"

# --- Configuration & Initial Checks ---
echo "[DEBUG] Determining script directory..."
SCRIPT_DIR_CMD_OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR_EXIT_CODE=$?
if [ ${SCRIPT_DIR_EXIT_CODE} -ne 0 ] || [ -z "${SCRIPT_DIR_CMD_OUT}" ]; then
    echo "[ERROR] Failed to determine script directory. Exit Code: ${SCRIPT_DIR_EXIT_CODE}. Output: '${SCRIPT_DIR_CMD_OUT}'. Exiting." >&2
    exit 1
fi
SCRIPT_DIR="${SCRIPT_DIR_CMD_OUT}"
echo "[INFO] Script directory: ${SCRIPT_DIR}"

PROJECT_USER="zmakey"

# Critical paths (verify these values match your system)
SD_MOUNT="/media/zmakey/251 GB Volume" # Adjust if necessary
VIDEO_REL_PATH="PRIVATE/M4ROOT/CLIP"
PHOTO_REL_PATH="DCIM/100MSDCF"

# Local storage directories
LOCAL_BASE="${SCRIPT_DIR}/footage"
LOCAL_VIDEO="${LOCAL_BASE}/videos"
LOCAL_PHOTO="${LOCAL_BASE}/photos"

# Rclone configuration
RCLONE_CONFIG="${SCRIPT_DIR}/rclone.conf"
RCLONE_REMOTE_NAME="gdrive"
RCLONE_BASE_PATH="FX3_Backups"

# Log file locations
LOG_DIR="${SCRIPT_DIR}/logs"
RCLONE_LOG="${LOG_DIR}/upload.log"

echo "[DEBUG] Checking log directory: ${LOG_DIR}"
if [ ! -d "${LOG_DIR}" ]; then
    echo "[WARN] Log directory ${LOG_DIR} not found. Attempting to create..."
    mkdir -p "${LOG_DIR}"
    if [ $? -ne 0 ]; then
        echo "[ERROR] Failed to create log directory ${LOG_DIR}. Check permissions. Exiting." >&2
        exit 1
    fi
    chown "${PROJECT_USER}:${PROJECT_USER}" "${LOG_DIR}" || echo "[WARN] Could not set ownership on ${LOG_DIR}."
fi
if ! touch "${LOG_DIR}/.writetest" 2>/dev/null; then
    echo "[ERROR] Log directory ${LOG_DIR} is not writable by user $(whoami). Check permissions. Exiting." >&2
    exit 1
else
    rm "${LOG_DIR}/.writetest"
fi
echo "[INFO] Log directory check passed."

# Rclone options
RCLONE_OPTS=(
    "--config" "${RCLONE_CONFIG}"
    "--log-level" "INFO"
    "--log-file" "${RCLONE_LOG}"
    "--min-age" "1m"
    "--fast-list"
    "--transfers" "4"
    "--checkers" "8"
    "--contimeout" "60s"
    "--timeout" "300s"
    "--retries" "3"
    "--low-level-retries" "10"
    "--stats" "1m"
)

echo "[INFO] Configuration:"
echo "  SD_MOUNT: ${SD_MOUNT}"
echo "  VIDEO_REL_PATH: ${VIDEO_REL_PATH}"
echo "  PHOTO_REL_PATH: ${PHOTO_REL_PATH}"
echo "  LOCAL_VIDEO: ${LOCAL_VIDEO}"
echo "  LOCAL_PHOTO: ${LOCAL_PHOTO}"
echo "  RCLONE_CONFIG: ${RCLONE_CONFIG}"
echo "  RCLONE_LOG: ${RCLONE_LOG}"

# Logging function
log_msg() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line="[${timestamp}] [${level}] ${message}"
    echo "${log_line}" >> "${RCLONE_LOG}"
    if [[ "$level" == "ERROR" ]]; then
        echo "${log_line}" >&2
    else
        echo "${log_line}"
    fi
    if [ $? -ne 0 ]; then
         echo "[${timestamp}] [ERROR] FAILED TO WRITE TO LOG FILE: ${RCLONE_LOG}" >&2
    fi
}

log_msg "INFO" "=== upload_and_cleanup.sh script started ==="

# 0. Check rclone config
log_msg "DEBUG" "Checking for rclone config file: ${RCLONE_CONFIG}"
if [ ! -f "${RCLONE_CONFIG}" ]; then
  log_msg "ERROR" "Rclone config file not found at ${RCLONE_CONFIG}. Cannot upload. Exiting."
  exit 1
fi
if [ ! -r "${RCLONE_CONFIG}" ]; then
  log_msg "ERROR" "Rclone config file not readable at ${RCLONE_CONFIG}. Check permissions. Exiting."
  exit 1
fi
log_msg "INFO" "Rclone config file found and readable."

# 1. Check if SD card is mounted
log_msg "DEBUG" "Checking mountpoint: ${SD_MOUNT}"
if ! findmnt --target "${SD_MOUNT}" > /dev/null; then
  log_msg "WARN" "SD card is not mounted at ${SD_MOUNT} according to findmnt."
  log_msg "ERROR" "SD Card mount check failed. Please ensure it's inserted and mounted correctly at '${SD_MOUNT}'. Exiting."
  exit 1
fi
log_msg "INFO" "SD card is mounted at ${SD_MOUNT}."

# 2. Ensure local directories exist and are writable
log_msg "DEBUG" "Ensuring local directories exist and are writable: ${LOCAL_VIDEO}, ${LOCAL_PHOTO}"
for dir in "${LOCAL_VIDEO}" "${LOCAL_PHOTO}"; do
    if ! mkdir -p "${dir}"; then
        log_msg "ERROR" "Failed to create local directory ${dir}. Check permissions. Exiting."
        exit 1
    fi
    if ! touch "${dir}/.writetest" 2>/dev/null; then
        log_msg "ERROR" "Local directory ${dir} is not writable. Check permissions. Exiting."
        exit 1
    else
        rm "${dir}/.writetest"
    fi
done
log_msg "INFO" "Local directories ensured and writable."

# 3. Define full source paths
VIDEO_SOURCE="${SD_MOUNT}/${VIDEO_REL_PATH}"
PHOTO_SOURCE="${SD_MOUNT}/${PHOTO_REL_PATH}"
log_msg "DEBUG" "Source paths defined: VIDEO=${VIDEO_SOURCE}, PHOTO=${PHOTO_SOURCE}"

# 4. Copy files from SD to local storage
log_msg "INFO" "Starting local copy phase (rsync)..."
COPY_ERRORS=0

log_msg "DEBUG" "Checking video source directory: ${VIDEO_SOURCE}"
if [ ! -d "$VIDEO_SOURCE" ]; then
    log_msg "WARN" "Video source directory ${VIDEO_SOURCE} not found. Skipping video copy."
elif [ ! -r "$VIDEO_SOURCE" ]; then
    log_msg "WARN" "Video source directory ${VIDEO_SOURCE} not readable. Skipping video copy."
else
    log_msg "INFO" "Copying videos from ${VIDEO_SOURCE} to ${LOCAL_VIDEO}..."
    rsync -av --no-perms --ignore-existing "${VIDEO_SOURCE}/" "${LOCAL_VIDEO}/" >> "${RCLONE_LOG}" 2>&1
    RSYNC_V_EXIT=$?
    if [ ${RSYNC_V_EXIT} -eq 0 ]; then
        log_msg "INFO" "Video copy finished successfully (rsync exit code 0)."
    else
        log_msg "ERROR" "Error during video copy (rsync exit code ${RSYNC_V_EXIT}). Check rsync output above in log file."
        COPY_ERRORS=1
    fi
fi

log_msg "DEBUG" "Checking photo source directory: ${PHOTO_SOURCE}"
if [ ! -d "$PHOTO_SOURCE" ]; then
    log_msg "WARN" "Photo source directory ${PHOTO_SOURCE} not found. Skipping photo copy."
elif [ ! -r "$PHOTO_SOURCE" ]; then
    log_msg "WARN" "Photo source directory ${PHOTO_SOURCE} not readable. Skipping photo copy."
else
    log_msg "INFO" "Copying photos from ${PHOTO_SOURCE} to ${LOCAL_PHOTO}..."
    rsync -av --no-perms --ignore-existing "${PHOTO_SOURCE}/" "${LOCAL_PHOTO}/" >> "${RCLONE_LOG}" 2>&1
    RSYNC_P_EXIT=$?
    if [ ${RSYNC_P_EXIT} -eq 0 ]; then
        log_msg "INFO" "Photo copy finished successfully (rsync exit code 0)."
    else
        log_msg "ERROR" "Error during photo copy (rsync exit code ${RSYNC_P_EXIT}). Check rsync output above in log file."
        COPY_ERRORS=1
    fi
fi

log_msg "INFO" "Local copy phase complete."
if [ ${COPY_ERRORS} -ne 0 ]; then
    log_msg "WARN" "Errors occurred during the local copy phase. Upload will proceed, but source files may be missing."
fi

# 5. Upload files from local storage to Google Drive
log_msg "INFO" "Starting upload phase (rclone)..."
UPLOAD_ERRORS=0

log_msg "DEBUG" "Checking for rclone command..."
if ! command -v rclone &> /dev/null; then
    log_msg "ERROR" "rclone command not found in PATH. Cannot upload. Exiting."
    exit 1
fi
log_msg "INFO" "rclone command found: $(command -v rclone)"

log_msg "DEBUG" "Performing rclone connectivity test (lsd)..."
rclone lsd "${RCLONE_REMOTE_NAME}:" "${RCLONE_OPTS[@]}" --max-depth 1 > /dev/null 2>&1
RCLONE_LSD_EXIT=$?
if [ ${RCLONE_LSD_EXIT} -ne 0 ]; then
    log_msg "ERROR" "Rclone failed to list remote '${RCLONE_REMOTE_NAME}:' (Exit Code: ${RCLONE_LSD_EXIT}). Check authentication and config (${RCLONE_CONFIG}). Check detailed rclone log (${RCLONE_LOG}). Exiting."
    exit 1
fi
log_msg "INFO" "Rclone connectivity test successful."

log_msg "DEBUG" "Checking local video directory for upload: ${LOCAL_VIDEO}"
if [ -z "$(ls -A "${LOCAL_VIDEO}" 2>/dev/null)" ]; then
    log_msg "INFO" "Local video directory ${LOCAL_VIDEO} is empty or contains no files. Skipping video upload."
else
    log_msg "INFO" "Uploading videos from ${LOCAL_VIDEO} to ${RCLONE_REMOTE_NAME}:${RCLONE_BASE_PATH}/videos/"
    rclone copy "${RCLONE_OPTS[@]}" "$LOCAL_VIDEO" "${RCLONE_REMOTE_NAME}:${RCLONE_BASE_PATH}/videos/"
    RCLONE_V_EXIT=$?
    if [ ${RCLONE_V_EXIT} -ne 0 ]; then
        log_msg "ERROR" "rclone reported errors during video upload (Exit Code: ${RCLONE_V_EXIT}). Check rclone log: ${RCLONE_LOG}"
        UPLOAD_ERRORS=1
    else
        log_msg "INFO" "rclone video upload finished (Exit Code: 0)."
    fi
fi

log_msg "DEBUG" "Checking local photo directory for upload: ${LOCAL_PHOTO}"
if [ -z "$(ls -A "${LOCAL_PHOTO}" 2>/dev/null)" ]; then
    log_msg "INFO" "Local photo directory ${LOCAL_PHOTO} is empty or contains no files. Skipping photo upload."
else
    log_msg "INFO" "Uploading photos from ${LOCAL_PHOTO} to ${RCLONE_REMOTE_NAME}:${RCLONE_BASE_PATH}/photos/"
    rclone copy "${RCLONE_OPTS[@]}" "$LOCAL_PHOTO" "${RCLONE_REMOTE_NAME}:${RCLONE_BASE_PATH}/photos/"
    RCLONE_P_EXIT=$?
    if [ ${RCLONE_P_EXIT} -ne 0 ]; then
        log_msg "ERROR" "rclone reported errors during photo upload (Exit Code: ${RCLONE_P_EXIT}). Check rclone log: ${RCLONE_LOG}"
        UPLOAD_ERRORS=1
    else
         log_msg "INFO" "rclone photo upload finished (Exit Code: 0)."
    fi
fi

log_msg "INFO" "Upload phase complete."

# 6. Final Status and Exit Code
FINAL_EXIT_CODE=0
if [ ${COPY_ERRORS} -ne 0 ] || [ ${UPLOAD_ERRORS} -ne 0 ]; then
    log_msg "ERROR" "Errors occurred during the script execution. Please review logs."
    FINAL_EXIT_CODE=1
else
    log_msg "INFO" "Script execution finished successfully."
fi

log_msg "INFO" "=== upload_and_cleanup.sh script finished ==="
echo "--- [$(date)] Script: upload_and_cleanup.sh --- END ---"

exit ${FINAL_EXIT_CODE}
