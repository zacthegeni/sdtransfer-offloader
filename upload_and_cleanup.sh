#!/bin/bash
# upload_and_cleanup.sh
# This script copies files from the SD card to local storage and then uploads them to Google Drive using rclone.
# Adjust the paths as needed.

# Define paths:
SD_MOUNT="/media/pi/SDCARD"
VIDEO_SOURCE="${SD_MOUNT}/PRIVATE/M4ROOT/CLIP"
PHOTO_SOURCE="${SD_MOUNT}/DCIM/100MSDCF"
LOCAL_VIDEO="/home/pi/footage/videos"
LOCAL_PHOTO="/home/pi/footage/photos"

# Copy videos and photos from SD card to local storage:
cp -r "$VIDEO_SOURCE"/* "$LOCAL_VIDEO"
cp -r "$PHOTO_SOURCE"/* "$LOCAL_PHOTO"

# Upload to Google Drive (assumes rclone remote named 'gdrive' is configured)
rclone copy "$LOCAL_VIDEO" "gdrive:/FX3_Backups/videos/" --min-age 1m --log-file /home/pi/rclone.log
rclone copy "$LOCAL_PHOTO" "gdrive:/FX3_Backups/photos/" --min-age 1m --log-file /home/pi/rclone.log

# Optional: Delete files from SD card after successful upload (uncomment if desired)
# rm -rf "$VIDEO_SOURCE"/*
# rm -rf "$PHOTO_SOURCE"/*
