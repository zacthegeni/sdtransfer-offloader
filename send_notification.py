#!/usr/bin/env python3
# /home/pi/pi-offloader/send_notification.py
# Sends email notifications using settings from email_config.json

import os
import json
import smtplib
import ssl
from email.message import EmailMessage
import sys
import datetime
from dotenv import load_dotenv # Import load_dotenv

# --- Configuration ---
SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
ENV_FILE = os.path.join(SCRIPT_DIR, '.env')
# Load .env to find the email config path
load_dotenv(dotenv_path=ENV_FILE)

# Get email config path from environment or use default
EMAIL_CONFIG_PATH = os.getenv("EMAIL_CONFIG_PATH", os.path.join(SCRIPT_DIR, "email_config.json"))
LOG_FILE = os.path.join(SCRIPT_DIR, "logs/notification.log")

# --- Logging ---
def log(message):
    """Appends a message to the notification log file."""
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    try:
        # Also print to stderr so it can be captured by calling process if needed
        print(f"{timestamp} - {message}", file=sys.stderr)
        with open(LOG_FILE, "a") as f:
            f.write(f"{timestamp} - {message}\n")
    except Exception as e:
        print(f"Failed to write to log file {LOG_FILE}: {e}", file=sys.stderr)

# --- Load Email Config ---
def load_config():
    """Loads email configuration from the JSON file."""
    if not os.path.exists(EMAIL_CONFIG_PATH):
        log(f"Error: Email configuration file not found at {EMAIL_CONFIG_PATH}")
        return None
    try:
        with open(EMAIL_CONFIG_PATH, 'r') as f:
            config = json.load(f)
        # Basic validation
        required_keys = ["smtp_server", "smtp_port", "smtp_username", "smtp_password", "target_email"]
        if not all(key in config and config[key] for key in required_keys):
             log("Error: Email configuration is incomplete in {}".format(EMAIL_CONFIG_PATH))
             return None
        # Convert port to int
        try: config["smtp_port"] = int(config["smtp_port"])
        except (ValueError, TypeError): log("Error: smtp_port must be a number."); return None
        return config
    except json.JSONDecodeError: log(f"Error: Could not parse JSON in {EMAIL_CONFIG_PATH}"); return None
    except Exception as e: log(f"Error loading email config: {e}"); return None

# --- Send Email Function ---
def send_email(subject, body):
    """Sends an email using the loaded configuration."""
    config = load_config()
    if not config:
        log("Email sending aborted due to missing or invalid configuration.")
        return False

    msg = EmailMessage()
    msg['Subject'] = subject
    msg['From'] = config["smtp_username"]
    msg['To'] = config["target_email"]
    msg.set_content(body)
    context = ssl.create_default_context()

    try:
        log(f"Attempting to send email to {config['target_email']} via {config['smtp_server']}:{config['smtp_port']}")
        server = None
        if config["smtp_port"] == 465:
             server = smtplib.SMTP_SSL(config["smtp_server"], config["smtp_port"], context=context, timeout=30)
        else: # Assume STARTTLS for other ports like 587, 25
            server = smtplib.SMTP(config["smtp_server"], config["smtp_port"], timeout=30)
            server.ehlo()
            server.starttls(context=context)
            server.ehlo()

        server.login(config["smtp_username"], config["smtp_password"])
        server.send_message(msg)
        server.quit()
        log("Email sent successfully.")
        return True
    except smtplib.SMTPAuthenticationError: log("Error: SMTP Authentication failed. Check username/password.")
    except smtplib.SMTPServerDisconnected: log("Error: SMTP server disconnected unexpectedly.")
    except smtplib.SMTPConnectError: log(f"Error: Could not connect to SMTP server {config['smtp_server']}:{config['smtp_port']}.")
    except ssl.SSLError as e: log(f"Error: SSL error during email sending: {e}")
    except TimeoutError: log(f"Error: Connection to SMTP server timed out.")
    except Exception as e: log(f"Error sending email: {e}")
    return False

# --- Main Execution ---
if __name__ == "__main__":
    if len(sys.argv) >= 3:
        email_subject = sys.argv[1]
        email_body = "\n".join(sys.argv[2:])
        if not send_email(email_subject, email_body):
            sys.exit(1) # Exit with error code if sending failed
    else:
        # Default action or test email if run directly without args
        log("Script run without subject/body arguments. Sending test email.")
        test_subject = "Test Notification from Pi Offloader"
        test_body = f"This is a test email sent from send_notification.py at {datetime.datetime.now()}."
        if not send_email(test_subject, test_body):
             print("Failed to send test email. Check logs/notification.log", file=sys.stderr)
             sys.exit(1)
        else:
             print("Test email sent successfully.")
             sys.exit(0) # Explicit success exit code