#!/bin/bash
# safe_eject.sh
# Placeholder script for safely unmounting and/or powering off the SD card reader/port.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
LOG_FILE="${SCRIPT_DIR}/logs/eject.log"
PROJECT_USER="zmakey"
SD_MOUNT="/media/${PROJECT_USER}/SDCARD" # Must match the mount point used

echo "$(date): Safe eject script triggered." >> "${LOG_FILE}"

# --- Add SD card unmounting/ejection logic here ---

# 1. Check if mounted
if mountpoint -q "$SD_MOUNT"; then
  echo "$(date): SD card is mounted at ${SD_MOUNT}. Attempting unmount..." >> "${LOG_FILE}"
  # Try unmounting using udisksctl (preferred, handles underlying device)
  udisksctl unmount -b "$(findmnt -n -o SOURCE --target "$SD_MOUNT")" >> "${LOG_FILE}" 2>&1
  UMOUNT_EXIT_CODE=$?

  if [ $UMOUNT_EXIT_CODE -eq 0 ]; then
    echo "$(date): Unmount successful via udisksctl." >> "${LOG_FILE}"
    # Optional: Power off the drive/port if possible (requires hardware support and tools like uhubctl)
    # echo "$(date): Attempting to power off USB port (example)..." >> "${LOG_FILE}"
    # uhubctl -l <location> -a off >> "${LOG_FILE}" 2>&1
  else
    echo "$(date): udisksctl unmount failed (Code: ${UMOUNT_EXIT_CODE}). Trying umount command..." >> "${LOG_FILE}"
    # Fallback to basic umount (might leave device busy)
    umount "$SD_MOUNT" >> "${LOG_FILE}" 2>&1
    UMOUNT_EXIT_CODE=$?
    if [ $UMOUNT_EXIT_CODE -eq 0 ]; then
        echo "$(date): Unmount successful via umount command." >> "${LOG_FILE}"
    else
         echo "$(date): Error: Failed to unmount ${SD_MOUNT} (Code: ${UMOUNT_EXIT_CODE}). It might be busy." >> "${LOG_FILE}"
         exit 1
    fi
  fi
else
  echo "$(date): SD card not currently mounted at ${SD_MOUNT}. No action taken." >> "${LOG_FILE}"
fi

echo "$(date): Eject process finished." >> "${LOG_FILE}"
exit 0