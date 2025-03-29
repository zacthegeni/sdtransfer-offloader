#!/bin/bash
# upload_and_cleanup.sh
# This script copies files from the SD card to local storage,
# and then uploads them to Google Drive using rclone.

# Define paths:
SD_MOUNT="/media/pi/SDCARD"
VIDEO_SOURCE="${SD_MOUNT}/PRIVATE/M4ROOT/CLIP"
PHOTO_SOURCE="${SD_MOUNT}/DCIM/100MSDCF"
LOCAL_VIDEO="/home/pi/footage/videos"
LOCAL_PHOTO="/home/pi/footage/photos"

# Ensure the SD card is mounted
if ! mountpoint -q "$SD_MOUNT"; then
  echo "SD card is not mounted at $SD_MOUNT. Exiting."
  exit 1
fi

# Ensure local directories exist
mkdir -p "$LOCAL_VIDEO" "$LOCAL_PHOTO"

# Copy videos and photos if source directories exist
if [ -d "$VIDEO_SOURCE" ]; then
  cp -r "$VIDEO_SOURCE"/* "$LOCAL_VIDEO"
fi

if [ -d "$PHOTO_SOURCE" ]; then
  cp -r "$PHOTO_SOURCE"/* "$LOCAL_PHOTO"
fi

# Upload to Google Drive (assumes rclone remote named 'gdrive' is configured)
# --min-age 1m avoids copying files that are still being written
rclone copy "$LOCAL_VIDEO" "gdrive:/FX3_Backups/videos/" --min-age 1m --log-file /home/pi/rclone.log
rclone copy "$LOCAL_PHOTO" "gdrive:/FX3_Backups/photos/" --min-age 1m --log-file /home/pi/rclone.log

# Optional: Remove files from SD card after successful upload.
# Uncomment the lines below if you are sure you want to delete them.
# rm -rf "$VIDEO_SOURCE"/*
# rm -rf "$PHOTO_SOURCE"/*
