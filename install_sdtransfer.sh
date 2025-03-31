#!/bin/bash
# install_sdtransfer.sh
# One-Click Installer for SDTransfer Offloader
# Adapted for user 'zmakey', uses Python virtual environment.

set -e # Exit immediately if any command fails
export DEBIAN_FRONTEND=noninteractive # Avoid prompts during installations

# --- Configuration ---
PROJECT_USER="zmakey"
PROJECT_HOME="/home/${PROJECT_USER}"
PROJECT_DIR="${PROJECT_HOME}/sdtransfer-offloader"
PYTHON_EXECUTABLE="/usr/bin/python3" # System Python 3

# --- Script Start ---
echo "SDTransfer Offloader Installer for user '${PROJECT_USER}'"
echo "Project Directory: ${PROJECT_DIR}"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run with sudo." >&2
  echo "Please run: sudo bash ${PROJECT_DIR}/install_sdtransfer.sh" >&2
  exit 1
fi

# Check if the project directory exists
if [ ! -d "${PROJECT_DIR}" ]; then
    echo "ERROR: Project directory ${PROJECT_DIR} not found." >&2
    echo "Please ensure you cloned the repository correctly before running this script." >&2
    exit 1
fi

echo "Step 1: Updating system package list..."
apt update

echo "Step 2: Upgrading existing packages (this may take a while)..."
apt upgrade -y

echo "Step 3: Installing required system packages..."
# Install core dependencies. python3-venv is crucial.
# Removed python3-flask as it's installed via pip in venv.
apt install -y git curl unzip python3-pip python3-venv nginx rclone
# Clean up unused dependencies afterwards (optional but good practice)
echo "Step 3a: Removing unused automatically installed packages..."
apt autoremove -y

echo "Step 4: Setting up Python virtual environment ('venv')..."
# Create venv owned by the project user
sudo -u "${PROJECT_USER}" ${PYTHON_EXECUTABLE} -m venv "${PROJECT_DIR}/venv"
echo "Virtual environment created at ${PROJECT_DIR}/venv"

echo "Step 5: Installing Python packages into the virtual environment..."
# Activate venv, upgrade pip, install requirements, deactivate
source "${PROJECT_DIR}/venv/bin/activate"
pip install --upgrade pip
pip install flask Flask-HTTPAuth python-dotenv gunicorn psutil
deactivate
echo "Python packages installed successfully in venv."

# Define Gunicorn executable path *after* venv creation
GUNICORN_EXECUTABLE="${PROJECT_DIR}/venv/bin/gunicorn"
if [ ! -x "${GUNICORN_EXECUTABLE}" ]; then
    echo "ERROR: Gunicorn executable not found or not executable in venv: ${GUNICORN_EXECUTABLE}" >&2
    exit 1
fi

echo "Step 6: Checking/Installing rclone..."
if ! command -v rclone &> /dev/null; then
    echo "Installing rclone (system package failed? trying curl method)..."
    curl https://rclone.org/install.sh | bash
else
    echo "rclone is already installed."
fi

# Rclone Configuration Prompt & Check
RCLONE_CONFIG_FILE="${PROJECT_DIR}/rclone.conf"
echo "---------------------------------------------------------------------"
echo "Step 7: Rclone Configuration Reminder"
echo "---------------------------------------------------------------------"
echo "If you haven't configured rclone for Google Drive yet:"
echo "1. Run the following command in a SEPARATE terminal"
echo "   AS THE '${PROJECT_USER}' USER (not root):"
echo ""
echo "     rclone config --config \"${RCLONE_CONFIG_FILE}\""
echo ""
echo "2. Follow the prompts:"
echo "   - Create a new remote ('n')."
echo "   - Name it exactly: 'gdrive'."
echo "   - Choose 'Drive' (Google Drive)."
echo "   - Leave client_id, client_secret, root_folder_id, service_account_file blank (press Enter)."
echo "   - Choose scope '1' (Full access)."
echo "   - Answer 'N' to advanced config."
echo "   - Answer 'N' to auto config (web UI will handle token)."
echo "   - Confirm ('y') and quit ('q')."
echo "---------------------------------------------------------------------"
read -p "Press Enter to continue once rclone is minimally configured OR if you will configure it via the Web UI..."

# Check if config file exists after prompt (user might have created it)
if [ ! -f "${RCLONE_CONFIG_FILE}" ]; then
     echo "Warning: Rclone config file '${RCLONE_CONFIG_FILE}' still not found."
     echo "You MUST configure Google Drive via the Web UI's 'Drive Auth' page later."
     # Create an empty file so the app doesn't crash trying to read it later maybe?
     # touch "${RCLONE_CONFIG_FILE}"
     # chown "${PROJECT_USER}:${PROJECT_USER}" "${RCLONE_CONFIG_FILE}"
     # Decided against creating empty file, UI should handle absence better.
else
    echo "Rclone config file found at ${RCLONE_CONFIG_FILE}."
    # Ensure config file has correct owner if user created it as root accidentally
    chown "${PROJECT_USER}:${PROJECT_USER}" "${RCLONE_CONFIG_FILE}"
fi


echo "Step 8: Setting up project directories..."
# Ensure directories exist and have correct owner
sudo -u "${PROJECT_USER}" mkdir -p "${PROJECT_DIR}/templates"
sudo -u "${PROJECT_USER}" mkdir -p "${PROJECT_DIR}/static"
sudo -u "${PROJECT_USER}" mkdir -p "${PROJECT_DIR}/footage/videos"
sudo -u "${PROJECT_USER}" mkdir -p "${PROJECT_DIR}/footage/photos"
sudo -u "${PROJECT_USER}" mkdir -p "${PROJECT_DIR}/config_backups"
sudo -u "${PROJECT_USER}" mkdir -p "${PROJECT_DIR}/logs"
echo "Directories ensured."

echo "Step 9: Setting ownership and permissions..."
# Set ownership of the entire project directory to the specified user
# Do this AFTER creating dirs and installing venv
chown -R "${PROJECT_USER}:${PROJECT_USER}" "${PROJECT_DIR}"

# Make shell scripts executable by the owner
find "${PROJECT_DIR}" -maxdepth 1 -name "*.sh" -exec chmod u+x {} \;
# Make optional python script executable if it exists
if [ -f "${PROJECT_DIR}/send_notification.py" ]; then
    chmod u+x "${PROJECT_DIR}/send_notification.py"
    chown "${PROJECT_USER}:${PROJECT_USER}" "${PROJECT_DIR}/send_notification.py"
fi
echo "Permissions set."

echo "Step 10: Setting up systemd service for Gunicorn (pi-gunicorn.service)..."
# Create Gunicorn service file
cat > /etc/systemd/system/pi-gunicorn.service <<EOF
[Unit]
Description=Gunicorn instance to serve SDTransfer Offloader
After=network.target

[Service]
User=${PROJECT_USER}
# Optional: Group=www-data might be needed if using Unix sockets later
# Group=www-data
WorkingDirectory=${PROJECT_DIR}
# ExecStart must use the Gunicorn from the virtual environment
ExecStart=${GUNICORN_EXECUTABLE} --workers 3 --bind 127.0.0.1:5000 app:app
Restart=always
RestartSec=3
# Log Gunicorn output to the project's log directory (ensure it's writable by User)
StandardOutput=append:${PROJECT_DIR}/logs/gunicorn.log
StandardError=append:${PROJECT_DIR}/logs/gunicorn.error.log

[Install]
WantedBy=multi-user.target
EOF
echo "Systemd service file created."

echo "Step 11: Reloading systemd, enabling and starting Gunicorn service..."
systemctl daemon-reload
systemctl enable pi-gunicorn
systemctl restart pi-gunicorn

# Add a check to see if the service started correctly
sleep 5 # Give the service a moment to start or fail
if ! systemctl is-active --quiet pi-gunicorn; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
    echo "ERROR: Gunicorn service (pi-gunicorn.service) failed to start." >&2
    echo "Please check the logs for errors:" >&2
    echo "  systemctl status pi-gunicorn.service" >&2
    echo "  sudo journalctl -u pi-gunicorn.service -n 50" >&2
    echo "  cat ${PROJECT_DIR}/logs/gunicorn.error.log" >&2
    echo "Installation cannot continue reliably." >&2
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
    exit 1
fi
echo "Gunicorn service started successfully."

echo "Step 12: Configuring Nginx as a reverse proxy..."
# Create Nginx config file for the site
cat > /etc/nginx/sites-available/sdtransfer <<EOF
server {
    listen 80;
    server_name _; # Listen on all hostnames

    # Pass requests to the Gunicorn server
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
        proxy_redirect off;
    }

    # Serve static files directly via Nginx for better performance
    location /static {
        alias ${PROJECT_DIR}/static;
        expires 30d;
        access_log off;
    }
}
EOF

echo "Step 13: Enabling Nginx site configuration..."
# Remove default site if it exists and conflicts
rm -f /etc/nginx/sites-enabled/default
# Create symbolic link
ln -sf /etc/nginx/sites-available/sdtransfer /etc/nginx/sites-enabled/

echo "Step 14: Testing Nginx configuration..."
if ! nginx -t; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
    echo "ERROR: Nginx configuration test failed." >&2
    echo "Please check Nginx configuration files and logs (/var/log/nginx/error.log)." >&2
    echo "Installation cannot continue reliably." >&2
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
    exit 1
fi
echo "Nginx configuration test successful."

echo "Step 15: Restarting Nginx service..."
systemctl restart nginx
echo "Nginx restarted."

echo "Step 16: Setting up cron jobs for user '${PROJECT_USER}'..."
# Use direct pipe method to avoid temp file permission issues when run as root
( \
    crontab -u "${PROJECT_USER}" -l 2>/dev/null | \
    grep -vF "${PROJECT_DIR}/offload.sh" | \
    grep -vF "${PROJECT_DIR}/upload_and_cleanup.sh" ; \
    echo "@reboot sleep 60 && bash ${PROJECT_DIR}/offload.sh >> ${PROJECT_DIR}/logs/cron_offload.log 2>&1" ; \
    echo "0 2 * * * bash ${PROJECT_DIR}/upload_and_cleanup.sh >> ${PROJECT_DIR}/logs/cron_upload.log 2>&1" \
) | crontab -u "${PROJECT_USER}" -

echo "Cron jobs updated for user '${PROJECT_USER}'."

echo "---------------------------------------------------------------------"
echo "Installation Script Finished!"
echo "---------------------------------------------------------------------"
echo "The Flask application should be running via Gunicorn and proxied by Nginx."
echo ""
echo "Access the web UI at: http://<your_pi_ip_address>/"
echo "(Note: It's now on port 80, not 5000 externally)"
echo ""
echo "Next Steps:"
echo "1. Access the web UI in your browser."
echo "2. Set your Admin Username and Password via the '/credentials' page."
echo "3. Configure Google Drive Authentication via the '/drive_auth' page"
echo "   (if the rclone config file wasn't found or fully configured)."
echo "4. IMPORTANT: Verify/Edit the SD Card Mount Point in the script:"
echo "   sudo nano ${PROJECT_DIR}/upload_and_cleanup.sh"
echo "   (Check the 'SD_MOUNT' variable matches your system when SD card is inserted)."
echo "5. IMPORTANT: Verify Camera File Structure variables ('VIDEO_REL_PATH',"
echo "   'PHOTO_REL_PATH') in '${PROJECT_DIR}/upload_and_cleanup.sh'."
echo "6. (Recommended) Set a secure FLASK_SECRET_KEY in '${PROJECT_DIR}/.env'."
echo "   Example: Add 'FLASK_SECRET_KEY=$(python3 -c 'import secrets; print(secrets.token_hex(24))')' to .env"
echo "   Then run 'sudo systemctl restart pi-gunicorn'."
echo "7. Configure Email Notifications via the '/notifications' page (optional)."
echo ""
echo "Troubleshooting:"
echo "- Gunicorn service: 'systemctl status pi-gunicorn.service'"
echo "- Gunicorn logs: '${PROJECT_DIR}/logs/gunicorn.error.log', '${PROJECT_DIR}/logs/gunicorn.log'"
echo "- Nginx service: 'systemctl status nginx.service'"
echo "- Nginx logs: '/var/log/nginx/error.log', '/var/log/nginx/access.log'"
echo "- Cron job logs: '${PROJECT_DIR}/logs/cron_*.log'"
echo "---------------------------------------------------------------------"

exit 0