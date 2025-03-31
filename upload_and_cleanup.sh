#!/bin/bash
# upload_and_cleanup.sh
# Copies files from SD card, uploads via rclone.
# Adapted for user 'zmakey' and project structure.

# --- Configuration ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_USER="zmakey"

# !! CRITICAL: Verify this mount point matches your system !!
# Examples: /media/zmakey/MY_SD_LABEL, /media/zmakey/1234-5678
SD_MOUNT="/media/${PROJECT_USER}/SDCARD" # Default assumption, CHANGE IF NEEDED!

# Source directories on the SD card (relative to SD_MOUNT)
# Adjust these based on your camera's file structure
VIDEO_REL_PATH="PRIVATE/M4ROOT/CLIP"
PHOTO_REL_PATH="DCIM/100MSDCF"

# Local storage directories within the project folder
LOCAL_VIDEO="${SCRIPT_DIR}/footage/videos"
LOCAL_PHOTO="${SCRIPT_DIR}/footage/photos"

# Rclone configuration
RCLONE_CONFIG="${SCRIPT_DIR}/rclone.conf"
RCLONE_REMOTE_NAME="gdrive" # Must match the remote name configured in rclone
RCLONE_BASE_PATH="FX3_Backups" # Base folder on Google Drive

# Log file for rclone operations
RCLONE_LOG="${SCRIPT_DIR}/logs/upload.log" # Renamed from rclone.log for clarity

# Rclone options
RCLONE_OPTS=(
    "--config" "${RCLONE_CONFIG}"
    "--log-level" "INFO" # Or "DEBUG" for more detail
    "--log-file" "${RCLONE_LOG}"
    "--min-age" "1m"      # Don't upload files modified in the last minute (avoids partial copies)
    "--fast-list"         # Use fewer transactions for listing files (good for GDrive)
    "--transfers" "4"     # Number of parallel transfers
    "--checkers" "8"      # Number of parallel checkers
    "--contimeout" "60s"
    "--timeout" "300s"
    "--retries" "3"
    "--low-level-retries" "10"
    # "--bwlimit" "8M"    # Optional: Limit bandwidth to 8 MByte/s
    # "--delete-empty-src-dirs" # Optional: Clean up empty source dirs after copy if local files were moved/deleted
)

# --- Script Start ---
echo "========================================" >> "${RCLONE_LOG}"
echo "$(date): upload_and_cleanup.sh started." >> "${RCLONE_LOG}"

# 0. Check if rclone config exists
if [ ! -f "${RCLONE_CONFIG}" ]; then
  echo "$(date): Error: Rclone config file not found at ${RCLONE_CONFIG}. Cannot upload." >> "${RCLONE_LOG}"
  exit 1
fi

# 1. Check if SD card is mounted
if ! mountpoint -q "$SD_MOUNT"; then
  echo "$(date): SD card is not mounted at ${SD_MOUNT}. Checking if auto-mount helps..." >> "${RCLONE_LOG}"
  # Attempt to trigger udisksctl mount if applicable (may need policykit rules)
  # Find the device corresponding to the potential label SDCARD
  SD_DEVICE=$(lsblk -o NAME,LABEL,MOUNTPOINT | grep 'SDCARD' | awk '{print $1}' | sed 's/^[^a-zA-Z0-9]*//;s/[^a-zA-Z0-9]*$//')
  if [ -n "$SD_DEVICE" ]; then
      echo "$(date): Attempting to mount /dev/${SD_DEVICE}..." >> "${RCLONE_LOG}"
      udisksctl mount -b "/dev/${SD_DEVICE}" >> "${RCLONE_LOG}" 2>&1
      sleep 5 # Give it a moment
      if ! mountpoint -q "$SD_MOUNT"; then
          echo "$(date): Auto-mount attempt failed or device still not at ${SD_MOUNT}. Exiting." >> "${RCLONE_LOG}"
          exit 1
      fi
      echo "$(date): SD card mounted successfully after attempt." >> "${RCLONE_LOG}"
  else
      echo "$(date): Could not identify device for label SDCARD. Cannot attempt mount. Exiting." >> "${RCLONE_LOG}"
      exit 1
  fi
fi
echo "$(date): SD card mounted at ${SD_MOUNT}." >> "${RCLONE_LOG}"


# 2. Ensure local directories exist
mkdir -p "$LOCAL_VIDEO"
mkdir -p "$LOCAL_PHOTO"
echo "$(date): Local directories ensured: ${LOCAL_VIDEO}, ${LOCAL_PHOTO}." >> "${RCLONE_LOG}"

# 3. Define full source paths
VIDEO_SOURCE="${SD_MOUNT}/${VIDEO_REL_PATH}"
PHOTO_SOURCE="${SD_MOUNT}/${PHOTO_REL_PATH}"

# 4. Copy files from SD to local storage (Offload)
# Using rsync for potentially better resuming and error handling
COPY_COUNT=0
ERROR_FLAG=0

if [ -d "$VIDEO_SOURCE" ]; then
  echo "$(date): Copying videos from ${VIDEO_SOURCE} to ${LOCAL_VIDEO}..." >> "${RCLONE_LOG}"
  rsync -av --no-perms --ignore-existing "${VIDEO_SOURCE}/" "${LOCAL_VIDEO}/" >> "${RCLONE_LOG}" 2>&1
  if [ $? -eq 0 ]; then
      VIDEO_COUNT=$(find "${VIDEO_SOURCE}" -maxdepth 1 -type f | wc -l)
      COPY_COUNT=$((COPY_COUNT + VIDEO_COUNT))
      echo "$(date): Video copy finished." >> "${RCLONE_LOG}"
  else
      echo "$(date): Error during video copy (rsync exit code $?). Check log." >> "${RCLONE_LOG}"
      ERROR_FLAG=1
  fi
else
    echo "$(date): Video source directory ${VIDEO_SOURCE} not found. Skipping video copy." >> "${RCLONE_LOG}"
fi

if [ -d "$PHOTO_SOURCE" ]; then
  echo "$(date): Copying photos from ${PHOTO_SOURCE} to ${LOCAL_PHOTO}..." >> "${RCLONE_LOG}"
  rsync -av --no-perms --ignore-existing "${PHOTO_SOURCE}/" "${LOCAL_PHOTO}/" >> "${RCLONE_LOG}" 2>&1
   if [ $? -eq 0 ]; then
      PHOTO_COUNT=$(find "${PHOTO_SOURCE}" -maxdepth 1 -type f | wc -l)
      COPY_COUNT=$((COPY_COUNT + PHOTO_COUNT))
      echo "$(date): Photo copy finished." >> "${RCLONE_LOG}"
  else
      echo "$(date): Error during photo copy (rsync exit code $?). Check log." >> "${RCLONE_LOG}"
      ERROR_FLAG=1
  fi
else
     echo "$(date): Photo source directory ${PHOTO_SOURCE} not found. Skipping photo copy." >> "${RCLONE_LOG}"
fi

echo "$(date): Local copy phase complete. Approx ${COPY_COUNT} files considered (may include existing)." >> "${RCLONE_LOG}"

# Optional: Check if copy actually copied anything before proceeding?

# 5. Upload files from local storage to Google Drive (Upload)
echo "$(date): Starting upload from local storage to Google Drive (${RCLONE_REMOTE_NAME}:${RCLONE_BASE_PATH})..." >> "${RCLONE_LOG}"

# Upload Videos
if [ "$(ls -A ${LOCAL_VIDEO})" ]; then # Check if directory is not empty
    echo "$(date): Uploading videos from ${LOCAL_VIDEO}..." >> "${RCLONE_LOG}"
    rclone copy "${RCLONE_OPTS[@]}" "$LOCAL_VIDEO" "${RCLONE_REMOTE_NAME}:${RCLONE_BASE_PATH}/videos/"
    if [ $? -ne 0 ]; then echo "$(date): Warning: rclone reported errors during video upload. Check log." >> "${RCLONE_LOG}"; ERROR_FLAG=1; fi
else
    echo "$(date): Local video directory is empty. Skipping video upload." >> "${RCLONE_LOG}"
fi

# Upload Photos
if [ "$(ls -A ${LOCAL_PHOTO})" ]; then # Check if directory is not empty
    echo "$(date): Uploading photos from ${LOCAL_PHOTO}..." >> "${RCLONE_LOG}"
    rclone copy "${RCLONE_OPTS[@]}" "$LOCAL_PHOTO" "${RCLONE_REMOTE_NAME}:${RCLONE_BASE_PATH}/photos/"
    if [ $? -ne 0 ]; then echo "$(date): Warning: rclone reported errors during photo upload. Check log." >> "${RCLONE_LOG}"; ERROR_FLAG=1; fi
else
     echo "$(date): Local photo directory is empty. Skipping photo upload." >> "${RCLONE_LOG}"
fi

echo "$(date): Upload phase complete." >> "${RCLONE_LOG}"


# 6. Optional Cleanup: Delete files from SD card AFTER successful copy/upload
# WARNING: Uncomment VERY carefully. Ensure copy/upload works reliably first.
# Consider using `rclone move` directly from SD if network is reliable and local copy isn't needed.
# if [ ${ERROR_FLAG} -eq 0 ]; then
#   echo "$(date): Cleanup phase: Removing files from SD card (if directories exist)..." >> "${RCLONE_LOG}"
#   if [ -d "$VIDEO_SOURCE" ]; then
#       echo "$(date): Removing files from ${VIDEO_SOURCE}/*" >> "${RCLONE_LOG}"
#       rm -rf "${VIDEO_SOURCE:?}"/* # Safety: :? prevents accidental rm -rf /
#   fi
#   if [ -d "$PHOTO_SOURCE" ]; then
#       echo "$(date): Removing files from ${PHOTO_SOURCE}/*" >> "${RCLONE_LOG}"
#       rm -rf "${PHOTO_SOURCE:?}"/*
#   fi
#   echo "$(date): SD card cleanup finished." >> "${RCLONE_LOG}"
# else
#    echo "$(date): Skipping cleanup due to errors during copy or upload." >> "${RCLONE_LOG}"
# fi

# 7. Optional Cleanup: Delete successfully uploaded files from local storage
# This saves space on the Pi's SD card.
# Use `rclone delete --min-age 7d ...` or similar logic based on upload success.
# Example: Delete local files older than 1 hour after attempting upload
# echo "$(date): Local cleanup: Deleting successfully uploaded files (older than 1h) from local storage..." >> "${RCLONE_LOG}"
# find "${LOCAL_VIDEO}" -maxdepth 1 -type f -mmin +60 -exec rm {} \; >> "${RCLONE_LOG}" 2>&1
# find "${LOCAL_PHOTO}" -maxdepth 1 -type f -mmin +60 -exec rm {} \; >> "${RCLONE_LOG}" 2>&1
# echo "$(date): Local cleanup finished." >> "${RCLONE_LOG}"
# A more robust way is to use `rclone check` or parse logs to confirm upload before deleting.

echo "$(date): upload_and_cleanup.sh finished." >> "${RCLONE_LOG}"
echo "========================================" >> "${RCLONE_LOG}"

exit ${ERROR_FLAG} # Exit with 0 if no errors, 1 otherwise