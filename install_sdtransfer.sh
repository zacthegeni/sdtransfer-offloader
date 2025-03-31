#!/bin/bash
# install_sdtransfer.sh
# One-Click Installer for SDTransfer Offloader
# Adapted for user 'zmakey' and project directory '/home/zmakey/sdtransfer-offloader'
# Includes fix for 'ps aux' apt error and uses Python virtual environment (venv).

set -e # Exit immediately if any command fails
export DEBIAN_FRONTEND=noninteractive # Avoid prompts during installations

# --- Configuration ---
PROJECT_USER="zmakey"
PROJECT_DIR="/home/${PROJECT_USER}/sdtransfer-offloader"
PYTHON_EXECUTABLE="/usr/bin/python3" # Path to system Python 3

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
# Corrected apt install line - removed 'ps aux | grep...'
# Added python3-venv, needed to create virtual environments.
apt install -y git curl unzip python3-pip python3-venv nginx rclone
# Optional: Install build tools if psutil install fails later (unlikely on newer systems)
# apt install -y python3-dev gcc

# --- Setup Python Virtual Environment ---
echo "Setting up Python virtual environment in ${PROJECT_DIR}/venv..."
# Create the virtual environment using system python3
${PYTHON_EXECUTABLE} -m venv ${PROJECT_DIR}/venv
echo "Virtual environment created."

# Activate the virtual environment and install packages within it
echo "Activating virtual environment and installing Python packages (Flask, Gunicorn, etc.)..."
# Use 'source' to activate in the current shell process
source ${PROJECT_DIR}/venv/bin/activate

# Upgrade pip within the venv
pip install --upgrade pip

# Install required packages within the venv
pip install flask Flask-HTTPAuth python-dotenv gunicorn psutil

# Deactivate the virtual environment (the service will activate it as needed)
deactivate
echo "Python packages installed successfully in virtual environment."
# --- End Python Virtual Environment Setup ---


echo "Checking if rclone is installed..."
if ! command -v rclone &> /dev/null; then
    echo "Installing rclone (this shouldn't be needed as apt should have installed it)..."
    curl https://rclone.org/install.sh | bash
else
    echo "rclone is installed."
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
echo "2. Complete the OAuth process (use the Web UI's Drive Auth page later)."
echo "3. Confirm saving the configuration to '${PROJECT_DIR}/rclone.conf'."
echo "   (The main goal here is creating the [gdrive] section)."
echo "---------------------------------------------------------------------"
read -p "Press Enter to continue after reviewing rclone instructions..."

# Verify rclone config file location (optional check)
RCLONE_CONFIG_FILE="${PROJECT_DIR}/rclone.conf"
if [ ! -f "${RCLONE_CONFIG_FILE}" ]; then
     echo "Warning: Rclone config file '${RCLONE_CONFIG_FILE}' not found yet."
     echo "Make sure to run 'rclone config' or use the Web UI Drive Auth page."
     # Don't exit here, let user configure via Web UI
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
# This includes the new venv directory
chown -R "${PROJECT_USER}:${PROJECT_USER}" "${PROJECT_DIR}"

# Make shell scripts executable by the owner
find "${PROJECT_DIR}" -maxdepth 1 -name "*.sh" -exec chmod u+x {} \;
# Make optional python script executable if it exists
if [ -f "${PROJECT_DIR}/send_notification.py" ]; then
    chmod u+x "${PROJECT_DIR}/send_notification.py"
fi

echo "Setting up systemd service for Gunicorn (pi-gunicorn.service)..."
# Define Gunicorn executable path inside the virtual environment
GUNICORN_VENV_PATH="${PROJECT_DIR}/venv/bin/gunicorn"

# Check if Gunicorn exists in venv
if [ ! -x "${GUNICORN_VENV_PATH}" ]; then
    echo "Error: Gunicorn not found inside the virtual environment at ${GUNICORN_VENV_PATH}." >&2
    echo "Python package installation might have failed. Check previous logs." >&2
    exit 1
fi

# Create Gunicorn service file
# Uses the specific path to Gunicorn inside the venv for ExecStart
cat > /etc/systemd/system/pi-gunicorn.service <<EOF
[Unit]
Description=Gunicorn instance to serve SDTransfer Offloader
After=network.target

[Service]
User=${PROJECT_USER}
Group=www-data # Optional: For potential future shared access needs
WorkingDirectory=${PROJECT_DIR}
# Ensure Gunicorn runs from the virtual environment
ExecStart=${PROJECT_DIR}/venv/bin/gunicorn --workers 3 --bind 127.0.0.1:5000 app:app
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
systemctl restart pi-gunicorn # Use restart to apply changes

echo "Configuring Nginx as a reverse proxy..."
# Create Nginx config file
cat > /etc/nginx/sites-available/sdtransfer <<EOF
server {
    listen 80 default_server; # Listen on port 80 for all IPv4 interfaces
    listen [::]:80 default_server; # Listen on port 80 for all IPv6 interfaces

    server_name _; # Listen on all hostnames

    # Increase max body size if you plan file uploads via UI later
    # client_max_body_size 100M;

    location / {
        proxy_pass http://127.0.0.1:5000; # Forward requests to Gunicorn
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Recommended proxy settings
        proxy_read_timeout 300s; # Longer timeout for potentially long operations
        proxy_connect_timeout 75s;
        proxy_redirect off;
        # proxy_buffering off; # Consider if streaming needed
    }

    # Serve static files directly via Nginx for performance
    location /static {
        alias ${PROJECT_DIR}/static;
        expires 30d; # Cache static files
        access_log off; # Don't log static file access
    }
}
EOF

echo "Enabling Nginx site configuration..."
# Remove default site if it exists to avoid conflicts
rm -f /etc/nginx/sites-enabled/default
# Create symbolic link to enable our site
ln -sf /etc/nginx/sites-available/sdtransfer /etc/nginx/sites-enabled/

echo "Testing Nginx configuration..."
if ! nginx -t; then
    echo "Error: Nginx configuration test failed. Please check Nginx logs (/var/log/nginx/error.log)." >&2
    # Optionally exit here: exit 1
fi

echo "Restarting Nginx service..."
systemctl restart nginx

echo "Setting up cron jobs for user '${PROJECT_USER}'..."
# Use temporary file for safer crontab update
CRON_TEMP_FILE=$(mktemp)
# Get current crontab or empty if none, ignoring errors if no crontab exists
crontab -u "${PROJECT_USER}" -l > "${CRON_TEMP_FILE}" 2>/dev/null || true

# Define cron job commands with full paths and logging
OFFLOAD_CMD="bash ${PROJECT_DIR}/offload.sh >> ${PROJECT_DIR}/logs/cron_offload.log 2>&1"
UPLOAD_CMD="bash ${PROJECT_DIR}/upload_and_cleanup.sh >> ${PROJECT_DIR}/logs/cron_upload.log 2>&1"

# Add/Update offload on reboot (with delay)
# Remove existing line first to avoid duplicates, matching the specific script path
sed -i "\%@reboot.*${PROJECT_DIR}/offload.sh%d" "${CRON_TEMP_FILE}"
echo "@reboot sleep 60 && ${OFFLOAD_CMD}" >> "${CRON_TEMP_FILE}"

# Add/Update daily upload (e.g., at 2 AM)
# Remove existing line first
sed -i "\%${PROJECT_DIR}/upload_and_cleanup.sh%d" "${CRON_TEMP_FILE}"
echo "0 2 * * * ${UPLOAD_CMD}" >> "${CRON_TEMP_FILE}"

# Install the modified crontab for the project user
crontab -u "${PROJECT_USER}" "${CRON_TEMP_FILE}"
rm "${CRON_TEMP_FILE}" # Clean up temp file
echo "Cron jobs updated."

echo "---------------------------------------------------------------------"
echo "SDTransfer Offloader Installation Complete!"
echo "---------------------------------------------------------------------"
echo "The Flask application should be running via Gunicorn and proxied by Nginx."
echo "Access the web UI at: http://<your_pi_ip_address>/"
echo "(Note: It's now on port 80, not 5000 externally)"
echo ""
echo "Next Steps:"
echo "1. Access the web UI."
echo "2. Set your Admin Username and Password via the '/credentials' page."
echo "3. Configure Google Drive Authentication via the '/drive_auth' page."
echo "4. Verify/Edit SD Card Mount Point in '${PROJECT_DIR}/upload_and_cleanup.sh'."
echo "5. Configure Email Notifications via '/notifications' (optional)."
echo ""
echo "Troubleshooting:"
echo "- Gunicorn logs: ${PROJECT_DIR}/logs/gunicorn.log / gunicorn.error.log"
echo "- Nginx logs: /var/log/nginx/error.log / /var/log/nginx/access.log"
echo "- Cron job logs: ${PROJECT_DIR}/logs/cron_*.log"
echo "- Check service status: 'sudo systemctl status pi-gunicorn' and 'sudo systemctl status nginx'"
echo "---------------------------------------------------------------------"

exit 0