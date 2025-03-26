#!/bin/bash
SRC_DIR="/home/pi/footage"
REMOTE="gdrive:/FX3_Backups"
LOGFILE="/home/pi/rclone.log"

HOSTS=("google.com" "cloudflare.com")
CONNECTED=false
for host in "${HOSTS[@]}"; do
    if ping -c 1 "$host" &> /dev/null; then
        CONNECTED=true
        break
    fi
done

if [ "$CONNECTED" = true ]; then
    rclone copy "$SRC_DIR/videos" "$REMOTE/videos" --log-file="$LOGFILE" --log-level INFO --progress
    rclone copy "$SRC_DIR/photos" "$REMOTE/photos" --log-file="$LOGFILE" --log-level INFO --progress

    if [ $? -eq 0 ]; then
        rm -rf "$SRC_DIR/videos"/* "$SRC_DIR/photos"/*
        echo "Upload successful. Files deleted." >> "$LOGFILE"
    else
        echo "Upload failed." >> "$LOGFILE"
        python3 /home/pi/send_notification.py "Upload Failure" "Upload failed on $(hostname) at $(date). Please check logs."
    fi
else
    echo "No internet. Skipping upload." >> "$LOGFILE"
fi
