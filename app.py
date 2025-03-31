# /home/pi/pi-offloader/app.py
import os
import subprocess
import shutil
import json
import psutil
import datetime # Make sure this is imported
import secrets
import time # For SSE sleep
import queue # For notification queue
from flask import (
    Flask, request, render_template, redirect, url_for,
    jsonify, flash, Response, stream_with_context, session # Added session
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
SD_MOUNT_PATH_FROM_ENV = os.getenv("SD_MOUNT_PATH") # Get path from env, might be None
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
    # Reload from .env inside the function for potentially updated values
    load_dotenv(dotenv_path, override=True)
    current_admin_user = os.getenv("ADMIN_USERNAME")
    current_admin_pass = os.getenv("ADMIN_PASSWORD")

    if not current_admin_user or not current_admin_pass:
        # Allow access if trying to reach essential setup/utility pages
        if request.endpoint in ['credentials', 'static', 'stream', 'internal_notify', 'index']: # Allow index too
             return "temp_user" # Return a dummy user to bypass initial auth for setup
        else:
            return False # Deny access to other pages, handled by before_request

    # Check provided credentials against current .env values
    if username == current_admin_user and password == current_admin_pass:
        return username # Return username on success
    return False

# --- Before Request Hook for Initial Setup ---
@app.before_request
def check_initial_setup():
    load_dotenv(dotenv_path, override=True) # Ensure latest env is loaded
    current_admin_user = os.getenv("ADMIN_USERNAME")
    current_admin_pass = os.getenv("ADMIN_PASSWORD")

    # Check if credentials are set
    if not current_admin_user or not current_admin_pass:
        # Define pages accessible without login during setup
        allowed_endpoints = ['credentials', 'static', 'stream', 'internal_notify']
        # Allow index page briefly so user can click 'Credentials' link
        if request.endpoint == 'index':
            # Use session to flash message only once per browser session if not logged in
            if 'creds_warning_shown' not in session:
                flash("Admin credentials are not set. Please set them via the 'Credentials' page.", "warning")
                session['creds_warning_shown'] = True # Mark as shown
            return # Allow index page to load
        # Redirect any other page to credentials setup
        elif request.endpoint not in allowed_endpoints:
            return redirect(url_for('credentials'))

    # If credentials *are* set, clear the warning flag if it exists
    elif 'creds_warning_shown' in session:
         session.pop('creds_warning_shown')


# --- Context Processor for Templates ---
@app.context_processor
def inject_now():
    """Injects the current UTC time into template contexts."""
    return {'now': datetime.datetime.utcnow()}


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
    # --- Disk Usage ---
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

    # --- CPU/Memory ---
    status['cpu_usage'] = psutil.cpu_percent(interval=0.5)
    status['mem_usage'] = psutil.virtual_memory().percent

    # --- SD Card Status ---
    status['sd_card_mounted'] = False; status['sd_card_path_exists'] = False # Default
    sd_path_to_check = SD_MOUNT_PATH_FROM_ENV # Use the variable read at startup
    if sd_path_to_check: # Only check if the path was actually set in .env
        try:
            status['sd_card_mounted'] = os.path.ismount(sd_path_to_check)
            status['sd_card_path_exists'] = os.path.exists(sd_path_to_check)
        except Exception as e:
            app.logger.error(f"Error checking SD mount status for {sd_path_to_check}: {e}")
            # Keep defaults as False
    else:
        # If SD_MOUNT_PATH was commented out/empty, status remains Not Detected
        app.logger.debug("SD_MOUNT_PATH not set in env, skipping SD status check.")


    # --- Last Run Timestamp ---
    last_run_file = os.path.join(PROJECT_DIR, "logs/last_run.txt")
    status['last_offload_run'] = "Never or Unknown" # Default
    try:
        if os.path.exists(last_run_file):
            with open(last_run_file, 'r') as f:
                timestamp_str = f.read().strip()
                status['last_offload_run'] = timestamp_str # Keep it simple
    except Exception as e:
        app.logger.warning(f"Could not read last run timestamp file {last_run_file}: {e}")
        status['last_offload_run'] = "Error reading status"

    return status

# --- CORRECTED read_log_file function ---
def read_log_file(log_path, lines=100):
    if not os.path.exists(log_path):
        return f"Log file not found: {log_path}"
    try:
        # Use tail for efficiency if available (Linux)
        if sys.platform.startswith('linux'):
            # Use run instead of check_output to avoid raising error on non-zero exit
            process = subprocess.run(['tail', '-n', str(lines), log_path], capture_output=True, text=True, check=False)
            # Return stdout even if tail exits non-zero (e.g., file shorter than N lines)
            return process.stdout if process.stdout else "(Log empty or tail error)"
        else: # Fallback for non-Linux (Windows)
            log_lines = []
            try:
                 with open(log_path, 'r', encoding='utf-8', errors='ignore') as f:
                     log_lines = f.readlines()
                 return "".join(log_lines[-lines:])
            except Exception as e_read:
                 # Handle error if fallback read fails too
                 app.logger.error(f"Fallback read failed for {log_path}: {e_read}")
                 return f"Could not read log file ({log_path}): {e_read}"
    except FileNotFoundError: # Handle tail command not found
        app.logger.warning("tail command not found, falling back to Python read.")
        log_lines = []
        try:
            with open(log_path, 'r', encoding='utf-8', errors='ignore') as f:
                log_lines = f.readlines()
            return "".join(log_lines[-lines:])
        except Exception as e_read:
             app.logger.error(f"Fallback read failed for {log_path}: {e_read}")
             return f"Could not read log file ({log_path}): {e_read}"
    except Exception as e_general: # Catch other potential errors (e.g., permissions)
        app.logger.error(f"Error reading log file {log_path}: {e_general}")
        return f"Error reading log file ({log_path}): {e_general}"
# --- End CORRECTED read_log_file function ---

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
            except queue.Empty: yield ": keepalive\n\n"
            except Exception as e: app.logger.error(f"Error in SSE stream: {e}"); yield f"event: error\ndata: {json.dumps({'message': 'Stream error occurred'})}\n\n"; time.sleep(5)

    headers = {'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'}
    return Response(event_stream(), headers=headers)

# --- Internal Notification Endpoint (for scripts) ---
@app.route('/internal/notify', methods=['POST'])
def internal_notify():
    auth_token = request.headers.get("X-Notify-Token"); is_local = request.remote_addr in ('127.0.0.1', '::1'); allow_access = is_local or (auth_token == INTERNAL_NOTIFY_TOKEN and INTERNAL_NOTIFY_TOKEN != 'replace_with_your_generated_secure_random_notify_token')
    if not allow_access: app.logger.warning(f"Unauthorized notify from {request.remote_addr}"); return jsonify({"status": "error", "message": "Unauthorized"}), 403
    if not request.is_json: app.logger.warning(f"Notify not JSON from {request.remote_addr}"); return jsonify({"status": "error", "message": "JSON required"}), 400
    data = request.get_json(); message = data.get('message'); msg_type = data.get('type', 'info')
    if not message: app.logger.warning(f"Notify missing message from {request.remote_addr}"); return jsonify({"status": "error", "message": "Missing 'message'"}), 400
    add_notification(message, msg_type); return jsonify({"status": "success"}), 200


# --- Regular Flask Routes ---

@app.route('/')
@auth.login_required
def index(): status = get_system_status(); return render_template('index.html', status=status)

@app.route('/status')
@auth.login_required
def status_api(): status = get_system_status(); return jsonify(status)

@app.route('/diagnostics')
@auth.login_required
def diagnostics():
    uptime, disk_info = "N/A", "N/A"
    if sys.platform.startswith('linux'):
        try: uptime = subprocess.check_output("uptime -p", shell=True, text=True, timeout=5).strip()
        except Exception as e: uptime = f"Error: {e}"; add_notification(f"Diagnostics Error: {e}", "error")
        try: disk_info_dict = shutil.disk_usage(MONITORED_DISK_PATH)._asdict(); disk_info = json.dumps(disk_info_dict, indent=2)
        except Exception as e: disk_info = f"Error getting disk info: {e}"; add_notification(f"Diagnostics Error: {e}", "error")
    else: uptime = "N/A (Linux only)"; disk_info = "N/A (Linux only)"
    mem = psutil.virtual_memory(); net = psutil.net_io_counters(); status = get_system_status()
    diagnostics_info = { "uptime": uptime, "cpu_usage": f"{status.get('cpu_usage', 'N/A')}%", "memory_total": f"{mem.total // (1024**2)} MB", "memory_used": f"{mem.used // (1024**2)} MB", "memory_percent": f"{mem.percent}%", "bytes_sent": f"{net.bytes_sent:,}", "bytes_recv": f"{net.bytes_recv:,}", "disk_usage_monitored_path": disk_info, "monitored_path": MONITORED_DISK_PATH }
    return render_template('diagnostics.html', info=diagnostics_info)

@app.route('/logs')
@auth.login_required
def logs():
    log_dir = os.path.join(PROJECT_DIR, "logs"); upload_log_content = read_log_file(UPLOAD_LOG, lines=200); offload_log_content = read_log_file(OFFLOAD_LOG, lines=200); retry_log_content = read_log_file(os.path.join(log_dir, "retry_offload.log"), lines=100); eject_log_content = read_log_file(os.path.join(log_dir, "eject.log"), lines=50); notify_log_content = read_log_file(os.path.join(log_dir, "notification.log"), lines=100); udev_log_content = read_log_file(os.path.join(log_dir, "udev_trigger.log"), lines=50)
    return render_template('logs.html', upload=upload_log_content, offload=offload_log_content, retry=retry_log_content, eject=eject_log_content, notification=notify_log_content, udev=udev_log_content)

# --- CORRECTED WIFI ROUTE ---
@app.route('/wifi', methods=['GET', 'POST'])
@auth.login_required
def wifi():
    if request.method == 'POST':
        if not sys.platform.startswith('linux'): flash("Wi-Fi config only on Linux.", "error"); add_notification("Wi-Fi config attempted on non-Linux.", "error"); return redirect(url_for('wifi'))
        ssid = request.form.get('ssid') or request.form.get('custom_ssid'); psk = request.form.get('psk')
        if not ssid or not psk: flash("SSID/Password required.", "error"); return redirect(url_for('wifi'))
        if any(c in ssid + psk for c in ['"', '\\', '\n']): flash("Invalid chars in SSID/Password.", "error"); return redirect(url_for('wifi'))
        config_block = f'\nnetwork={{\n\tssid="{ssid}"\n\tpsk="{psk}"\n\tkey_mgmt=WPA-PSK\n}}\n'; wpa_conf_path = '/etc/wpa_supplicant/wpa_supplicant.conf'
        try:
            with open(wpa_conf_path, 'a') as f: f.write(config_block) # Assumes write access or sudoers
            cmd = ['sudo', 'wpa_cli', '-i', 'wlan0', 'reconfigure']; result = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=15)
            app.logger.info(f"wpa_cli output: {result.stdout}")
            if "OK" in result.stdout or ("FAIL" not in result.stdout and "ERROR" not in result.stdout): flash(f"Wi-Fi '{ssid}' added. Attempting connection.", "success"); add_notification(f"Wi-Fi network '{ssid}' added.", "success")
            else: flash(f"wpa_cli maybe OK? Output: {result.stdout}", "warning"); add_notification(f"Wi-Fi cmd for '{ssid}' output: {result.stdout}", "warning")
        except FileNotFoundError as e: flash(f"Error: Command/file not found ({e}).", "error"); add_notification(f"WiFi Config Error: Cmd not found {e}", "error")
        except PermissionError: flash(f"Error: Permission denied writing {wpa_conf_path} or running sudo.", "error"); add_notification("WiFi Config Error: Permission Denied", "error")
        except subprocess.CalledProcessError as e: flash(f"Error running wpa_cli: {e}. Check sudo.", "error"); add_notification(f"WiFi Config Error: wpa_cli failed", "error"); app.logger.error(f"wpa_cli error: {e.stderr}")
        except subprocess.TimeoutExpired: flash("wpa_cli command timed out.", "error"); add_notification("WiFi Config Error: wpa_cli timed out", "error")
        except Exception as e: flash(f"Unexpected error: {e}", "error"); add_notification(f"Error configuring Wi-Fi: {e}", "error"); app.logger.error(f"WiFi config failed", exc_info=True)
        return redirect(url_for('wifi'))

    # --- GET Request ---
    ssids = []
    if sys.platform.startswith('linux'):
        try:
            scan_cmd = ['sudo', '/sbin/iwlist', 'wlan0', 'scan']
            scan_result = subprocess.run(scan_cmd, capture_output=True, text=True, timeout=20)
            if scan_result.returncode == 0:
                for line in scan_result.stdout.splitlines():
                    line_strip = line.strip()
                    if "ESSID:" in line_strip:
                        # --- Corrected try/except block ---
                        try:
                            current_ssid = line_strip.split('"')[1]
                            if current_ssid and current_ssid != "\\x00" and current_ssid not in ssids:
                                ssids.append(current_ssid)
                        except IndexError:
                            # This handles lines where ESSID isn't quoted correctly
                            app.logger.debug(f"Could not parse SSID from line: {line_strip}")
                            # No 'pass' needed here, just continue the loop
                        # --- End corrected block ---
            else:
                app.logger.warning(f"iwlist scan failed. Code: {scan_result.returncode}, Error: {scan_result.stderr}")
        # Outer try...except block for scanning process
        except FileNotFoundError: app.logger.error("iwlist command not found.")
        except subprocess.TimeoutExpired: app.logger.warning("iwlist scan timed out.")
        except Exception as e: app.logger.error(f"Error scanning Wi-Fi: {e}", exc_info=True)
    else:
        app.logger.info("Wi-Fi scan skipped on non-Linux.")

    return render_template('wifi.html', ssids=sorted(list(set(ssids))))
# --- End of CORRECTED WIFI ROUTE ---

@app.route('/notifications', methods=['GET', 'POST'])
@auth.login_required
def notifications_route(): # Renamed function
    if request.method == 'POST': config = { "smtp_server": request.form.get("smtp_server", ""), "smtp_port": request.form.get("smtp_port", ""), "smtp_username": request.form.get("smtp_username", ""), "smtp_password": request.form.get("smtp_password", ""), "target_email": request.form.get("target_email", "") }; save_email_config(config)
    config = load_email_config(); return render_template('notifications.html', config=config)

@app.route('/backup_config')
@auth.login_required
def backup_config():
    try: os.makedirs(CONFIG_BACKUP_PATH, exist_ok=True)
    except OSError as e: flash(f"Error creating backup dir: {e}", "error"); add_notification(f"Backup Error: Cannot create dir", "error"); return redirect(url_for('index'))
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S"); files_to_backup = [ os.path.join(PROJECT_DIR, '.env'), EMAIL_CONFIG_PATH, RCLONE_CONFIG_PATH ]; backed_up_files, errors = [], []
    for file_path in files_to_backup:
        if file_path and os.path.exists(file_path): base_name = os.path.basename(file_path); dest_path = os.path.join(CONFIG_BACKUP_PATH, f"{base_name}.{timestamp}.bak"); try: shutil.copy2(file_path, dest_path); backed_up_files.append(dest_path); except Exception as e: errors.append(f"Backup failed for {file_path}: {e}"); app.logger.error(f"Backup error: {e}")
        else: errors.append(f"Skipped backup: {file_path} not found/invalid.")
    if backed_up_files: flash(f"Backed up {len(backed_up_files)} files to {CONFIG_BACKUP_PATH}", "success"); add_notification(f"Config backup OK ({len(backed_up_files)} files).", "success")
    if errors:
        for error in errors: flash(error, "error"); add_notification(f"Backup error: {error}", "error")
    return render_template('backup.html', files=backed_up_files, errors=errors, backup_dir=CONFIG_BACKUP_PATH)

@app.route('/update_system')
@auth.login_required
def update_system():
    update_output = ""; success = True
    if not sys.platform.startswith('linux'): flash("Update only on Linux.", "error"); add_notification("Update attempted on non-Linux.", "error"); return render_template('update.html', output="Update feature only on Linux.")
    try:
        add_notification("Attempting git pull...", "info"); git_cmd = ['git', 'pull']; result_git = subprocess.run(git_cmd, cwd=PROJECT_DIR, capture_output=True, text=True, check=True, timeout=60)
        update_output += f"Git Pull:\n{result_git.stdout}\n{result_git.stderr}\n\n"; flash("Git pull OK.", "info"); add_notification("Git pull OK.", "success")
        if 'requirements.txt' in result_git.stdout:
            flash("requirements.txt changed, installing...", "info"); add_notification("Installing updated requirements...", "info"); pip_cmd = [os.path.join(PROJECT_DIR, 'venv/bin/pip'), 'install', '-r', 'requirements.txt']; result_pip = subprocess.run(pip_cmd, cwd=PROJECT_DIR, capture_output=True, text=True, check=True, timeout=180)
            update_output += f"Pip Install:\n{result_pip.stdout}\n{result_pip.stderr}\n\n"; flash("Pip install OK.", "success"); add_notification("Pip requirements OK.", "success")
        add_notification("Attempting service restart...", "info"); restart_cmd = ['sudo', 'systemctl', 'restart', 'pi-gunicorn.service']; result_restart = subprocess.run(restart_cmd, capture_output=True, text=True, check=True, timeout=20)
        update_output += f"Service Restart:\n{result_restart.stdout}\n{result_restart.stderr}\n"; flash("Gunicorn restart initiated.", "success"); add_notification("Gunicorn restart OK.", "success") # Corrected notification
    except Exception as e: errmsg=f"Update Error: {e}"; update_output += errmsg; flash(errmsg, "error"); add_notification(f"System update failed: {e}", "error"); success = False; app.logger.error(f"Update error", exc_info=True)
    return render_template('update.html', output=update_output)

@app.route('/run/<action>')
@auth.login_required
def run_action(action):
    script_dir = PROJECT_DIR; scripts = { 'upload': os.path.join(script_dir, 'upload_and_cleanup.sh'), 'offload': os.path.join(script_dir, 'offload.sh'), 'retry': os.path.join(script_dir, 'retry_offload.sh'), 'eject': os.path.join(script_dir, 'safe_eject.sh'), 'reboot': 'sudo /sbin/reboot', 'shutdown': 'sudo /sbin/shutdown now' }
    if action == 'send_test_email': return redirect(url_for('run_send_test_email'))
    if action in scripts:
        cmd = scripts[action]; is_linux_cmd = any(s in cmd for s in ['sudo', '.sh'])
        if is_linux_cmd and not sys.platform.startswith('linux'): errmsg=f"Action '{action}' requires Linux."; flash(errmsg, "error"); add_notification(errmsg, "error"); return redirect(url_for('index'))
        try:
            if action in ['reboot', 'shutdown']: add_notification(f"Action '{action}' initiated by user.", "warning"); subprocess.Popen(cmd, shell=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            elif os.path.exists(cmd) and (cmd.endswith('.sh') and os.access(cmd, os.X_OK)): subprocess.Popen([cmd], env=os.environ.copy(), cwd=script_dir, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); flash(f"Action '{action}' started.", "success"); add_notification(f"Action '{action}' started by user.", "info")
            else: errmsg = f"Script for '{action}' not found/executable: {cmd}"; flash(errmsg, "error"); add_notification(errmsg, "error"); app.logger.error(errmsg)
        except Exception as e: errmsg = f"Failed to run action '{action}': {e}"; flash(errmsg, "error"); add_notification(errmsg, "error"); app.logger.error(errmsg, exc_info=True)
    else: flash(f"Unknown action: {action}", "error"); add_notification(f"Unknown action attempted: {action}", "warning")
    return redirect(url_for('index'))

@app.route('/credentials', methods=['GET', 'POST'])
def credentials():
    load_dotenv(dotenv_path, override=True); current_admin_user = os.getenv("ADMIN_USERNAME"); current_admin_pass = os.getenv("ADMIN_PASSWORD"); admin_exists = bool(current_admin_user and current_admin_pass)
    if request.method == "POST":
        new_user = request.form.get("new_username","").strip(); new_pass = request.form.get("new_password","")
        if not new_user or not new_pass: flash("Username/Password cannot be empty.", "error"); return render_template("credentials.html", admin_exists=admin_exists)
        if admin_exists:
            old_user = request.form.get("old_username"); old_pass = request.form.get("old_password")
            if old_user != current_admin_user or old_pass != current_admin_pass: flash("Current credentials incorrect.", "error"); return render_template("credentials.html", admin_exists=True)
        env_lines = [];
        if os.path.exists(dotenv_path):
            with open(dotenv_path, "r") as f: env_lines = f.readlines()
        updated_lines = []; found_user, found_pass = False, False
        for line in env_lines:
            clean_line = line.strip();
            if clean_line.startswith("ADMIN_USERNAME="): updated_lines.append(f"ADMIN_USERNAME={new_user}\n"); found_user = True
            elif clean_line.startswith("ADMIN_PASSWORD="): updated_lines.append(f"ADMIN_PASSWORD={new_pass}\n"); found_pass = True
            else: updated_lines.append(line)
        if not found_user: updated_lines.append(f"ADMIN_USERNAME={new_user}\n")
        if not found_pass: updated_lines.append(f"ADMIN_PASSWORD={new_pass}\n")
        try:
            with open(dotenv_path, "w") as f: f.writelines(updated_lines)
            load_dotenv(dotenv_path, override=True); global ADMIN_USERNAME, ADMIN_PASSWORD; ADMIN_USERNAME = os.getenv("ADMIN_USERNAME"); ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD")
            flash("Credentials updated. Restart service if login issues persist.", "success"); add_notification("Admin credentials updated.", "success"); return redirect(url_for("index"))
        except Exception as e: flash(f"Error writing .env: {e}", "error"); add_notification("Error saving credentials.", "error"); app.logger.error(f"Error writing .env", exc_info=True); return render_template("credentials.html", admin_exists=admin_exists)
    if 'creds_warning_shown' in session: session.pop('creds_warning_shown')
    return render_template("credentials.html", admin_exists=admin_exists)

@app.route('/drive_auth', methods=['GET', 'POST'])
@auth.login_required
def drive_auth():
    rclone_cmd = 'rclone'; config_flag = f'--config={RCLONE_CONFIG_PATH}'; remote_name = os.getenv('RCLONE_REMOTE_NAME', 'gdrive')
    if request.method == 'POST':
        auth_token = request.form.get('auth_token')
        if auth_token:
            try:
                authorize_cmd = [rclone_cmd, 'authorize', 'drive', '--auth-no-open-browser', config_flag]
                process = subprocess.run(authorize_cmd, input=auth_token + "\n", capture_output=True, text=True, check=True, timeout=45)
                app.logger.info(f"Rclone authorize output: {process.stdout}"); flash(f"GDrive token submitted for '{remote_name}'. Test upload.", "success"); add_notification(f"GDrive token submitted for '{remote_name}'.", "success")
            except Exception as e: flash(f"Rclone auth failed: {e}", "error"); add_notification(f"GDrive auth failed: {e}", "error"); app.logger.error(f"Rclone authorize error", exc_info=True)
        else: flash("Please enter the token from Google.", "error")
        return redirect(url_for('drive_auth'))
    else: # GET Request
        auth_url, error_message = "", ""
        try:
            cmd = [rclone_cmd, 'authorize', 'drive', '--auth-no-open-browser', config_flag]
            result = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=30)
            for line in result.stdout.splitlines():
                if line.strip().startswith('http'): auth_url = line.strip(); break
            if not auth_url: auth_url = result.stdout; flash("Could not auto-extract URL.", "warning")
        except Exception as e: error_message = f"Error generating auth URL: {e}"; flash(error_message, "error"); add_notification(f"Drive Auth URL Error: {e}", "error"); app.logger.error(f"Drive auth URL error", exc_info=True)
        return render_template('drive_auth.html', auth_url=auth_url, error_message=error_message, remote_name=remote_name)

# --- Test Email Route ---
@app.route('/run/send_test_email')
@auth.login_required
def run_send_test_email():
    script_path = os.path.join(PROJECT_DIR, 'send_notification.py');
    if not os.path.exists(script_path): add_notification("Test Email Error: Script not found.", "error"); return jsonify({"success": False, "message": "send_notification.py not found."})
    try:
        env = os.environ.copy(); process = subprocess.run([sys.executable, script_path, "Test Email", "Test message from web UI."], capture_output=True, text=True, timeout=45, env=env, cwd=PROJECT_DIR)
        if process.returncode == 0: app.logger.info(f"send_notification.py executed."); add_notification("Test email initiated.", "info"); return jsonify({"success": True, "message": "Test email initiated."})
        else: app.logger.error(f"send_notification.py failed. Code: {process.returncode}\nOutput:\n{process.stdout}\n{process.stderr}"); add_notification("Test email script failed.", "error"); return jsonify({"success": False, "message": f"Script failed (code {process.returncode})."})
    except Exception as e: app.logger.error(f"Failed to run send_notification.py", exc_info=True); add_notification(f"Test Email Error: {e}", "error"); return jsonify({"success": False, "message": f"Error: {e}"})


# --- Main Execution ---
if __name__ == '__main__':
    app.logger.info(f"Starting Flask App. Internal Notify Token: {INTERNAL_NOTIFY_TOKEN[:4]}... (hidden)")
    use_debug = os.getenv('FLASK_DEBUG', 'false').lower() in ['true', '1']
    # Run with reloader if debugging, disable threaded in that case
    app.run(host='0.0.0.0', port=5000, debug=use_debug, use_reloader=use_debug, threaded=not use_debug)