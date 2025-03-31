#!/bin/bash
# install_sdtransfer.sh
# One-Click Installer for SDTransfer Offloader
# Adapted for user 'zmakey', project directory '/home/zmakey/sdtransfer-offloader'
# Includes Python Virtual Environment setup (PEP 668 fix)

set -e # Exit immediately if any command fails
export DEBIAN_FRONTEND=noninteractive # Avoid prompts during installations

# --- Configuration ---
PROJECT_USER="zmakey"
PROJECT_DIR="/home/${PROJECT_USER}/sdtransfer-offloader"
PYTHON_EXECUTABLE="/usr/bin/python3"
# Gunicorn will be installed inside the virtual environment
GUNICORN_EXECUTABLE="${PROJECT_DIR}/venv/bin/gunicorn"
VENV_DIR="${PROJECT_DIR}/venv"

# --- Script Start ---
echo "SDTransfer Offloader Installer for user '${PROJECT_USER}'"
echo "Project Directory: ${PROJECT_DIR}"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run with sudo. Please run 'sudo bash ${PROJECT_DIR}/install_sdtransfer.sh'" >&2
  exit 1
fi

# Check if the project directory exists (it should, if run from there)
if [ ! -d "${PROJECT_DIR}" ]; then
    echo "Error: Project directory ${PROJECT_DIR} not found." >&2
    echo "Please ensure you are running this script from within the cloned directory." >&2
    exit 1
fi

echo "Updating system package list..."
apt update

echo "Upgrading existing packages (this may take a while)..."
# apt upgrade -y # Optionally skip this for faster install, run manually later

echo "Installing required system packages..."
# Added python3-venv for virtual environment support
apt install -y git curl unzip python3-pip python3-venv python3-flask nginx rclone
# Removed the bad 'ps aux | grep...' part from here

echo "Setting up project directories..."
mkdir -p "${PROJECT_DIR}/templates"
mkdir -p "${PROJECT_DIR}/static"
mkdir -p "${PROJECT_DIR}/footage/videos" # Subdirs for local storage
mkdir -p "${PROJECT_DIR}/footage/photos"
mkdir -p "${PROJECT_DIR}/config_backups"
mkdir -p "${PROJECT_DIR}/logs" # Specific directory for logs

echo "Setting initial ownership (before venv creation)..."
chown -R "${PROJECT_USER}:${PROJECT_USER}" "${PROJECT_DIR}"

# --- Python Virtual Environment Setup ---
echo "Creating Python virtual environment at ${VENV_DIR}..."
# Run python3 -m venv as the target user to avoid permission issues later
sudo -u "${PROJECT_USER}" ${PYTHON_EXECUTABLE} -m venv "${VENV_DIR}"

echo "Activating virtual environment and installing Python packages..."
# Activate venv, install packages, then deactivate
# Note: Activation is only for this subshell block
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip
pip install flask Flask-HTTPAuth python-dotenv gunicorn psutil
deactivate
echo "Python packages installed in virtual environment."
# --- End Virtual Environment Setup ---

echo "Checking if rclone is installed..."
if ! command -v rclone &> /dev/null; then
    echo "Installing rclone..."
    # The apt install above should handle this now, but keep check just in case
    curl https://rclone.org/install.sh | bash
else
    echo "rclone already installed via apt or previously."
fi

# Manual Rclone Configuration Reminder (Keep this section)
echo "---------------------------------------------------------------------"
echo "IMPORTANT: Rclone Configuration Needed!"
echo "---------------------------------------------------------------------"
echo "You need to configure rclone manually if you haven't already."
echo "Run the following command AS THE '${PROJECT_USER}' USER (not root):"
echo ""
echo "  rclone config --config \"${PROJECT_DIR}/rclone.conf\""
echo ""
echo "Follow the prompts to add a Google Drive remote. Make sure to:"
echo "1. Name the remote 'gdrive'."
echo "2. Complete the OAuth process in your browser OR via the Web UI later."
echo "3. Confirm saving the configuration to '${PROJECT_DIR}/rclone.conf'."
echo "---------------------------------------------------------------------"
read -p "Press Enter to continue after you have configured rclone (or if already done)..."

# Re-verify rclone config file location
RCLONE_CONFIG_FILE="${PROJECT_DIR}/rclone.conf"
if [ ! -f "${RCLONE_CONFIG_FILE}" ]; then
     echo "Warning: Rclone config file '${RCLONE_CONFIG_FILE}' not found."
     echo "The web application might not be able to authenticate with Google Drive until configured via CLI or Web UI."
    # Removed the pause here as the Web UI can handle it later
fi

echo "Setting final permissions and script executability..."
# Ensure user owns everything again, including venv content
chown -R "${PROJECT_USER}:${PROJECT_USER}" "${PROJECT_DIR}"

# Make shell scripts executable by the owner
find "${PROJECT_DIR}" -maxdepth 1 -name "*.sh" -exec chmod u+x {} \;
# Make optional python script executable if it exists
if [ -f "${PROJECT_DIR}/send_notification.py" ]; then
    chmod u+x "${PROJECT_DIR}/send_notification.py"
fi

echo "Setting up systemd service for Gunicorn (pi-gunicorn.service)..."
# Ensure Gunicorn path inside venv exists and is executable
if [ ! -x "${GUNICORN_EXECUTABLE}" ]; then
    echo "Error: Gunicorn not found or not executable at expected venv path: ${GUNICORN_EXECUTABLE}" >&2
    echo "Check if the virtual environment setup and package installation succeeded." >&2
    exit 1
fi
echo "Using Gunicorn from: ${GUNICORN_EXECUTABLE}"

# Create Gunicorn service file
# Using explicit paths with variables resolved *before* writing the file
cat > /etc/systemd/system/pi-gunicorn.service <<EOF
[Unit]
Description=Gunicorn instance to serve SDTransfer Offloader
# BindsTo=network.target # More specific than After sometimes
After=network.target

[Service]
User=${PROJECT_USER}
Group=www-data # Nginx user, good for socket permissions if using Unix sockets later
WorkingDirectory=${PROJECT_DIR}
# Ensure the ExecStart uses the Gunicorn from the virtual environment
ExecStart=${GUNICORN_EXECUTABLE} --workers 3 --bind 127.0.0.1:5000 app:app
Restart=always
RestartSec=3
# Log Gunicorn output to the project's log directory
StandardOutput=append:${PROJECT_DIR}/logs/gunicorn.log
StandardError=append:${PROJECT_DIR}/logs/gunicorn.error.log

[Install]
WantedBy=multi-user.target
EOF

echo "Reloading systemd daemon, enabling and starting Gunicorn service..."
systemctl daemon-reload
systemctl enable pi-gunicorn
# Use restart; if the file was bad before, this ensures it re-reads the fixed one
systemctl restart pi-gunicorn

# Check status immediately after trying to restart
sleep 2 # Give it a moment to try starting
if systemctl is-active --quiet pi-gunicorn; then
    echo "Gunicorn service started successfully."
else
    echo "Error: Gunicorn service failed to start." >&2
    echo "Run 'systemctl status pi-gunicorn.service' and 'sudo journalctl -u pi-gunicorn.service' for details." >&2
    # Decide if you want to exit here or continue with Nginx setup
    # exit 1 # Optional: Stop if Gunicorn fails
fi


echo "Configuring Nginx as a reverse proxy..."
# Create Nginx config file
cat > /etc/nginx/sites-available/sdtransfer <<EOF
server {
    listen 80 default_server; # Make this the default server for IP access
    listen [::]:80 default_server;
    server_name _; # Listen on all hostnames

    # Increase max body size if needed later for uploads via web UI
    # client_max_body_size 100M;

    # Root path for server (optional, good practice)
    root ${PROJECT_DIR}; # Or /var/www/html if preferred

    location / {
        # Pass requests to the Gunicorn server running on localhost:5000
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Recommended proxy settings
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
        proxy_redirect off;
    }

    # Serve static files directly via Nginx for performance
    location /static/ { # Added trailing slash for consistency
        alias ${PROJECT_DIR}/static/; # Added trailing slash
        expires 30d;
        add_header Cache-Control "public";
        access_log off;
    }

    # Optional: Deny access to hidden files (like .env) if served from project root
    location ~ /\. {
        deny all;
    }
}
EOF

echo "Enabling Nginx site configuration..."
# Remove default site if it exists and conflicts
rm -f /etc/nginx/sites-enabled/default
# Create symbolic link (use -f to force overwrite if link exists)
ln -sf /etc/nginx/sites-available/sdtransfer /etc/nginx/sites-enabled/

echo "Testing Nginx configuration..."
if ! nginx -t; then
    echo "Error: Nginx configuration test failed. Please check Nginx logs ('sudo journalctl -u nginx' or /var/log/nginx/error.log)." >&2
    # Optionally stop here: exit 1
fi

echo "Restarting Nginx service..."
systemctl restart nginx

echo "Setting up cron jobs for user '${PROJECT_USER}'..."
# Use temporary file for safer crontab update
CRON_TEMP_FILE=$(mktemp)
# Get current crontab or empty if none, ensuring correct user context
sudo -u "${PROJECT_USER}" crontab -l > "${CRON_TEMP_FILE}" 2>/dev/null || true

# Define cron log files
CRON_OFFLOAD_LOG="${PROJECT_DIR}/logs/cron_offload.log"
CRON_UPLOAD_LOG="${PROJECT_DIR}/logs/cron_upload.log"

# Add/Update offload on reboot (with delay)
# Remove existing line first to avoid duplicates
sed -i '\%@reboot.*offload.sh%d' "${CRON_TEMP_FILE}"
echo "@reboot sleep 60 && bash ${PROJECT_DIR}/offload.sh >> ${CRON_OFFLOAD_LOG} 2>&1" >> "${CRON_TEMP_FILE}"

# Add/Update daily upload (e.g., at 2 AM)
# Remove existing line first
sed -i '\%upload_and_cleanup.sh%d' "${CRON_TEMP_FILE}"
echo "0 2 * * * bash ${PROJECT_DIR}/upload_and_cleanup.sh >> ${CRON_UPLOAD_LOG} 2>&1" >> "${CRON_TEMP_FILE}"

# Install the modified crontab for the specific user
sudo -u "${PROJECT_USER}" crontab "${CRON_TEMP_FILE}"
rm "${CRON_TEMP_FILE}"
echo "Cron jobs updated for user ${PROJECT_USER}."

echo "---------------------------------------------------------------------"
echo "One-Click Installer Finished!"
echo "---------------------------------------------------------------------"
echo "The Flask application should be running via Gunicorn (from venv) and proxied by Nginx."
echo "Access the web UI at: http://<your_pi_ip_address>/"
echo "(Note: It's on port 80, not 5000 externally)"
echo ""
echo "Next Steps:"
echo "1. Access the web UI in your browser."
echo "2. Set your Admin Username and Password via the '/credentials' page."
echo "3. Configure Google Drive Authentication via the '/drive_auth' page."
echo "4. Verify the SD Card Mount Point in '${PROJECT_DIR}/upload_and_cleanup.sh'."
echo "5. Optionally configure Email Notifications via the '/notifications' page."
echo ""
echo "Troubleshooting:"
echo "- Check Gunicorn status: 'systemctl status pi-gunicorn.service'"
echo "- Check Gunicorn logs: '${PROJECT_DIR}/logs/gunicorn.*.log'"
echo "- Check Nginx status: 'systemctl status nginx.service'"
echo "- Check Nginx logs: '/var/log/nginx/error.log' or 'sudo journalctl -u nginx'"
echo "- Check Cron job logs: '${PROJECT_DIR}/logs/cron_*.log'"
echo "---------------------------------------------------------------------"

exit 0