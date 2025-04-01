#!/usr/bin/env python3
import os
import sys
import json
import shutil
import subprocess
import datetime
import time
import queue
import psutil
from threading import Thread
from flask import (
    Flask, request, render_template, redirect, url_for,
    jsonify, flash, Response, stream_with_context, session
)
from flask_httpauth import HTTPBasicAuth
from dotenv import load_dotenv

# Define project directory
PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
dotenv_path = os.path.join(PROJECT_DIR, '.env')
if os.path.exists(dotenv_path):
    load_dotenv(dotenv_path, override=True)
else:
    print(f"Warning: .env file not found at {dotenv_path}", file=sys.stderr)

app = Flask(__name__)
app.secret_key = os.getenv("FLASK_SECRET_KEY", "default_insecure_secret_key_change_me!")
auth = HTTPBasicAuth()

# Global Variables and Paths
MONITORED_DISK_PATH = os.getenv("MONITORED_DISK_PATH", "/")
SD_MOUNT_PATH = os.getenv("SD_MOUNT_PATH", "")  # Should be set if used
CONFIG_BACKUP_PATH = os.path.join(PROJECT_DIR, "config_backups")
EMAIL_CONFIG_PATH = os.getenv("EMAIL_CONFIG", os.path.join(PROJECT_DIR, "email_config.json"))
RCLONE_CONFIG_PATH = os.getenv("RCLONE_CONFIG", os.path.join(PROJECT_DIR, "rclone.conf"))
INTERNAL_NOTIFY_TOKEN = os.getenv("INTERNAL_NOTIFY_TOKEN", "replace_with_your_generated_secure_random_notify_token")

# Helper Functions
def add_notification(message, msg_type="info"):
    # Placeholder: In a real system, you might enqueue this for SSE notifications.
    app.logger.info(f"Notification [{msg_type}]: {message}")

def save_email_config(config):
    try:
        with open(EMAIL_CONFIG_PATH, 'w') as f:
            json.dump(config, f, indent=4)
        flash("Email configuration saved.", "success")
        app.logger.info("Email configuration saved.")
    except Exception as e:
        app.logger.error(f"Error saving email config: {e}")
        flash(f"Error saving email config: {e}", "error")

def load_email_config():
    try:
        with open(EMAIL_CONFIG_PATH, 'r') as f:
            return json.load(f)
    except Exception as e:
        app.logger.error(f"Error loading email config: {e}")
        return {}

def get_system_status():
    status = {}
    try:
        usage = shutil.disk_usage(MONITORED_DISK_PATH)
        status['free_space_mb'] = usage.free // (1024**2)
        status['disk_percent'] = int(usage.used / usage.total * 100) if usage.total > 0 else "N/A"
    except Exception as e:
        app.logger.error(f"Error reading disk usage: {e}")
        status['free_space_mb'] = 'N/A'
        status['disk_percent'] = 'N/A'
    try:
        status['cpu_usage'] = psutil.cpu_percent(interval=0.5)
    except Exception as e:
        app.logger.error(f"Error reading CPU usage: {e}")
        status['cpu_usage'] = 'N/A'
    try:
        status['mem_usage'] = psutil.virtual_memory().percent
    except Exception as e:
        app.logger.error(f"Error reading memory usage: {e}")
        status['mem_usage'] = 'N/A'
    try:
        status['sd_card_mounted'] = os.path.ismount(SD_MOUNT_PATH) if SD_MOUNT_PATH else False
        status['sd_card_path_exists'] = os.path.exists(SD_MOUNT_PATH) if SD_MOUNT_PATH else False
    except Exception as e:
        app.logger.error(f"Error checking SD mount status: {e}")
        status['sd_card_mounted'] = False
        status['sd_card_path_exists'] = False
    # Last offload run
    last_run_file = os.path.join(PROJECT_DIR, "logs", "last_run.txt")
    try:
        if os.path.exists(last_run_file):
            with open(last_run_file, 'r') as f:
                status['last_offload_run'] = f.read().strip()
        else:
            status['last_offload_run'] = "Never or Unknown"
    except Exception as e:
        app.logger.error(f"Error reading last run timestamp: {e}")
        status['last_offload_run'] = "Error"
    return status

def read_log_file(log_path, lines=100):
    if not os.path.exists(log_path):
        return f"Log file not found: {log_path}"
    try:
        process = subprocess.run(['tail', '-n', str(lines), log_path], capture_output=True, text=True, check=False)
        return process.stdout if process.stdout else "(Log is empty)"
    except Exception as e:
        return f"Error reading log file: {e}"

# Authentication
@auth.verify_password
def verify_password(username, password):
    load_dotenv(dotenv_path, override=True)
    admin_username = os.getenv("ADMIN_USERNAME", "")
    admin_password = os.getenv("ADMIN_PASSWORD", "")
    # Allow setup if credentials are not yet set
    if not admin_username or not admin_password:
        return True
    if username == admin_username and password == admin_password:
        return username
    return False

@app.before_request
def check_initial_setup():
    load_dotenv(dotenv_path, override=True)
    admin_username = os.getenv("ADMIN_USERNAME", "")
    admin_password = os.getenv("ADMIN_PASSWORD", "")
    if not admin_username or not admin_password:
        if request.endpoint not in ['credentials', 'static', 'stream', 'internal_notify']:
            if request.endpoint == 'index':
                if 'creds_warning_shown' not in session:
                    flash("Admin credentials are not set. Please set them via the 'Credentials' page.", "warning")
                    session['creds_warning_shown'] = True
                return
            return redirect(url_for('credentials'))
    elif 'creds_warning_shown' in session:
        session.pop('creds_warning_shown')

@app.context_processor
def inject_now():
    return {'now': datetime.datetime.utcnow()}

# Routes
@app.route('/')
@auth.login_required
def index():
    status = get_system_status()
    return render_template('index.html', status=status)

@app.route('/status_api')
def status_api():
    return jsonify(get_system_status())

@app.route('/diagnostics')
@auth.login_required
def diagnostics():
    mem = psutil.virtual_memory()
    net = psutil.net_io_counters()
    try:
        disk_info = json.dumps(shutil.disk_usage(MONITORED_DISK_PATH)._asdict(), indent=2)
    except Exception as e:
        disk_info = f"Error getting disk info: {e}"
    status = get_system_status()
    diagnostics_info = {
        "uptime": subprocess.check_output("uptime -p", shell=True, text=True, timeout=5).strip() if sys.platform.startswith('linux') else "N/A",
        "cpu_usage": f"{status.get('cpu_usage', 'N/A')}%",
        "memory_total": f"{mem.total // (1024**2)} MB",
        "memory_used": f"{mem.used // (1024**2)} MB",
        "memory_percent": f"{mem.percent}%",
        "bytes_sent": f"{net.bytes_sent:,}",
        "bytes_recv": f"{net.bytes_recv:,}",
        "disk_usage_monitored_path": disk_info,
        "monitored_path": MONITORED_DISK_PATH
    }
    return render_template('diagnostics.html', info=diagnostics_info)

@app.route('/logs')
@auth.login_required
def logs():
    upload_log_content = read_log_file(os.path.join(PROJECT_DIR, "logs", "upload.log"), lines=200)
    offload_log_content = read_log_file(os.path.join(PROJECT_DIR, "logs", "offload_wrapper.log"), lines=200)
    retry_log_content = read_log_file(os.path.join(PROJECT_DIR, "logs", "retry_offload.log"), lines=100)
    eject_log_content = read_log_file(os.path.join(PROJECT_DIR, "logs", "eject.log"), lines=50)
    notify_log_content = read_log_file(os.path.join(PROJECT_DIR, "logs", "notification.log"), lines=100)
    udev_log_content = read_log_file(os.path.join(PROJECT_DIR, "logs", "udev_trigger.log"), lines=50)
    return render_template('logs.html', upload=upload_log_content, offload=offload_log_content,
                           retry=retry_log_content, eject=eject_log_content,
                           notification=notify_log_content, udev=udev_log_content)

@app.route('/wifi', methods=['GET', 'POST'])
@auth.login_required
def wifi():
    if request.method == 'POST':
        ssid = request.form.get('ssid') or request.form.get('custom_ssid')
        psk = request.form.get('psk')
        if not ssid or not psk:
            flash("SSID and Password are required.", "error")
            return redirect(url_for('wifi'))
        if any(c in ssid + psk for c in ['"', '\\', '\n']):
            flash("Invalid characters detected in SSID or Password.", "error")
            return redirect(url_for('wifi'))
        config_block = f'\nnetwork={{\n\tssid="{ssid}"\n\tpsk="{psk}"\n\tkey_mgmt=WPA-PSK\n}}\n'
        wpa_conf_path = '/etc/wpa_supplicant/wpa_supplicant.conf'
        try:
            with open(wpa_conf_path, 'a') as f:
                f.write(config_block)
            cmd = ['sudo', 'wpa_cli', '-i', 'wlan0', 'reconfigure']
            result = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=15)
            if "OK" in result.stdout:
                flash(f"Wi‑Fi network '{ssid}' added. Attempting connection.", "success")
            else:
                flash(f"Wi‑Fi network added, but reconfigure output: {result.stdout}", "warning")
        except Exception as e:
            flash(f"Error configuring Wi‑Fi: {e}", "error")
            app.logger.error(f"Wi-Fi config failed: {e}", exc_info=True)
        return redirect(url_for('wifi'))
    else:
        ssids = []
        if sys.platform.startswith('linux'):
            try:
                scan_cmd = ['sudo', '/sbin/iwlist', 'wlan0', 'scan']
                scan_result = subprocess.run(scan_cmd, capture_output=True, text=True, timeout=20)
                if scan_result.returncode == 0:
                    for line in scan_result.stdout.splitlines():
                        if "ESSID:" in line:
                            try:
                                current_ssid = line.split('"')[1]
                                if current_ssid and current_ssid != "\\x00":
                                    ssids.append(current_ssid)
                            except IndexError:
                                continue
                else:
                    app.logger.warning(f"iwlist scan failed with code {scan_result.returncode}")
            except Exception as e:
                app.logger.error(f"Error scanning Wi-Fi: {e}", exc_info=True)
        return render_template('wifi.html', ssids=sorted(list(set(ssids))))

@app.route('/notifications', methods=['GET', 'POST'])
@auth.login_required
def notifications_route():
    if request.method == 'POST':
        config = {
            "smtp_server": request.form.get("smtp_server", ""),
            "smtp_port": request.form.get("smtp_port", ""),
            "smtp_username": request.form.get("smtp_username", ""),
            "smtp_password": request.form.get("smtp_password", ""),
            "target_email": request.form.get("target_email", "")
        }
        save_email_config(config)
    config = load_email_config()
    return render_template('notifications.html', config=config)

@app.route('/backup_config', methods=['GET', 'POST'])
@auth.login_required
def backup_config():
    try:
        os.makedirs(CONFIG_BACKUP_PATH, exist_ok=True)
    except Exception as e:
        flash(f"Error creating backup directory {CONFIG_BACKUP_PATH}: {e}", "error")
        return redirect(url_for('index'))
    backed_up_files = []
    errors = []
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    files_to_backup = [os.path.join(PROJECT_DIR, '.env'), EMAIL_CONFIG_PATH, RCLONE_CONFIG_PATH]
    for file_path in files_to_backup:
        if file_path and os.path.exists(file_path):
            base_name = os.path.basename(file_path)
            dest_path = os.path.join(CONFIG_BACKUP_PATH, f"{base_name}.{timestamp}.bak")
            try:
                shutil.copy2(file_path, dest_path)
                backed_up_files.append(dest_path)
            except Exception as e:
                errors.append(f"Failed to backup {file_path}: {e}")
                app.logger.error(f"Backup error for {file_path}: {e}")
        else:
            errors.append(f"File not found or invalid path, skipped backup: {file_path}")
    if backed_up_files:
        flash(f"Backed up {len(backed_up_files)} files to {CONFIG_BACKUP_PATH}", "success")
    if errors:
        for error in errors:
            flash(error, "error")
    return render_template('backup.html', files=backed_up_files, errors=errors, backup_dir=CONFIG_BACKUP_PATH)

@app.route('/update_system', methods=['GET', 'POST'])
@auth.login_required
def update_system():
    if request.method == 'POST':
        response = render_template('update.html', output="Update initiated. Please wait...")
        def perform_update():
            update_output = ""
            try:
                git_cmd = ['git', 'pull']
                result_git = subprocess.run(git_cmd, cwd=PROJECT_DIR, capture_output=True, text=True, check=True, timeout=60)
                update_output += f"Git Pull Output:\n{result_git.stdout}\n{result_git.stderr}\n\n"
                if 'requirements.txt' in result_git.stdout:
                    pip_cmd = [os.path.join(PROJECT_DIR, 'venv/bin/pip'), 'install', '-r', 'requirements.txt']
                    result_pip = subprocess.run(pip_cmd, cwd=PROJECT_DIR, capture_output=True, text=True, check=True, timeout=120)
                    update_output += f"Pip Install Output:\n{result_pip.stdout}\n{result_pip.stderr}\n\n"
                restart_cmd = ['sudo', 'systemctl', 'restart', 'pi-gunicorn.service']
                result_restart = subprocess.run(restart_cmd, capture_output=True, text=True, check=True, timeout=15)
                update_output += f"Service Restart Output:\n{result_restart.stdout}\n{result_restart.stderr}\n"
            except Exception as e:
                update_output += f"Update failed: {e}\n"
                app.logger.error(f"Update error: {e}", exc_info=True)
            try:
                log_file = os.path.join(PROJECT_DIR, 'logs', 'update_output.log')
                with open(log_file, 'w') as f:
                    f.write(update_output)
            except Exception as file_e:
                app.logger.error(f"Failed to write update log: {file_e}", exc_info=True)
        Thread(target=perform_update).start()
        return response
    else:
        return render_template('update.html', output="Click the button to initiate an update.")

@app.route('/run/<action>')
@auth.login_required
def run_action(action):
    script_dir = PROJECT_DIR
    scripts = {
        'upload': os.path.join(script_dir, 'upload_and_cleanup.sh'),
        'offload': os.path.join(script_dir, 'offload.sh'),
        'retry': os.path.join(script_dir, 'retry_offload.sh'),
        'eject': os.path.join(script_dir, 'safe_eject.sh'),
        'reboot': 'sudo /sbin/reboot',
        'shutdown': 'sudo /sbin/shutdown now'
    }
    if action == 'send_test_email':
        return redirect(url_for('run_send_test_email'))
    if action in scripts:
        cmd = scripts[action]
        try:
            if action in ['reboot', 'shutdown']:
                subprocess.Popen(cmd, shell=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            elif os.path.exists(cmd) and os.access(cmd, os.X_OK):
                subprocess.Popen([cmd], cwd=script_dir, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                flash(f"Action '{action}' started in background.", "success")
            else:
                flash(f"Script for action '{action}' not found or not executable at {cmd}", "error")
                app.logger.error(f"Action '{action}': Script not found or not executable at {cmd}")
        except PermissionError as e:
            flash(f"Permission denied running {action}.", "error")
            app.logger.error(f"Permission denied for {action}: {e}", exc_info=True)
        except Exception as e:
            flash(f"Failed to run action '{action}': {e}", "error")
            app.logger.error(f"Error running action '{action}': {e}", exc_info=True)
    else:
        flash(f"Unknown action: {action}", "error")
        app.logger.warning(f"Unknown action attempted: {action}")
    return redirect(url_for('index'))

@app.route('/credentials', methods=['GET', 'POST'])
def credentials():
    load_dotenv(dotenv_path, override=True)
    current_admin_user = os.getenv("ADMIN_USERNAME")
    current_admin_pass = os.getenv("ADMIN_PASSWORD")
    admin_exists = bool(current_admin_user and current_admin_pass)
    if request.method == "POST":
        new_user = request.form.get("new_username", "").strip()
        new_pass = request.form.get("new_password", "")
        if not new_user or not new_pass:
            flash("New username and password cannot be empty.", "error")
            return render_template("credentials.html", admin_exists=admin_exists)
        if admin_exists:
            old_user = request.form.get("old_username")
            old_pass = request.form.get("old_password")
            if old_user != current_admin_user or old_pass != current_admin_pass:
                flash("Current credentials do not match!", "error")
                return render_template("credentials.html", admin_exists=True)
        env_lines = []
        if os.path.exists(dotenv_path):
            with open(dotenv_path, "r") as f:
                env_lines = f.readlines()
        updated_lines = []
        found_user, found_pass = False, False
        for line in env_lines:
            if line.strip().startswith("ADMIN_USERNAME="):
                updated_lines.append(f"ADMIN_USERNAME={new_user}\n")
                found_user = True
            elif line.strip().startswith("ADMIN_PASSWORD="):
                updated_lines.append(f"ADMIN_PASSWORD={new_pass}\n")
                found_pass = True
            else:
                updated_lines.append(line)
        if not found_user:
            updated_lines.append(f"ADMIN_USERNAME={new_user}\n")
        if not found_pass:
            updated_lines.append(f"ADMIN_PASSWORD={new_pass}\n")
        try:
            with open(dotenv_path, "w") as f:
                f.writelines(updated_lines)
            load_dotenv(dotenv_path, override=True)
            flash("Credentials updated. Restart service if login issues persist.", "success")
        except Exception as e:
            flash(f"Error writing to .env file: {e}", "error")
            app.logger.error(f"Error writing .env file: {e}", exc_info=True)
            return render_template("credentials.html", admin_exists=admin_exists)
        return redirect(url_for("index"))
    if 'creds_warning_shown' in session:
        session.pop('creds_warning_shown')
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
                process = subprocess.run(authorize_cmd, input=auth_token+"\n", capture_output=True, text=True, check=True, timeout=45)
                app.logger.info(f"Rclone authorize output: {process.stdout}")
                flash(f"Google Drive token submitted for remote '{remote_name}'.", "success")
            except FileNotFoundError:
                flash(f"Error: '{rclone_cmd}' command not found.", "error")
            except subprocess.CalledProcessError as e:
                flash(f"Rclone auth failed: {e.stderr[:200]}...", "error")
                app.logger.error(f"Rclone authorize error: {e.stderr}")
            except subprocess.TimeoutExpired:
                flash("Rclone command timed out during authorization.", "error")
            except Exception as e:
                flash(f"Unexpected error during authorization: {e}", "error")
                app.logger.error(f"Drive auth unexpected error: {e}", exc_info=True)
        else:
            flash("Please enter the token from Google.", "error")
        return redirect(url_for('drive_auth'))
    else:
        auth_url, error_message = "", ""
        try:
            cmd = [rclone_cmd, 'authorize', 'drive', '--auth-no-open-browser', config_flag]
            result = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=30)
            for line in result.stdout.splitlines():
                if line.strip().startswith('http'):
                    auth_url = line.strip()
                    break
            if not auth_url:
                auth_url = result.stdout
                flash("Could not auto-extract URL, see text below.", "warning")
        except FileNotFoundError:
            error_message = f"Error: '{rclone_cmd}' command not found."
            flash(error_message, "error")
        except subprocess.CalledProcessError as e:
            error_message = f"Error generating auth URL: {e.stderr[:200]}..."
            flash(error_message, "error")
            app.logger.error(f"Rclone authorize URL error: {e.stderr}")
        except subprocess.TimeoutExpired:
            error_message = "Rclone command timed out generating auth URL."
            flash(error_message, "error")
        except Exception as e:
            error_message = f"Unexpected error: {e}"
            flash(error_message, "error")
            app.logger.error(f"Drive auth URL unexpected error: {e}", exc_info=True)
        return render_template('drive_auth.html', auth_url=auth_url, error_message=error_message, remote_name=remote_name)

@app.route('/run/send_test_email')
@auth.login_required
def run_send_test_email():
    script_path = os.path.join(PROJECT_DIR, 'send_notification.py')
    if not os.path.exists(script_path):
        flash("send_notification.py script not found.", "error")
        return jsonify({"success": False, "message": "send_notification.py not found."})
    try:
        env = os.environ.copy()
        process = subprocess.run([sys.executable, script_path, "Test Email", "This is a test message from the web UI."],
                                 capture_output=True, text=True, timeout=45, env=env, cwd=PROJECT_DIR)
        if process.returncode == 0:
            flash("Test email initiated. Check logs/recipient.", "success")
            return jsonify({"success": True, "message": "Test email initiated. Check logs/recipient."})
        else:
            flash(f"send_notification.py failed with code {process.returncode}.", "error")
            return jsonify({"success": False, "message": f"Script failed (code {process.returncode})."})
    except subprocess.TimeoutExpired:
        flash("send_notification.py timed out.", "error")
        return jsonify({"success": False, "message": "Script timed out."})
    except Exception as e:
        flash(f"Error executing send_notification.py: {e}", "error")
        return jsonify({"success": False, "message": f"Error executing script: {e}"})

if __name__ == '__main__':
    app.logger.info(f"Starting Flask App. Internal Notify Token: {INTERNAL_NOTIFY_TOKEN[:4]}... (hidden)")
    use_debug = os.getenv('FLASK_DEBUG', 'false').lower() in ['true', '1']
    app.run(host='0.0.0.0', port=5000, debug=use_debug, use_reloader=use_debug, threaded=not use_debug)
