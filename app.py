# /home/pi/pi-offloader/app.py
import os
import subprocess
import shutil
import json
import psutil
import datetime
import secrets
import time # For SSE sleep
import queue # For notification queue
from flask import (
    Flask, request, render_template, redirect, url_for,
    jsonify, flash, Response, stream_with_context
)
from flask_httpauth import HTTPBasicAuth
from dotenv import load_dotenv
import sys
import logging # Use Flask's logger

# --- Load Environment & Basic Setup ---
dotenv_path = os.path.join(os.path.dirname(__file__), '.env')
load_dotenv(dotenv_path)

app = Flask(__name__)
# Load secret key from .env or generate one (essential for sessions/flash messages)
app.secret_key = os.getenv("FLASK_SECRET_KEY", secrets.token_hex(16))
if app.secret_key == 'replace_with_your_strong_random_flask_secret_key':
     app.logger.warning("FLASK_SECRET_KEY is set to the default placeholder! Please generate a real secret key in .env.")
auth = HTTPBasicAuth()

# --- Notification Queue ---
notification_queue = queue.Queue()
INTERNAL_NOTIFY_TOKEN = os.getenv("INTERNAL_NOTIFY_TOKEN", secrets.token_hex(8)) # Simple secret for internal endpoint
if INTERNAL_NOTIFY_TOKEN == 'replace_with_your_generated_secure_random_notify_token':
     app.logger.warning("INTERNAL_NOTIFY_TOKEN is set to the default placeholder! Please generate a real token in .env for script notifications.")
     # Use a temporary one if placeholder is detected, though scripts might fail if app restarts
     INTERNAL_NOTIFY_TOKEN = secrets.token_hex(8)


# --- Configuration from .env ---
ADMIN_USERNAME = os.getenv("ADMIN_USERNAME")
ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD")
UPLOAD_LOG = os.getenv("UPLOAD_LOG", "/home/pi/pi-offloader/logs/rclone.log")
OFFLOAD_LOG = os.getenv("OFFLOAD_LOG", "/home/pi/pi-offloader/logs/offload.log")
EMAIL_CONFIG_PATH = os.getenv("EMAIL_CONFIG_PATH", "/home/pi/pi-offloader/email_config.json")
MONITORED_DISK_PATH = os.getenv("MONITORED_DISK_PATH", "/home/pi/footage") # Default to footage if not set
CONFIG_BACKUP_PATH = os.getenv("CONFIG_BACKUP_PATH", "/home/pi/config_backups")
RCLONE_CONFIG_PATH = os.getenv("RCLONE_CONFIG_PATH", "/home/pi/.config/rclone/rclone.conf")
SD_MOUNT_PATH = os.getenv("SD_MOUNT_PATH", "/media/pi/SDCARD") # Load SD mount path
PROJECT_DIR = os.path.dirname(__file__) # Get the directory where app.py is located

# Ensure log directory exists
os.makedirs(os.path.join(PROJECT_DIR, "logs"), exist_ok=True)

# Set up basic logging
logging.basicConfig(level=logging.INFO)
app.logger.setLevel(logging.INFO)


# --- Helper: Add Notification ---
def add_notification(message, msg_type="info"):
    """Adds a notification message to the queue."""
    app.logger.info(f"Queueing notification: [{msg_type}] {message}") # Log to console/gunicorn log
    try:
        notification_queue.put_nowait({"type": msg_type, "message": message})
    except queue.Full:
        app.logger.warning("Notification queue is full, dropping message.")


# --- Authentication ---
@auth.verify_password
def verify_password(username, password):
    current_admin_user = os.getenv("ADMIN_USERNAME")
    current_admin_pass = os.getenv("ADMIN_PASSWORD")

    if not current_admin_user or not current_admin_pass:
        if request.endpoint in ['credentials', 'static', 'stream', 'internal_notify']:
             return "temp_user"
        else:
            return False

    if username == current_admin_user and password == current_admin_pass:
        return username
    return False

# --- Before Request Hook for Initial Setup ---
@app.before_request
def check_initial_setup():
    load_dotenv(dotenv_path, override=True)
    current_admin_user = os.getenv("ADMIN_USERNAME")
    current_admin_pass = os.getenv("ADMIN_PASSWORD")

    if not current_admin_user or not current_admin_pass:
        if request.endpoint not in ['credentials', 'static', 'stream', 'internal_notify']:
            # Allow access to index page briefly so user can click 'Credentials' link
            if request.endpoint == 'index':
                 flash("Admin credentials are not set. Please set them via the 'Credentials' page.", "warning")
                 return # Allow index to load but show flash message
            else:
                return redirect(url_for('credentials'))


# --- Helper Functions ---
def load_email_config():
    try:
        with open(EMAIL_CONFIG_PATH, 'r') as f:
            return json.load(f)
    except FileNotFoundError:
        return {"smtp_server": "", "smtp_port": "", "smtp_username": "", "smtp_password": "", "target_email": ""}
    except Exception as e:
        app.logger.error(f"Error loading email config from {EMAIL_CONFIG_PATH}: {e}")
        flash(f"Error loading email config: {e}", "error")
        add_notification(f"Error loading email config: {e}", "error")
        return {"smtp_server": "", "smtp_port": "", "smtp_username": "", "smtp_password": "", "target_email": ""}

def save_email_config(config):
    try:
        with open(EMAIL_CONFIG_PATH, 'w') as f:
            json.dump(config, f, indent=4)
        flash("Email settings saved successfully.", "success")
        add_notification("Email settings saved.", "success")
    except Exception as e:
        app.logger.error(f"Error saving email config to {EMAIL_CONFIG_PATH}: {e}")
        flash(f"Error saving email config: {e}", "error")
        add_notification(f"Error saving email config: {e}", "error")

def get_system_status():
    status = {}
    try:
        usage = shutil.disk_usage(MONITORED_DISK_PATH)
        status['disk_total'] = usage.total // (1024**2)
        status['disk_used'] = usage.used // (1024**2)
        status['disk_free'] = usage.free // (1024**2)
        status['disk_percent'] = int((usage.used / usage.total) * 100) if usage.total > 0 else 0
        status['free_space_mb'] = f"{status['disk_free']} MB free"
    except FileNotFoundError:
        status['free_space_mb'] = f"Path not found: {MONITORED_DISK_PATH}"
        status['disk_percent'] = 'N/A'
    except Exception as e:
        status['free_space_mb'] = f"Error reading disk: {e}"
        status['disk_percent'] = 'N/A'

    status['cpu_usage'] = psutil.cpu_percent(interval=0.5)
    status['mem_usage'] = psutil.virtual_memory().percent

    try:
        status['sd_card_mounted'] = os.path.ismount(SD_MOUNT_PATH)
        status['sd_card_path_exists'] = os.path.exists(SD_MOUNT_PATH)
    except Exception as e:
        app.logger.error(f"Error checking SD mount status for {SD_MOUNT_PATH}: {e}")
        status['sd_card_mounted'] = False
        status['sd_card_path_exists'] = False

    return status

def read_log_file(log_path, lines=100):
    if not os.path.exists(log_path):
        return f"Log file not found: {log_path}"
    try:
        # Use tail for efficiency
        process = subprocess.run(['tail', '-n', str(lines), log_path], capture_output=True, text=True, check=False)
        # Even if tail returns error (e.g. file just created/empty), stdout might be valid
        return process.stdout if process.stdout else "(Log is empty or could not be read)"
    except FileNotFoundError:
        # Fallback if tail command is not available
        try:
            with open(log_path, 'r') as f:
                log_lines = f.readlines()
                return "".join(log_lines[-lines:])
        except Exception as e_read:
            return f"Could not read log file ({log_path}): {e_read}"
    except Exception as e_tail:
        return f"Error using tail for log file ({log_path}): {e_tail}"

# --- Routes ---

# --- Notification Stream Endpoint (SSE) ---
@app.route('/stream')
def stream():
    @stream_with_context
    def event_stream():
        while True:
            try:
                message_data = notification_queue.get(timeout=60)
                sse_data = f"data: {json.dumps(message_data)}\n\n"
                yield sse_data
                notification_queue.task_done()
            except queue.Empty:
                yield ": keepalive\n\n"
            except Exception as e:
                 app.logger.error(f"Error in SSE stream: {e}")
                 yield f"event: error\ndata: {json.dumps({'message': 'Stream error occurred'})}\n\n"
                 time.sleep(5)

    # Set headers to prevent caching
    headers = {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'X-Accel-Buffering': 'no' # Useful for Nginx buffering
    }
    return Response(event_stream(), headers=headers)

# --- Internal Notification Endpoint (for scripts) ---
@app.route('/internal/notify', methods=['POST'])
def internal_notify():
    auth_token = request.headers.get("X-Notify-Token")
    is_local = request.remote_addr in ('127.0.0.1', '::1')

    # Allow if local or token matches
    if not is_local and auth_token != INTERNAL_NOTIFY_TOKEN:
        app.logger.warning(f"Unauthorized notification attempt from {request.remote_addr}")
        return jsonify({"status": "error", "message": "Unauthorized"}), 403

    if not request.is_json:
        app.logger.warning(f"Invalid notification request (not JSON) from {request.remote_addr}")
        return jsonify({"status": "error", "message": "Invalid request, JSON required"}), 400

    data = request.get_json()
    message = data.get('message')
    msg_type = data.get('type', 'info') # Default to 'info'

    if not message:
        app.logger.warning(f"Invalid notification request (missing message) from {request.remote_addr}")
        return jsonify({"status": "error", "message": "Missing 'message' field"}), 400

    add_notification(message, msg_type)
    return jsonify({"status": "success", "message": "Notification received"}), 200


# --- Regular Flask Routes ---

@app.route('/')
@auth.login_required
def index():
    status = get_system_status()
    return render_template('index.html', status=status)

@app.route('/status')
@auth.login_required
def status_api():
    status = get_system_status()
    return jsonify(status)

@app.route('/diagnostics')
@auth.login_required
def diagnostics():
    try:
        uptime = subprocess.check_output("uptime -p", shell=True, text=True).strip()
    except Exception as e:
        uptime = f"Error getting uptime: {e}"; add_notification(f"Diagnostics Error: {e}", "error")

    mem = psutil.virtual_memory()
    net = psutil.net_io_counters()
    disk_info = "N/A"
    try:
        disk_info_dict = shutil.disk_usage(MONITORED_DISK_PATH)._asdict()
        disk_info = json.dumps(disk_info_dict, indent=2)
    except Exception as e:
         disk_info = f"Error getting disk info for {MONITORED_DISK_PATH}: {e}"
         add_notification(f"Diagnostics Error: {e}", "error")

    status = get_system_status()
    diagnostics_info = {
        "uptime": uptime, "cpu_usage": f"{status.get('cpu_usage', 'N/A')}%",
        "memory_total": f"{mem.total // (1024**2)} MB", "memory_used": f"{mem.used // (1024**2)} MB",
        "memory_percent": f"{mem.percent}%", "bytes_sent": f"{net.bytes_sent:,}", "bytes_recv": f"{net.bytes_recv:,}", # Added commas
        "disk_usage_monitored_path": disk_info, "monitored_path": MONITORED_DISK_PATH
    }
    return render_template('diagnostics.html', info=diagnostics_info)

@app.route('/logs')
@auth.login_required
def logs():
    upload_log_content = read_log_file(UPLOAD_LOG, lines=200)
    offload_log_content = read_log_file(OFFLOAD_LOG, lines=200)
    # Also read other logs maybe?
    retry_log_content = read_log_file(os.path.join(PROJECT_DIR, "logs/retry_offload.log"), lines=100)
    eject_log_content = read_log_file(os.path.join(PROJECT_DIR, "logs/eject.log"), lines=50)
    notify_log_content = read_log_file(os.path.join(PROJECT_DIR, "logs/notification.log"), lines=100)
    udev_log_content = read_log_file(os.path.join(PROJECT_DIR, "logs/udev_trigger.log"), lines=50)

    return render_template('logs.html', upload=upload_log_content, offload=offload_log_content,
                           retry=retry_log_content, eject=eject_log_content,
                           notification=notify_log_content, udev=udev_log_content)

@app.route('/wifi', methods=['GET', 'POST'])
@auth.login_required
def wifi():
    if request.method == 'POST':
        ssid = request.form.get('ssid') or request.form.get('custom_ssid')
        psk = request.form.get('psk')
        if not ssid or not psk: flash("SSID and Password are required.", "error"); return redirect(url_for('wifi'))
        # Basic sanity check for quotes/newlines
        if any(c in ssid + psk for c in ['"', '\\', '\n']):
             flash("Invalid characters detected in SSID or Password.", "error"); return redirect(url_for('wifi'))

        config_block = f'\nnetwork={{\n\tssid="{ssid}"\n\tpsk="{psk}"\n\tkey_mgmt=WPA-PSK\n}}\n'
        wpa_conf_path = '/etc/wpa_supplicant/wpa_supplicant.conf'
        try:
            # Append requires sudo access for pi user or specific file permissions (less secure)
            # Consider writing to a temp file and using sudo mv? Safer but more complex.
            # Using direct append with sudo wpa_cli assumes sudoers is set up.
            with open(wpa_conf_path, 'a') as f: f.write(config_block)
            cmd = ['sudo', 'wpa_cli', '-i', 'wlan0', 'reconfigure']
            result = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=10)
            app.logger.info(f"wpa_cli reconfigure output: {result.stdout}")
            if "OK" in result.stdout or ("FAIL" not in result.stdout and "ERROR" not in result.stdout):
                 flash(f"Wi-Fi network '{ssid}' added. System is attempting to connect.", "success")
                 add_notification(f"Wi-Fi network '{ssid}' added. Attempting connection.", "success")
            else:
                 flash(f"wpa_cli command run, maybe OK? Output: {result.stdout}", "warning")
                 add_notification(f"Wi-Fi cmd for '{ssid}' output: {result.stdout}", "warning")
        except FileNotFoundError as e: flash(f"Error: Command/file not found ({e}).", "error"); add_notification(f"WiFi Config Error: Command not found {e}", "error")
        except PermissionError: flash(f"Error: Permission denied writing {wpa_conf_path} or running sudo.", "error"); add_notification("WiFi Config Error: Permission Denied", "error")
        except subprocess.CalledProcessError as e: flash(f"Error running wpa_cli: {e}. Check sudo permissions.", "error"); add_notification(f"WiFi Config Error: wpa_cli failed", "error"); app.logger.error(f"wpa_cli error: {e.stderr}")
        except subprocess.TimeoutExpired: flash("wpa_cli command timed out.", "error"); add_notification("WiFi Config Error: wpa_cli timed out", "error")
        except Exception as e: flash(f"An unexpected error occurred: {e}", "error"); add_notification(f"Error configuring Wi-Fi: {e}", "error"); app.logger.error(f"WiFi config failed: {e}", exc_info=True)
        return redirect(url_for('wifi'))

    # --- GET Request ---
    ssids = []
    try:
        scan_cmd = ['sudo', '/sbin/iwlist', 'wlan0', 'scan']
        scan_result = subprocess.run(scan_cmd, capture_output=True, text=True, timeout=20) # Increased timeout
        if scan_result.returncode == 0:
            current_ssid = None
            for line in scan_result.stdout.splitlines():
                line_strip = line.strip()
                if "ESSID:" in line_strip:
                    try:
                        current_ssid = line_strip.split('"')[1]
                        if current_ssid and current_ssid != "\\x00" and current_ssid not in ssids:
                             ssids.append(current_ssid)
                    except IndexError: pass # Ignore lines where ESSID isn't quoted properly
        else: app.logger.warning(f"iwlist scan failed. Code: {scan_result.returncode}, Error: {scan_result.stderr}")
    except FileNotFoundError: app.logger.error("iwlist command not found.")
    except subprocess.TimeoutExpired: app.logger.warning("iwlist scan timed out.")
    except Exception as e: app.logger.error(f"Error scanning Wi-Fi: {e}", exc_info=True)
    return render_template('wifi.html', ssids=sorted(list(set(ssids))))


@app.route('/notifications', methods=['GET', 'POST'])
@auth.login_required
def notifications():
    if request.method == 'POST':
        config = {
            "smtp_server": request.form.get("smtp_server", ""), "smtp_port": request.form.get("smtp_port", ""),
            "smtp_username": request.form.get("smtp_username", ""), "smtp_password": request.form.get("smtp_password", ""),
            "target_email": request.form.get("target_email", "")
        }
        save_email_config(config)
    config = load_email_config()
    return render_template('notifications.html', config=config)


@app.route('/backup_config')
@auth.login_required
def backup_config():
    try:
        os.makedirs(CONFIG_BACKUP_PATH, exist_ok=True)
    except OSError as e:
        flash(f"Error creating backup directory {CONFIG_BACKUP_PATH}: {e}", "error")
        add_notification(f"Backup Error: Cannot create directory {CONFIG_BACKUP_PATH}", "error")
        return redirect(url_for('index'))

    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    files_to_backup = [ os.path.join(PROJECT_DIR, '.env'), EMAIL_CONFIG_PATH, RCLONE_CONFIG_PATH ]
    backed_up_files, errors = [], []

    for file_path in files_to_backup:
        if file_path and os.path.exists(file_path): # Check if path is not None/empty
            base_name = os.path.basename(file_path)
            dest_path = os.path.join(CONFIG_BACKUP_PATH, f"{base_name}.{timestamp}.bak")
            try:
                shutil.copy2(file_path, dest_path)
                backed_up_files.append(dest_path)
            except Exception as e: errors.append(f"Failed to backup {file_path}: {e}"); app.logger.error(f"Backup error for {file_path}: {e}")
        else: errors.append(f"File not found or path invalid, skipped backup: {file_path}")

    if backed_up_files: flash(f"Backed up {len(backed_up_files)} files to {CONFIG_BACKUP_PATH}", "success"); add_notification(f"Configuration backup successful ({len(backed_up_files)} files).", "success")
    if errors:
        for error in errors: flash(error, "error"); add_notification(f"Backup error: {error}", "error")

    return render_template('backup.html', files=backed_up_files, errors=errors, backup_dir=CONFIG_BACKUP_PATH)


@app.route('/update_system')
@auth.login_required
def update_system():
    update_output = ""
    success = True
    try:
        add_notification("Attempting system update via git...", "info")
        git_cmd = ['git', 'pull']
        result_git = subprocess.run(git_cmd, cwd=PROJECT_DIR, capture_output=True, text=True, check=True, timeout=60)
        update_output += f"Git Pull Output:\n{result_git.stdout}\n{result_git.stderr}\n\n"
        flash("Git pull successful.", "info"); add_notification("Git pull successful.", "success") # Notify success here

        # Check if requirements changed
        if 'requirements.txt' in result_git.stdout:
            flash("requirements.txt changed, attempting to install...", "info")
            add_notification("Attempting pip install for updated requirements...", "info")
            pip_cmd = [os.path.join(PROJECT_DIR, 'venv/bin/pip'), 'install', '-r', 'requirements.txt']
            result_pip = subprocess.run(pip_cmd, cwd=PROJECT_DIR, capture_output=True, text=True, check=True, timeout=120)
            update_output += f"Pip Install Output:\n{result_pip.stdout}\n{result_pip.stderr}\n\n"
            flash("Pip install successful.", "success"); add_notification("Pip requirements installed.", "success")

        add_notification("Attempting service restart...", "info")
        restart_cmd = ['sudo', 'systemctl', 'restart', 'pi-gunicorn.service']
        result_restart = subprocess.run(restart_cmd, capture_output=True, text=True, check=True, timeout=15)
        update_output += f"Service Restart Output:\n{result_restart.stdout}\n{result_restart.stderr}\n"
        flash("Gunicorn service restart initiated.", "success"); add_notification("Gunicorn service restart initiated.", "success")

    except FileNotFoundError as e: errmsg=f"Error: Command not found ({e.filename})."; update_output += errmsg; flash(errmsg, "error"); add_notification(f"Update Error: {errmsg}", "error"); success = False
    except subprocess.CalledProcessError as e: errmsg=f"Error during update:\nCommand: {' '.join(e.cmd)}\nOutput:\n{e.stderr}"; update_output += errmsg; flash(errmsg, "error"); add_notification(f"System update failed (Command: {' '.join(e.cmd)}).", "error"); success = False; app.logger.error(f"Update error: {e}", exc_info=True)
    except subprocess.TimeoutExpired as e_time: errmsg=f"Error: Command timed out ({' '.join(e_time.cmd)})."; update_output += errmsg; flash(errmsg, "error"); add_notification(f"System update failed (Timeout: {' '.join(e_time.cmd)}).", "error"); success = False
    except Exception as e: errmsg=f"An unexpected error occurred: {e}"; update_output += errmsg; flash(errmsg, "error"); add_notification(f"System update failed: {e}", "error"); success = False; app.logger.error(f"Update error: {e}", exc_info=True)

    return render_template('update.html', output=update_output)


@app.route('/run/<action>')
@auth.login_required
def run_action(action):
    script_dir = PROJECT_DIR
    scripts = {
        'upload': os.path.join(script_dir, 'upload_and_cleanup.sh'), # Runs stateful upload ONLY
        'offload': os.path.join(script_dir, 'offload.sh'), # Wrapper, calls stateful copy AND upload
        'retry': os.path.join(script_dir, 'retry_offload.sh'), # Runs stateful retry upload
        'eject': os.path.join(script_dir, 'safe_eject.sh'),
        'reboot': 'sudo /sbin/reboot',
        'shutdown': 'sudo /sbin/shutdown now'
    }

    if action == 'send_test_email': return redirect(url_for('run_send_test_email')) # Use dedicated route

    if action in scripts:
        cmd = scripts[action]
        try:
            if action in ['reboot', 'shutdown']:
                add_notification(f"Action '{action}' initiated by user.", "warning")
                # Use Popen for background, no waiting needed
                subprocess.Popen(cmd, shell=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                # Can't reliably flash as app might die
            elif os.path.exists(cmd) and os.access(cmd, os.X_OK):
                env = os.environ.copy()
                # Start script in background, don't wait for it
                subprocess.Popen([cmd], env=env, cwd=script_dir, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                flash(f"Action '{action}' started in background.", "success")
                add_notification(f"Action '{action}' started by user.", "info") # Script should notify on completion/error
            else: errmsg = f"Script for action '{action}' not found or not executable at {cmd}"; flash(errmsg, "error"); add_notification(errmsg, "error"); app.logger.error(errmsg)
        except PermissionError as e: errmsg = f"Permission denied running {action}. Check sudoers/permissions."; flash(errmsg, "error"); add_notification(errmsg, "error"); app.logger.error(f"{errmsg} Details: {e}")
        except Exception as e: errmsg = f"Failed to run action '{action}': {e}"; flash(errmsg, "error"); add_notification(errmsg, "error"); app.logger.error(errmsg, exc_info=True)
    else: flash(f"Unknown action: {action}", "error"); add_notification(f"Attempted unknown action: {action}", "warning")

    return redirect(url_for('index'))


@app.route('/credentials', methods=['GET', 'POST'])
def credentials():
    load_dotenv(dotenv_path, override=True)
    current_admin_user = os.getenv("ADMIN_USERNAME")
    current_admin_pass = os.getenv("ADMIN_PASSWORD")
    admin_exists = bool(current_admin_user and current_admin_pass)

    if request.method == "POST":
        new_user = request.form.get("new_username","").strip()
        new_pass = request.form.get("new_password","") # Keep leading/trailing spaces? Usually no.

        if not new_user or not new_pass:
             flash("New username and password cannot be empty.", "error"); return render_template("credentials.html", admin_exists=admin_exists)

        if admin_exists:
            old_user = request.form.get("old_username")
            old_pass = request.form.get("old_password")
            if old_user != current_admin_user or old_pass != current_admin_pass:
                flash("Current credentials do not match!", "error"); return render_template("credentials.html", admin_exists=True)

        env_lines = []
        if os.path.exists(dotenv_path):
            with open(dotenv_path, "r") as f: env_lines = f.readlines()
        updated_lines = []
        found_user, found_pass = False, False
        for line in env_lines:
            clean_line = line.strip()
            if clean_line.startswith("ADMIN_USERNAME="): updated_lines.append(f"ADMIN_USERNAME={new_user}\n"); found_user = True
            elif clean_line.startswith("ADMIN_PASSWORD="): updated_lines.append(f"ADMIN_PASSWORD={new_pass}\n"); found_pass = True
            else: updated_lines.append(line) # Keep original line ending
        if not found_user: updated_lines.append(f"ADMIN_USERNAME={new_user}\n")
        if not found_pass: updated_lines.append(f"ADMIN_PASSWORD={new_pass}\n")

        try:
            with open(dotenv_path, "w") as f: f.writelines(updated_lines)
            load_dotenv(dotenv_path, override=True) # Reload current process
            global ADMIN_USERNAME, ADMIN_PASSWORD # Update global vars
            ADMIN_USERNAME = os.getenv("ADMIN_USERNAME")
            ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD")
            flash("Credentials updated. Restart service if login issues persist.", "success"); add_notification("Admin credentials updated.", "success")
            return redirect(url_for("index"))
        except Exception as e: flash(f"Error writing to .env file: {e}", "error"); add_notification("Error saving credentials.", "error"); app.logger.error(f"Error writing .env file: {e}", exc_info=True); return render_template("credentials.html", admin_exists=admin_exists)

    return render_template("credentials.html", admin_exists=admin_exists)


@app.route('/drive_auth', methods=['GET', 'POST'])
@auth.login_required
def drive_auth():
    rclone_cmd = 'rclone'
    config_flag = f'--config={RCLONE_CONFIG_PATH}'
    remote_name = os.getenv('RCLONE_REMOTE_NAME', 'gdrive')

    if request.method == 'POST':
        auth_token = request.form.get('auth_token')
        if auth_token:
            try:
                authorize_cmd = [rclone_cmd, 'authorize', 'drive', '--auth-no-open-browser', config_flag]
                # Pass token via stdin, ensure it ends with newline if needed by rclone
                process = subprocess.run(authorize_cmd, input=auth_token + "\n", capture_output=True, text=True, check=True, timeout=45)
                app.logger.info(f"Rclone authorize output: {process.stdout}")
                flash(f"Google Drive token submitted for remote '{remote_name}'. Test upload.", "success"); add_notification(f"Google Drive token submitted for remote '{remote_name}'.", "success")
            except FileNotFoundError: flash(f"Error: '{rclone_cmd}' command not found.", "error"); add_notification(f"Drive Auth Error: rclone not found", "error")
            except subprocess.CalledProcessError as e: flash(f"Rclone auth failed. Check token/setup. Error: {e.stderr[:200]}...", "error"); add_notification(f"GDrive auth failed: {e.stderr[:100]}...", "error"); app.logger.error(f"Rclone authorize error: {e.stderr}")
            except subprocess.TimeoutExpired: flash("Rclone cmd timed out during authorization.", "error"); add_notification("GDrive auth timed out.", "error")
            except Exception as e: flash(f"Unexpected error during authorization: {e}", "error"); add_notification(f"Drive auth unexpected error: {e}", "error"); app.logger.error(f"Drive auth unexpected error: {e}", exc_info=True)
        else: flash("Please enter the authentication token from Google.", "error")
        return redirect(url_for('drive_auth'))
    else:
        # --- GET request: Generate the auth URL ---
        auth_url, error_message = "", ""
        try:
            cmd = [rclone_cmd, 'authorize', 'drive', '--auth-no-open-browser', config_flag]
            result = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=30)
            for line in result.stdout.splitlines():
                if line.strip().startswith('http'): auth_url = line.strip(); break
            if not auth_url: auth_url = result.stdout; flash("Could not auto-extract URL, see text below.", "warning")
        except FileNotFoundError: error_message = f"Error: '{rclone_cmd}' command not found."; flash(error_message, "error"); add_notification(error_message, "error")
        except subprocess.CalledProcessError as e: error_message = f"Error generating auth URL. Is rclone config ok for '{remote_name}'? Error: {e.stderr[:200]}..."; flash(error_message, "error"); add_notification(f"Drive Auth URL Error: {e.stderr[:100]}...", "error"); app.logger.error(f"Rclone authorize URL error: {e.stderr}")
        except subprocess.TimeoutExpired: error_message = "Rclone command timed out generating auth URL."; flash(error_message, "error"); add_notification(error_message, "error")
        except Exception as e: error_message = f"An unexpected error occurred: {e}"; flash(error_message, "error"); add_notification(f"Drive Auth URL Error: {e}", "error"); app.logger.error(f"Drive auth URL unexpected error: {e}", exc_info=True)
        return render_template('drive_auth.html', auth_url=auth_url, error_message=error_message, remote_name=remote_name)


# --- Test Email Route ---
@app.route('/run/send_test_email')
@auth.login_required
def run_send_test_email():
    script_path = os.path.join(PROJECT_DIR, 'send_notification.py')
    if not os.path.exists(script_path):
        add_notification("Test Email Error: Script not found.", "error"); return jsonify({"success": False, "message": "send_notification.py script not found."})
    try:
        env = os.environ.copy()
        # Run with default test args
        process = subprocess.run([sys.executable, script_path, "Test Email", "This is a test message from the web UI."],
                                 capture_output=True, text=True, timeout=45, env=env, cwd=PROJECT_DIR)
        if process.returncode == 0:
            app.logger.info(f"send_notification.py executed. Output:\n{process.stdout}\n{process.stderr}")
            add_notification("Test email initiated via script.", "info"); return jsonify({"success": True, "message": "Test email initiated. Check logs/recipient."})
        else:
            app.logger.error(f"send_notification.py failed. Code: {process.returncode}\nOutput:\n{process.stdout}\n{process.stderr}")
            add_notification("Test email script failed.", "error"); return jsonify({"success": False, "message": f"Script failed (code {process.returncode}). Check notification log."})
    except subprocess.TimeoutExpired: app.logger.error("send_notification.py timed out."); add_notification("Test email script timed out.", "error"); return jsonify({"success": False, "message": "Script timed out."})
    except Exception as e: app.logger.error(f"Failed to run send_notification.py: {e}", exc_info=True); add_notification(f"Test Email Error: {e}", "error"); return jsonify({"success": False, "message": f"Error executing script: {e}"})


# --- Main Execution ---
if __name__ == '__main__':
    app.logger.info(f"Starting Flask App. Internal Notify Token: {INTERNAL_NOTIFY_TOKEN[:4]}... (hidden)")
    # Gunicorn with gevent/eventlet handles production concurrency
    app.run(host='0.0.0.0', port=5000, debug=False, threaded=True) # threaded=True is fallback