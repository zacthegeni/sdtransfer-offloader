#!/bin/bash
# offload.sh
# Wrapper script that calls upload_and_cleanup.sh
# Ensures it runs from the script's directory for relative paths if needed.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
UPLOAD_SCRIPT="${SCRIPT_DIR}/upload_and_cleanup.sh"
LOG_FILE="${SCRIPT_DIR}/logs/offload.log" # Log wrapper activity

echo "--------------------" >> "${LOG_FILE}"
echo "$(date): Offload script triggered." >> "${LOG_FILE}"

if [ -f "$UPLOAD_SCRIPT" ]; then
  echo "$(date): Executing ${UPLOAD_SCRIPT}..." >> "${LOG_FILE}"
  # Execute the main script, its output will go to its own log (rclone.log)
  bash "$UPLOAD_SCRIPT"
  EXIT_CODE=$?
  echo "$(date): ${UPLOAD_SCRIPT} finished with exit code ${EXIT_CODE}." >> "${LOG_FILE}"
  exit ${EXIT_CODE}
else
  echo "$(date): Error: Upload script not found at ${UPLOAD_SCRIPT}" >> "${LOG_FILE}"
  exit 1
fi