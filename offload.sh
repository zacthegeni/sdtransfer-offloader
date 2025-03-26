#!/bin/bash
# Load parameters from .env if available
if [ -f /home/pi/pi-offloader/.env ]; then
    export $(grep -v '^#' /home/pi/pi-offloader/.env | xargs)
fi

MOUNT_POINT="/media/pi/SDCARD"
DEST_DIR="/home/pi/footage"
LOGFILE="/home/pi/offload.log"
MIN_FREE_SPACE_MB="${MIN_FREE_SPACE_MB:-1024}"
VIDEO_SRC="$MOUNT_POINT/PRIVATE/M4ROOT/CLIP"
PHOTO_SRC="$MOUNT_POINT/DCIM/100MSDCF"
VIDEO_DEST="$DEST_DIR/videos"
PHOTO_DEST="$DEST_DIR/photos"

if [ ! -d "$MOUNT_POINT" ]; then
    echo "Mount point $MOUNT_POINT not found. Is the SD card mounted?" >> "$LOGFILE"
    exit 1
fi

mkdir -p "$VIDEO_DEST" "$PHOTO_DEST"
echo -e "\n[$(date)] Checking SD card..." >> "$LOGFILE"

FREE_SPACE=$(df --output=avail "$DEST_DIR" | tail -n1)
FREE_SPACE_MB=$((FREE_SPACE / 1024))

if [ "$FREE_SPACE_MB" -lt "$MIN_FREE_SPACE_MB" ]; then
    echo "Not enough space. Skipping offload." >> "$LOGFILE"
    exit 1
fi

if [ -d "$VIDEO_SRC" ] || [ -d "$PHOTO_SRC" ]; then
    [ -d "$VIDEO_SRC" ] && rsync -av --remove-source-files "$VIDEO_SRC/" "$VIDEO_DEST/" >> "$LOGFILE"
    [ -d "$PHOTO_SRC" ] && rsync -av --remove-source-files "$PHOTO_SRC/" "$PHOTO_DEST/" >> "$LOGFILE"
    echo "Transfer complete." >> "$LOGFILE"
else
    echo "No FX3 folders found." >> "$LOGFILE"
fi
