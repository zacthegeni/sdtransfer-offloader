#!/bin/bash
# /home/pi/pi-offloader/offload.sh
# Wrapper script to run upload_and_cleanup.sh
# Ensures environment variables from .env are loaded

SCRIPT_DIR=$(dirname "$(realpath "$0")")
ENV_FILE="$SCRIPT_DIR/.env"
UPLOAD_SCRIPT="$SCRIPT_DIR/upload_and_cleanup.sh"
LOG_FILE_WRAPPER="$SCRIPT_DIR/logs/offload_wrapper.log" # Log for this wrapper

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE_WRAPPER")"

echo "-------------------------------------" >> "$LOG_FILE_WRAPPER"
echo "Offload Wrapper Started: $(date)" >> "$LOG_FILE_WRAPPER"

# Source environment variables from .env file if it exists
if [ -f "$ENV_FILE" ]; then
  echo "Loading environment variables from $ENV_FILE" >> "$LOG_FILE_WRAPPER"
  # Use 'set -a' to export all variables defined in the sourced file
  set -a
  # Use process substitution to avoid subshell issues with variable scope if needed
  # source <(grep -v '^#' "$ENV_FILE" | grep -v '^$' )
  # Simpler source usually works if scripts don't modify parent env vars
  source "$ENV_FILE"
  set +a
else
  echo "Error: Environment file $ENV_FILE not found." >> "$LOG_FILE_WRAPPER"
  # Optionally try to notify Flask app about this critical error
  # (Requires curl, jq, token, and app running)
  exit 1
fi

# Check if the main upload script exists and is executable
if [ -x "$UPLOAD_SCRIPT" ]; then
  echo "Executing $UPLOAD_SCRIPT" >> "$LOG_FILE_WRAPPER"
  # Execute the main script. It handles its own logging & notifications
  # Redirect script's stdout/stderr to the wrapper log for debugging script execution issues
  bash "$UPLOAD_SCRIPT" >> "$LOG_FILE_WRAPPER" 2>&1
  EXIT_CODE=$?
  echo "Upload script finished with exit code: $EXIT_CODE" >> "$LOG_FILE_WRAPPER"
  # Don't exit wrapper with error unless script failed critically
  # exit $EXIT_CODE
else
  echo "Error: Upload script $UPLOAD_SCRIPT not found or not executable." >> "$LOG_FILE_WRAPPER"
  # Notify Flask app
  exit 1
fi

echo "Offload Wrapper Finished: $(date)" >> "$LOG_FILE_WRAPPER"
echo "-------------------------------------" >> "$LOG_FILE_WRAPPER"
exit 0 # Wrapper itself succeeded in calling the script