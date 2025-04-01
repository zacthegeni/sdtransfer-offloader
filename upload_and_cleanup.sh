#!/bin/bash
# Ensure this file is saved with Unix LF line endings and without a BOM!
set -ex

echo "--- [$(date)] Script: upload_and_cleanup.sh --- START ---"

echo '[DEBUG] Determining script directory...'
SCRIPT_DIR_CMD_OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR_EXIT_CODE=$?
if [ ${SCRIPT_DIR_EXIT_CODE} -ne 0 ] || [ -z "${SCRIPT_DIR_CMD_OUT}" ]; then
    echo "[ERROR] Failed to determine script directory. Exiting." >&2
    exit 1
fi
SCRIPT_DIR="${SCRIPT_DIR_CMD_OUT}"
echo "[INFO] Script directory: ${SCRIPT_DIR}"

PROJECT_USER="zmakey"

# Set the SD card mount point (as mounted by your system)
SD_MOUNT="/media/zmakey/A0C2-FF6F"
VIDEO_REL_PATH="PRIVATE/M4ROOT/CLIP"
PHOTO_REL_PATH="DCIM/100MSDCF"

LOCAL_BASE="${SCRIPT_DIR}/footage"
LOCAL_VIDEO="${LOCAL_BASE}/videos"
LOCAL_PHOTO="${LOCAL_BASE}/photos"

RCLONE_CONFIG="${SCRIPT_DIR}/rclone.conf"
RCLONE_REMOTE_NAME="gdrive"
RCLONE_BASE_PATH="FX3_Backups"

LOG_DIR="${SCRIPT_DIR}/logs"
RCLONE_LOG="${LOG_DIR}/upload.log"

echo '[DEBUG] Verifying log directory: '"${LOG_DIR}"
if [ ! -d "${LOG_DIR}" ]; then
    echo "[WARN] Log directory not found. Creating it..."
    mkdir -p "${LOG_DIR}" || { echo "[ERROR] Could not create log directory. Exiting."; exit 1; }
    chown "${PROJECT_USER}:${PROJECT_USER}" "${LOG_DIR}" || echo "[WARN] Could not set ownership on ${LOG_DIR}."
fi
touch "${LOG_DIR}/.writetest" && rm "${LOG_DIR}/.writetest"
echo "[INFO] Log directory check passed."

# Updated rclone options for faster uploads of large files:
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
    "--drive-chunk-size" "128M"
)

echo "[INFO] Configuration:"
echo "  SD_MOUNT: ${SD_MOUNT}"
echo "  VIDEO_REL_PATH: ${VIDEO_REL_PATH}"
echo "  PHOTO_REL_PATH: ${PHOTO_REL_PATH}"
echo "  LOCAL_VIDEO: ${LOCAL_VIDEO}"
echo "  LOCAL_PHOTO: ${LOCAL_PHOTO}"
echo "  RCLONE_CONFIG: ${RCLONE_CONFIG}"
echo "  RCLONE_LOG: ${RCLONE_LOG}"

# Logging function: writes to both stdout and the log file.
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
}

log_msg INFO "=== upload_and_cleanup.sh script started ==="

log_msg DEBUG "Checking for rclone config file: ${RCLONE_CONFIG}"
if [ ! -f "${RCLONE_CONFIG}" ]; then
  log_msg ERROR "Rclone config file not found at ${RCLONE_CONFIG}. Exiting."
  exit 1
fi
if [ ! -r "${RCLONE_CONFIG}" ]; then
  log_msg ERROR "Rclone config file not readable at ${RCLONE_CONFIG}. Exiting."
  exit 1
fi
log_msg INFO "Rclone config file found and readable."

log_msg DEBUG "Checking mountpoint: ${SD_MOUNT}"
if ! findmnt --target "${SD_MOUNT}" > /dev/null; then
  log_msg WARN "SD card is not mounted at ${SD_MOUNT}."
  log_msg ERROR "SD card mount check failed. Exiting."
  exit 1
fi
log_msg INFO "SD card is mounted at ${SD_MOUNT}."

log_msg DEBUG "Ensuring local directories exist for: ${LOCAL_VIDEO} and ${LOCAL_PHOTO}"
for dir in "${LOCAL_VIDEO}" "${LOCAL_PHOTO}"; do
    mkdir -p "${dir}" || { log_msg ERROR "Failed to create ${dir}."; exit 1; }
    touch "${dir}/.writetest" 2>/dev/null || { log_msg ERROR "Directory ${dir} is not writable."; exit 1; }
    rm "${dir}/.writetest"
done
log_msg INFO "Local directories are present and writable."

VIDEO_SOURCE="${SD_MOUNT}/${VIDEO_REL_PATH}"
PHOTO_SOURCE="${SD_MOUNT}/${PHOTO_REL_PATH}"
log_msg DEBUG "Defined source paths: VIDEO=${VIDEO_SOURCE}, PHOTO=${PHOTO_SOURCE}"

log_msg INFO "Starting local copy (rsync)..."
COPY_ERRORS=0

log_msg DEBUG "Checking video source directory: ${VIDEO_SOURCE}"
if [ ! -d "${VIDEO_SOURCE}" ]; then
    log_msg WARN "Video source directory ${VIDEO_SOURCE} not found. Skipping video copy."
elif [ ! -r "${VIDEO_SOURCE}" ]; then
    log_msg WARN "Video source directory ${VIDEO_SOURCE} not readable. Skipping video copy."
else
    log_msg INFO "Copying videos from ${VIDEO_SOURCE} to ${LOCAL_VIDEO}..."
    rsync -av --no-perms --ignore-existing "${VIDEO_SOURCE}/" "${LOCAL_VIDEO}/" >> "${RCLONE_LOG}" 2>&1
    RSYNC_V_EXIT=$?
    if [ ${RSYNC_V_EXIT} -eq 0 ]; then
        log_msg INFO "Video copy completed successfully."
    else
        log_msg ERROR "Error during video copy (exit code ${RSYNC_V_EXIT})."
        COPY_ERRORS=1
    fi
fi

log_msg DEBUG "Checking photo source directory: ${PHOTO_SOURCE}"
if [ ! -d "${PHOTO_SOURCE}" ]; then
    log_msg WARN "Photo source directory ${PHOTO_SOURCE} not found. Skipping photo copy."
elif [ ! -r "${PHOTO_SOURCE}" ]; then
    log_msg WARN "Photo source directory ${PHOTO_SOURCE} not readable. Skipping photo copy."
else
    log_msg INFO "Copying photos from ${PHOTO_SOURCE} to ${LOCAL_PHOTO}..."
    rsync -av --no-perms --ignore-existing "${PHOTO_SOURCE}/" "${LOCAL_PHOTO}/" >> "${RCLONE_LOG}" 2>&1
    RSYNC_P_EXIT=$?
    if [ ${RSYNC_P_EXIT} -eq 0 ]; then
        log_msg INFO "Photo copy completed successfully."
    else
        log_msg ERROR "Error during photo copy (exit code ${RSYNC_P_EXIT})."
        COPY_ERRORS=1
    fi
fi

log_msg INFO "Local copy phase complete."
if [ ${COPY_ERRORS} -ne 0 ]; then
    log_msg WARN "There were errors during the local copy phase; some files might not have been copied."
fi

log_msg INFO "Starting upload phase (rclone)..."
UPLOAD_ERRORS=0

log_msg DEBUG "Checking for rclone command..."
if ! command -v rclone &> /dev/null; then
    log_msg ERROR "rclone command not found in PATH. Exiting."
    exit 1
fi
log_msg INFO "rclone command is available: $(command -v rclone)"

log_msg DEBUG "Performing rclone connectivity test (lsd)..."
rclone lsd "${RCLONE_REMOTE_NAME}:" "${RCLONE_OPTS[@]}" --max-depth 1 > /dev/null 2>&1
RCLONE_LSD_EXIT=$?
if [ ${RCLONE_LSD_EXIT} -ne 0 ]; then
    log_msg ERROR "Rclone failed to list remote '${RCLONE_REMOTE_NAME}:' (exit code ${RCLONE_LSD_EXIT}). Exiting."
    exit 1
fi
log_msg INFO "Rclone connectivity test passed."

log_msg DEBUG "Uploading videos if available..."
if [ -z "$(ls -A "${LOCAL_VIDEO}" 2>/dev/null)" ]; then
    log_msg INFO "No files in ${LOCAL_VIDEO}; skipping video upload."
else
    log_msg INFO "Uploading videos from ${LOCAL_VIDEO} to ${RCLONE_REMOTE_NAME}:${RCLONE_BASE_PATH}/videos/"
    rclone copy "${RCLONE_OPTS[@]}" "${LOCAL_VIDEO}" "${RCLONE_REMOTE_NAME}:${RCLONE_BASE_PATH}/videos/"
    RCLONE_V_EXIT=$?
    if [ ${RCLONE_V_EXIT} -ne 0 ]; then
        log_msg ERROR "rclone video upload failed (exit code ${RCLONE_V_EXIT})."
        UPLOAD_ERRORS=1
    else
        log_msg INFO "Video upload completed successfully."
    fi
fi

log_msg DEBUG "Uploading photos if available..."
if [ -z "$(ls -A "${LOCAL_PHOTO}" 2>/dev/null)" ]; then
    log_msg INFO "No files in ${LOCAL_PHOTO}; skipping photo upload."
else
    log_msg INFO "Uploading photos from ${LOCAL_PHOTO} to ${RCLONE_REMOTE_NAME}:${RCLONE_BASE_PATH}/photos/"
    rclone copy "${RCLONE_OPTS[@]}" "${LOCAL_PHOTO}" "${RCLONE_REMOTE_NAME}:${RCLONE_BASE_PATH}/photos/"
    RCLONE_P_EXIT=$?
    if [ ${RCLONE_P_EXIT} -ne 0 ]; then
        log_msg ERROR "rclone photo upload failed (exit code ${RCLONE_P_EXIT})."
        UPLOAD_ERRORS=1
    else
         log_msg INFO "Photo upload completed successfully."
    fi
fi

log_msg INFO "Upload phase complete."

FINAL_EXIT_CODE=0
if [ ${COPY_ERRORS} -ne 0 ] || [ ${UPLOAD_ERRORS} -ne 0 ]; then
    log_msg ERROR "Script encountered errors during execution."
    FINAL_EXIT_CODE=1
else
    log_msg INFO "Script executed successfully."
fi

log_msg INFO "=== upload_and_cleanup.sh script finished ==="
echo "--- [$(date)] Script: upload_and_cleanup.sh --- END ---"
exit ${FINAL_EXIT_CODE}
