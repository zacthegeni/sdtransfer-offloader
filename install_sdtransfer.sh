#!/bin/bash
# install_sdtransfer.sh
# Installer for SDTransfer Offloader

# --- Configuration ---
PROJECT_DIR="/home/pi/pi-offloader"
PYTHON_EXEC="python3"
PIP_EXEC="pip3"
SERVICE_NAME="pi-gunicorn"
NGINX_CONF_NAME="sdtransfer"
PI_USER="pi" # User running the service and owning files

# --- Safety Checks ---
if [ "$(id -u)" -eq 0 ]; then
  echo "### ERROR: This script should not be run as root. Run it as the '$PI_USER' user."
  echo "###        It will use 'sudo' where necessary."
  exit 1
fi
set -e # Exit immediately if any command fails

echo ">>> Starting SDTransfer Offloader Installation..."

# --- System Update ---
echo ">>> [1/10] Updating system packages..."
sudo apt update && sudo apt upgrade -y

# --- Install Dependencies ---
echo ">>> [2/10] Installing required system packages..."
# Added rsync, tail, jq, gevent build deps (python3-dev, build-essential)
sudo apt install -y git curl unzip $PYTHON_EXEC $PYTHON_EXEC-pip $PYTHON_EXEC-venv nginx rsync tail jq wireless-tools python3-dev build-essential libffi-dev libssl-dev
# Added libffi-dev libssl-dev, sometimes needed for gevent/cryptography

echo ">>> [3/10] Installing rclone..."
if ! command -v rclone &> /dev/null; then
    curl https://rclone.org/install.sh | sudo bash
else
    echo ">>> Rclone already installed. Skipping download."
fi
echo ">>> Rclone installed/verified. IMPORTANT: You MUST configure rclone manually after this script:"
echo ">>> Run: rclone config"
echo ">>> Ensure RCLONE_CONFIG_PATH in .env points to the created config file (usually ~/.config/rclone/rclone.conf)."


# --- Project Setup ---
echo ">>> [4/10] Setting up project directories..."
mkdir -p "$PROJECT_DIR/templates" "$PROJECT_DIR/static" "$PROJECT_DIR/logs" "$PROJECT_DIR/config_backups"
# Default footage location - Check MONITORED_DISK_PATH and LOCAL_FOOTAGE_PATH in .env
mkdir -p "/home/pi/footage/videos" "/home/pi/footage/photos"
sudo chown -R $PI_USER:$PI_USER "$PROJECT_DIR" "/home/pi/footage" # Ensure user owns dirs

echo ">>> [5/10] Setting up Python virtual environment and installing packages..."
cd "$PROJECT_DIR"
if [ ! -d "venv" ]; then
    $PYTHON_EXEC -m venv venv
    echo ">>> Created Python virtual environment."
fi
source venv/bin/activate
$PIP_EXEC install --upgrade pip
if [ -f "requirements.txt" ]; then
    echo ">>> Installing packages from requirements.txt..."
    $PIP_EXEC install -r requirements.txt
else
    echo "### WARNING: requirements.txt not found. Attempting manual install..."
    $PIP_EXEC install Flask Flask-HTTPAuth python-dotenv gunicorn psutil gevent
fi
deactivate
echo ">>> Python packages installed."

# --- Create Placeholder/Default Config Files ---
echo ">>> [6/10] Creating default/placeholder configuration files (if they dont exist)..."
if [ ! -f "$PROJECT_DIR/.env" ]; then
    echo "### IMPORTANT: Creating default .env file. EDIT THIS FILE with your settings!"
    # Use python to generate secrets directly
    FLASK_SECRET=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
    NOTIFY_TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
    cat > "$PROJECT_DIR/.env" <<EOF
# /home/pi/pi-offloader/.env
# !!! EDIT THIS FILE WITH YOUR ACTUAL SETTINGS !!!

FLASK_SECRET_KEY=$FLASK_SECRET
ADMIN_USERNAME=
ADMIN_PASSWORD=
INTERNAL_NOTIFY_TOKEN=$NOTIFY_TOKEN

SD_MOUNT_PATH=/media/pi/SDCARD
LOCAL_FOOTAGE_PATH=/home/pi/footage
RCLONE_CONFIG_PATH=/home/pi/.config/rclone/rclone.conf
UPLOAD_LOG=\${PROJECT_DIR}/logs/rclone.log
OFFLOAD_LOG=\${PROJECT_DIR}/logs/offload.log
EMAIL_CONFIG_PATH=\${PROJECT_DIR}/email_config.json
MONITORED_DISK_PATH=/home/pi/footage
CONFIG_BACKUP_PATH=/home/pi/config_backups

RCLONE_REMOTE_NAME=gdrive
RCLONE_REMOTE_BASE_PATH=FX3_Backups
RCLONE_COPY_FLAGS="--min-age 1m --contimeout 60s --timeout 300s --retries 3"

VIDEO_SUBDIR=PRIVATE/M4ROOT/CLIP
PHOTO_SUBDIR=DCIM/100MSDCF
EOF
    echo ">>> Default .env created at $PROJECT_DIR/.env"
else
    echo ">>> .env file already exists, skipping creation."
fi

if [ ! -f "$PROJECT_DIR/email_config.json" ]; then
    echo "{}" > "$PROJECT_DIR/email_config.json"
    echo ">>> Created empty email_config.json."
else
     echo ">>> email_config.json already exists, skipping creation."
fi
# Set permissions every time to ensure they are correct
sudo chown $PI_USER:$PI_USER "$PROJECT_DIR/.env" "$PROJECT_DIR/email_config.json" || echo "Warning: Could not chown config files."
sudo chmod 600 "$PROJECT_DIR/.env" "$PROJECT_DIR/email_config.json" || echo "Warning: Could not chmod config files."


# --- Make Scripts Executable ---
echo ">>> [7/10] Setting permissions on scripts..."
chmod +x "$PROJECT_DIR/offload.sh" \
          "$PROJECT_DIR/upload_and_cleanup.sh" \
          "$PROJECT_DIR/retry_offload.sh" \
          "$PROJECT_DIR/safe_eject.sh" \
          "$PROJECT_DIR/send_notification.py" \
          || echo "Warning: Could not chmod scripts."

# --- Systemd Service for Gunicorn ---
echo ">>> [8/10] Setting up systemd service for Gunicorn ($SERVICE_NAME)..."
GUNICORN_EXEC="$PROJECT_DIR/venv/bin/gunicorn"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"

# Check if Gunicorn exists in venv
if [ ! -x "$GUNICORN_EXEC" ]; then
    echo "### ERROR: Gunicorn not found at $GUNICORN_EXEC. Installation might have failed."
    exit 1
fi

sudo bash -c "cat > $SERVICE_FILE <<EOF
[Unit]
Description=Gunicorn instance to serve the SDTransfer Offloader Flask app
After=network.target

[Service]
User=$PI_USER
Group=$(id -gn $PI_USER)
WorkingDirectory=$PROJECT_DIR
EnvironmentFile=-$PROJECT_DIR/.env # Use '-' to ignore error if file doesn't exist initially
# Use gevent worker for SSE, specify Python from venv
ExecStart=$PROJECT_DIR/venv/bin/python $GUNICORN_EXEC --workers 3 -k gevent --bind unix:$PROJECT_DIR/$SERVICE_NAME.sock -m 007 app:app
# Or eventlet: ExecStart=... -k eventlet ...
Restart=always
RestartSec=5s
TimeoutStopSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF"

sudo systemctl daemon-reload
sudo systemctl enable $SERVICE_NAME
sudo systemctl start $SERVICE_NAME
echo ">>> Gunicorn service '$SERVICE_NAME' created and started (using gevent)."
echo ">>> Check service status with: sudo systemctl status $SERVICE_NAME"

# --- Nginx Configuration ---
echo ">>> [9/10] Configuring Nginx reverse proxy..."
NGINX_CONF_AVAILABLE="/etc/nginx/sites-available/$NGINX_CONF_NAME"
NGINX_CONF_ENABLED="/etc/nginx/sites-enabled/$NGINX_CONF_NAME"

sudo bash -c "cat > $NGINX_CONF_AVAILABLE <<EOF
server {
    listen 80 default_server; # Listen on IPv4
    listen [::]:80 default_server; # Listen on IPv6
    server_name _; # Listen for any hostname
    client_max_body_size 100M;

    location /static {
        alias $PROJECT_DIR/static;
        expires 7d; # Cache static files for a week
        access_log off; # Don't log access for static files
    }

    location / {
        proxy_pass http://unix:$PROJECT_DIR/$SERVICE_NAME.sock;
        # Standard proxy headers
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        # Headers/Settings for SSE WebSocket/long-polling
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade"; # Allows WebSocket if needed later
        proxy_buffering off; # Crucial for SSE
        proxy_cache off; # Crucial for SSE
        proxy_read_timeout 86400s; # 24 hours, keep connection open
        proxy_send_timeout 86400s;
    }
}
EOF"

if [ -f /etc/nginx/sites-enabled/default ]; then sudo rm /etc/nginx/sites-enabled/default; fi
# Ensure link is correct, remove existing if it's wrong type
if [ -L "$NGINX_CONF_ENABLED" ]; then sudo rm "$NGINX_CONF_ENABLED"; fi
sudo ln -sf "$NGINX_CONF_AVAILABLE" "$NGINX_CONF_ENABLED"
# Add www-data to pi group (if they exist)
sudo usermod -a -G $PI_USER www-data 2>/dev/null || echo "Info: User www-data or group $PI_USER might not exist, skipping group add."

echo ">>> Testing Nginx configuration..."
sudo nginx -t
if [ $? -eq 0 ]; then
    echo ">>> Nginx config OK. Restarting Nginx..."
    sudo systemctl restart nginx
else
    echo "### ERROR: Nginx configuration test failed! Please check the config file: $NGINX_CONF_AVAILABLE"
    echo "### Nginx NOT restarted."
    exit 1
fi
echo ">>> Nginx configured to proxy requests to Gunicorn (incl. SSE settings)."


# --- Sudoers Configuration ---
echo ">>> [10/10] Configuring Sudo Permissions (Manual Step Required After Script)"
SUDOERS_FILE="/etc/sudoers.d/99-pi-offloader-webui"
echo "############################################################################"
echo "### ACTION REQUIRED: Configure Passwordless Sudo ###"
echo "############################################################################"
echo "The web UI needs specific sudo permissions."
echo "Run 'sudo visudo -f $SUDOERS_FILE' and ADD the following lines:"
echo "----------------------------------------------------------------------------"
echo "# Allow '$PI_USER' user to run specific commands without password for offloader UI"
echo "$PI_USER ALL=(ALL) NOPASSWD: /sbin/reboot"
echo "$PI_USER ALL=(ALL) NOPASSWD: /sbin/shutdown"
echo "$PI_USER ALL=(ALL) NOPASSWD: /usr/sbin/wpa_cli -i wlan0 reconfigure"
echo "$PI_USER ALL=(ALL) NOPASSWD: /sbin/iwlist wlan0 scan"
echo "$PI_USER ALL=(ALL) NOPASSWD: /bin/systemctl restart $SERVICE_NAME.service"
echo "$PI_USER ALL=(ALL) NOPASSWD: /bin/umount *" # Be careful with this wildcard! Consider specific device paths if possible.
# Example for specific device pattern:
# pi ALL=(ALL) NOPASSWD: /bin/umount /dev/sd[a-z][0-9], /bin/umount /dev/mmcblk[0-9]p[0-9]
echo "----------------------------------------------------------------------------"
echo ">>> Failure to do this will result in errors when using Reboot, Shutdown,"
echo ">>> Wi-Fi configuration, System Update, or Eject buttons in the UI."
echo "############################################################################"


# --- Cron Jobs Reminder (Replaced by udev ideally) ---
echo ">>> Cron jobs NOT added by default. Use udev rules (see separate instructions/examples)."


# --- Final Instructions ---
echo ""
echo "##########################################"
echo "### Installation Complete! ###"
echo "##########################################"
echo ""
echo "1.  **CRITICAL:** Configure passwordless sudo as instructed above using 'sudo visudo -f $SUDOERS_FILE'."
echo "2.  **CRITICAL:** Edit the '.env' file with your specific settings: '$PROJECT_DIR/.env'"
echo "3.  **CRITICAL:** Configure rclone using 'rclone config'. Ensure RCLONE_CONFIG_PATH in .env points to the config file."
echo "4.  Reboot your Raspberry Pi ('sudo reboot') for all changes to take effect."
echo "5.  Access the web UI at: http://<your_pi_ip>/ (or http://$(hostname -I | awk '{print $1}')/ )"
echo "6.  Set your Admin username/password via the web UI on first access."
echo "7.  Configure Google Drive Auth via the 'Drive Auth' page if needed (only if rclone config token expired)."
echo "8.  (Recommended) Set up and test udev rules (see separate examples) for automatic SD card processing."
echo ""
echo ">>> Done."