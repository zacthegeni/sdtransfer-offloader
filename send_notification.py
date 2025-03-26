#!/usr/bin/env python3
import json, sys, smtplib
from email.message import EmailMessage

CONFIG_PATH = "/home/pi/pi-offloader/email_config.json"

if len(sys.argv) < 3:
    print("Usage: send_notification.py <subject> <message>")
    sys.exit(1)

subject = sys.argv[1]
message_body = sys.argv[2]

try:
    with open(CONFIG_PATH, "r") as f:
        config = json.load(f)
except Exception as e:
    print("No email configuration found.")
    sys.exit(0)

smtp_server = config.get("smtp_server")
smtp_port = config.get("smtp_port")
smtp_username = config.get("smtp_username")
smtp_password = config.get("smtp_password")
target_email = config.get("target_email")

if not all([smtp_server, smtp_port, smtp_username, smtp_password, target_email]):
    print("Email configuration incomplete.")
    sys.exit(0)

emails = [email.strip() for email in target_email.split(",") if email.strip()]

msg = EmailMessage()
msg["Subject"] = subject
msg["From"] = smtp_username
msg["To"] = ', '.join(emails)
msg.set_content(message_body)

try:
    with smtplib.SMTP(smtp_server, int(smtp_port)) as server:
        server.starttls()
        server.login(smtp_username, smtp_password)
        server.send_message(msg)
    print("Notification sent.")
except Exception as e:
    print("Failed to send email:", e)
