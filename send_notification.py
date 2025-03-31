#!/usr/bin/env python3
# send_notification.py
# Placeholder script for sending email notifications.
# Reads configuration from email_config.json

import os
import json
import smtplib
import sys
from email.mime.text import MIMEText

# --- Configuration ---
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
EMAIL_CONFIG_PATH = os.path.join(BASE_DIR, 'email_config.json')
LOG_FILE = os.path.join(BASE_DIR, 'logs', 'notification.log')

# --- Helper Functions ---
def log_message(message):
    """Appends a message to the notification log file."""
    try:
        with open(LOG_FILE, 'a') as f:
            timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            f.write(f"{timestamp}: {message}\n")
    except Exception as e:
        print(f"Error writing to notification log {LOG_FILE}: {e}", file=sys.stderr)

def load_email_config():
    """Loads email configuration from the JSON file."""
    try:
        with open(EMAIL_CONFIG_PATH, 'r') as f:
            return json.load(f)
    except FileNotFoundError:
        log_message(f"Error: Email config file not found at {EMAIL_CONFIG_PATH}")
        return None
    except json.JSONDecodeError:
        log_message(f"Error: Could not decode JSON from {EMAIL_CONFIG_PATH}")
        return None
    except Exception as e:
        log_message(f"Error loading email config: {e}")
        return None

def send_email(subject, body):
    """Sends an email using configuration from email_config.json."""
    config = load_email_config()
    if not config:
        log_message("Cannot send email: Configuration is missing or invalid.")
        return False

    # Validate required fields
    required = ["smtp_server", "smtp_port", "smtp_username", "smtp_password", "target_email"]
    if not all(config.get(field) for field in required):
        log_message("Cannot send email: Missing required fields in email_config.json.")
        print("Missing fields:", [field for field in required if not config.get(field)]) # Debug print
        return False

    sender_email = config["smtp_username"]
    receiver_email = config["target_email"]
    password = config["smtp_password"]
    smtp_server = config["smtp_server"]
    try:
        smtp_port = int(config["smtp_port"]) # Ensure port is an integer
    except ValueError:
        log_message(f"Error: Invalid SMTP port '{config['smtp_port']}'. Must be an integer.")
        return False

    message = MIMEText(body, 'plain')
    message['Subject'] = subject
    message['From'] = sender_email
    message['To'] = receiver_email

    try:
        log_message(f"Connecting to SMTP server {smtp_server}:{smtp_port}...")
        # Use STARTTLS for port 587, SSL for 465 (common setups)
        if smtp_port == 587:
            server = smtplib.SMTP(smtp_server, smtp_port)
            server.starttls()
        elif smtp_port == 465:
            server = smtplib.SMTP_SSL(smtp_server, smtp_port)
        else: # Assume plain SMTP for other ports (less common, might need adjustment)
             server = smtplib.SMTP(smtp_server, smtp_port)

        log_message("Logging into SMTP server...")
        server.login(sender_email, password)
        log_message("Sending email...")
        server.sendmail(sender_email, receiver_email, message.as_string())
        log_message("Email sent successfully.")
        return True
    except smtplib.SMTPAuthenticationError:
        log_message("Error: SMTP Authentication failed. Check username/password and App Password if using Gmail.")
        return False
    except smtplib.SMTPServerDisconnected:
         log_message("Error: SMTP server disconnected unexpectedly.")
         return False
    except smtplib.SMTPConnectError:
         log_message(f"Error: Could not connect to SMTP server {smtp_server}:{smtp_port}.")
         return False
    except Exception as e:
        log_message(f"Error sending email: {e}")
        return False
    finally:
        try:
            if 'server' in locals() and server:
                server.quit()
                log_message("SMTP connection closed.")
        except Exception as e:
            log_message(f"Error closing SMTP connection: {e}")


# --- Main Execution ---
if __name__ == "__main__":
    # This script is intended to be called with arguments
    # Example: ./send_notification.py "Upload Complete" "Files uploaded successfully."
    import datetime

    if len(sys.argv) < 3:
        print("Usage: ./send_notification.py <Subject> <Body>")
        log_message("Error: Script called without subject and body arguments.")
        sys.exit(1)

    email_subject = sys.argv[1]
    email_body = sys.argv[2]

    log_message(f"Attempting to send notification: Subject='{email_subject}'")
    if send_email(email_subject, email_body):
        sys.exit(0)
    else:
        sys.exit(1)