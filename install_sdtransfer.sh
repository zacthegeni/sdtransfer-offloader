#!/bin/bash
# install_sdtransfer.sh
# One-Click Installer for SDTransfer Offloader
# Adapted for user 'zmakey' and project directory '/home/zmakey/sdtransfer-offloader'
# CORRECTED: Removed 'ps aux | grep ...' from apt install line.

set -e # Exit immediately if any command fails
export DEBIAN_FRONTEND=noninteractive # Avoid prompts during installations

# --- Configuration ---
PROJECT_USER="zmakey"
PROJECT_DIR="/home/${PROJECT_USER}/sdtransfer-offloader"
PYTHON_EXECUTABLE="/usr/bin/python3" # Adjust if using a virtual environment
GUNICORN_EXECUTABLE="/usr/local/bin/gunicorn" # Default pip install location

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
apt upgrade -y

echo "Installing required system packages..."
# Added python3-venv just in case, removed hostapd/dnsmasq unless needed for AP mode
# --- THIS IS THE CORRECTED LINE ---
apt install -y git curl unzip python3-pip python3-venv python3-flask nginx rclone
# ----------------------------------
# Ensure psutil system deps are met if needed (less common now)
# apt install -y python3-dev gcc

echo "Installing required Python packages via pip..."
# Consider using a virtual environment for better dependency management
# Example:
# ${PYTHON_EXECUTABLE} -m venv ${PROJECT_DIR}/venv
# source ${PROJECT_DIR}/venv/bin/activate
# pip install --upgrade pip
# pip install flask Flask-HTTPAuth python-dotenv gunicorn psutil
# Deactivate environment when done if needed: deactivate

# Install globally for simplicity in this script:
pip3 install --upgrade pip
pip3 install flask Flask-HTTPAuth python-dotenv gunicorn psutil

echo "Checking if rclone is installed..."
if ! command -v rclone &> /dev/null; then
    echo "Installing rclone..."
    curl https://rclone.org/install.sh | bash
else
    echo "rclone already installed."
fi

# Manual Rclone Configuration Reminder
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
echo "2. Complete the OAuth process in your browser when prompted."
echo "3. Confirm saving the configuration to '${PROJECT_DIR}/rclone.conf'."
echo "---------------------------------------------------------------------"
read -p "Press Enter to continue after you have configured rclone (or if already done)..."

# Re-verify rclone config file location
RCLONE_CONFIG_FILE="${PROJECT_DIR}/rclone.conf"
if [ ! -f "${RCLONE_CONFIG_FILE}" ]; then
     echo "Warning: Rclone config file '${RCLONE_CONFIG_FILE}' not found."
     echo "The web application might not be able to authenticate with Google Drive."
     read -p "Press Enter to continue anyway..."
fi


echo "Setting up project directories..."
mkdir -p "${PROJECT_DIR}/templates"
mkdir -p "${PROJECT_DIR}/static"
mkdir -p "${PROJECT_DIR}/footage/videos" # Subdirs for local storage
mkdir -p "${PROJECT_DIR}/footage/photos"
mkdir -p "${PROJECT_DIR}/config_backups"
mkdir -p "${PROJECT_DIR}/logs" # Specific directory for logs

echo "Setting permissions..."
# Set ownership of the entire project directory to the specified user
chown -R "${PROJECT_USER}:${PROJECT_USER}" "${PROJECT_DIR}"

# Make shell scripts executable by the owner
find "${PROJECT_DIR}" -maxdepth 1 -name "*.sh" -exec chmod u+x {} \;
# Make optional python script executable if it exists
if [ -f "${PROJECT_DIR}/send_notification.py" ]; then
    chmod u+x "${PROJECT_DIR}/send_notification.py"
fi

echo "Setting up systemd service for Gunicorn (pi-gunicorn.service)..."
# Ensure Gunicorn path is correct
if [ ! -x "${GUNICORN_EXECUTABLE}" ]; then
    echo "Error: Gunicorn not found at ${GUNICORN_EXECUTABLE}. Trying 'which gunicorn'..."
    GUNICORN_EXECUTABLE=$(which gunicorn)
    if [ -z "${GUNICORN_EXECUTABLE}" ] || [ ! -x "${GUNICORN_EXECUTABLE}" ]; then
        echo "Error: Cannot find Gunicorn executable. Please install it (pip3 install gunicorn) and potentially adjust GUNICORN_EXECUTABLE in this script." >&2
        exit 1
    fi
     echo "Found Gunicorn at: ${GUNICORN_EXECUTABLE}"
fi

# Create Gunicorn service file
cat > /etc/systemd/system/pi-gunicorn.service <<EOF
[Unit]
Description=Gunicorn instance to serve SDTransfer Offloader
After=network.target

[Service]
User=${PROJECT_USER}
Group=www-data # Optional: If Nginx needs access, though usually proxying is enough
WorkingDirectory=${PROJECT_DIR}
# If using venv: ExecStart=${PROJECT_DIR}/venv/bin/gunicorn --workers 3 --bind unix:${PROJECT_DIR}/sdtransfer.sock -m 007 wsgi:app
# Without venv, binding to localhost for Nginx proxy:
ExecStart=${GUNICORN_EXECUTABLE} --workers 3 --bind 127.0.0.1:5000 app:app
Restart=always
RestartSec=3
StandardOutput=append:${PROJECT_DIR}/logs/gunicorn.log # Log Gunicorn stdout
StandardError=append:${PROJECT_DIR}/logs/gunicorn.error.log # Log Gunicorn stderr

[Install]
WantedBy=multi-user.target
EOF

echo "Reloading systemd daemon, enabling and starting Gunicorn service..."
systemctl daemon-reload
systemctl enable pi-gunicorn
systemctl restart pi-gunicorn # Use restart instead of start to ensure it picks up changes

echo "Configuring Nginx as a reverse proxy..."
# Create Nginx config file
cat > /etc/nginx/sites-available/sdtransfer <<EOF
server {
    listen 80;
    server_name _; # Listen on all hostnames

    # Increase max body size for potential large file uploads if needed later
    # client_max_body_size 100M;

    location / {
        # Pass requests to the Gunicorn server running on localhost:5000
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Recommended proxy settings for better handling
        proxy_read_timeout 300s; # Increase timeout for long operations
        proxy_connect_timeout 75s;
        proxy_redirect off;
        # proxy_buffering off; # Consider if streaming large responses
    }

    # Optional: Serve static files directly via Nginx for better performance
    location /static {
        alias ${PROJECT_DIR}/static;
        expires 30d; # Cache static files in browser
        access_log off; # Don't log static file access
    }
}
EOF

echo "Enabling Nginx site configuration..."
# Remove default site if it exists and conflicts
rm -f /etc/nginx/sites-enabled/default
# Create symbolic link
ln -sf /etc/nginx/sites-available/sdtransfer /etc/nginx/sites-enabled/

echo "Testing Nginx configuration..."
nginx -t
if [ $? -ne 0 ]; then
    echo "Error: Nginx configuration test failed. Please check Nginx logs." >&2
    # Optionally stop here: exit 1
fi

echo "Restarting Nginx service..."
systemctl restart nginx

echo "Setting up cron jobs for user '${PROJECT_USER}'..."
# Use temporary file for safer crontab update
CRON_TEMP_FILE=$(mktemp)
crontab -u "${PROJECT_USER}" -l > "${CRON_TEMP_FILE}" 2>/dev/null || true # Get current crontab or empty if none

# Add/Update offload on reboot (with delay)
# Remove existing line first to avoid duplicates
sed -i '\%@reboot.*offload.sh%d' "${CRON_TEMP_FILE}"
echo "@reboot sleep 60 && bash ${PROJECT_DIR}/offload.sh >> ${PROJECT_DIR}/logs/cron_offload.log 2>&1" >> "${CRON_TEMP_FILE}"

# Add/Update daily upload (e.g., at 2 AM)
# Remove existing line first
sed -i '\%upload_and_cleanup.sh%d' "${CRON_TEMP_FILE}"
echo "0 2 * * * bash ${PROJECT_DIR}/upload_and_cleanup.sh >> ${PROJECT_DIR}/logs/cron_upload.log 2>&1" >> "${CRON_TEMP_FILE}"

# Install the modified crontab
crontab -u "${PROJECT_USER}" "${CRON_TEMP_FILE}"
rm "${CRON_TEMP_FILE}"

echo "---------------------------------------------------------------------"
echo "One-Click Installer Complete!"
echo "---------------------------------------------------------------------"
echo "The Flask application should be running via Gunicorn and proxied by Nginx."
echo "Access the web UI at: http://<your_pi_ip_address>/"
echo "(Note: It's now on port 80, not 5000 externally)"
echo ""
echo "Initial Setup Steps:"
echo "1. Access the web UI."
echo "2. Set your Admin Username and Password via the '/credentials' page."
echo "3. Configure Google Drive Authentication via the '/drive_auth' page (if you haven't run 'rclone config' manually)."
echo "4. Configure Email Notifications via the '/notifications' page (optional)."
echo "5. Verify the SD Card Mount Point in '${PROJECT_DIR}/upload_and_cleanup.sh'."
echo ""
echo "Troubleshooting:"
echo "- Gunicorn logs: ${PROJECT_DIR}/logs/gunicorn.log / gunicorn.error.log"
echo "- Nginx logs: /var/log/nginx/access.log / /var/log/nginx/error.log"
echo "- Cron job logs: ${PROJECT_DIR}/logs/cron_*.log"
echo "- Check service status: 'sudo systemctl status pi-gunicorn' and 'sudo systemctl status nginx'"
echo "---------------------------------------------------------------------"

exit 0