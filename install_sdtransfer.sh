#!/bin/bash
# One-Click Installer for SDTransfer Offloader

set -e

echo "Updating system..."
sudo apt update && sudo apt upgrade -y

echo "Installing required packages..."
sudo apt install git curl unzip python3-pip python3-flask hostapd dnsmasq nginx -y
pip3 install flask Flask-HTTPAuth python-dotenv gunicorn psutil

echo "Installing rclone..."
curl https://rclone.org/install.sh | sudo bash

echo "Configuring rclone..."
echo "Please run 'rclone config' manually if not already configured."

echo "Setting up directories and copying configuration files..."
mkdir -p /home/pi/pi-offloader/templates
mkdir -p /home/pi/footage
mkdir -p /home/pi/config_backups

echo "Please copy your .env and email_config.json files to /home/pi/pi-offloader/ if needed."

echo "Setting permissions on scripts..."
sudo chmod +x /home/pi/offload.sh /home/pi/upload_and_cleanup.sh /home/pi/retry_offload.sh /home/pi/safe_eject.sh /home/pi/send_notification.py

echo "Setting up systemd service for Gunicorn..."
sudo bash -c 'cat > /etc/systemd/system/pi-gunicorn.service <<EOF
[Unit]
Description=Gunicorn app
After=network.target

[Service]
User=pi
WorkingDirectory=/home/pi/pi-offloader
ExecStart=/usr/local/bin/gunicorn --bind 127.0.0.1:5000 app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF'
sudo systemctl daemon-reload
sudo systemctl enable pi-gunicorn
sudo systemctl start pi-gunicorn

echo "Configuring Nginx..."
sudo bash -c 'cat > /etc/nginx/sites-available/sdtransfer <<EOF
server {
  listen 80;
  server_name _;

  location / {
    proxy_pass http://127.0.0.1:5000;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF'
sudo ln -s /etc/nginx/sites-available/sdtransfer /etc/nginx/sites-enabled/
sudo systemctl restart nginx

echo "Setting up cron jobs..."
(crontab -l 2>/dev/null; echo "@reboot sleep 30 && /home/pi/offload.sh") | crontab -
(crontab -l 2>/dev/null; echo "0 2 * * * /home/pi/upload_and_cleanup.sh") | crontab -

echo "One-Click Installer Complete!"
echo "Please review the web UI at http://<your_pi_ip>/ and configure email, rclone (rclone config), and HTTPS if needed."
