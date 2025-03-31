import os
import subprocess
import shutil
import json
import psutil
import datetime
from flask import Flask, request, render_template, redirect, url_for, jsonify, flash
from flask_httpauth import HTTPBasicAuth
from dotenv import load_dotenv

# Define base directory relative to the script location
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# Load environment variables from .env in the base directory
dotenv_path = os.path.join(BASE_DIR, '.env')
if os.path.exists(dotenv_path):
    load_dotenv(dotenv_path)
else:
    print(f"Warning: .env file not found at {dotenv_path}")

app = Flask(__name__)
# IMPORTANT: Change this key! Generate a good random key.
# You can generate one using: python -c 'import secrets; print(secrets.token_hex(16))'
app.secret_key = os.getenv("FLASK_SECRET_KEY", "default_insecure_secret_key_change_me!")
auth = HTTPBasicAuth()

# --- Configuration Variables ---
# Use environment variables or defaults pointing within the project directory
UPLOAD_LOG = os.getenv("UPLOAD_LOG", os.path.join(BASE_DIR, "upload.log"))
OFFLOAD_LOG = os.getenv("OFFLOAD_LOG", os.path.join(BASE_DIR, "offload.log"))
EMAIL_CONFIG_PATH = os.getenv("EMAIL_CONFIG", os.path.join(BASE_DIR, 'email_config.json'))
RCLONE_CONFIG_PATH = os.getenv("RCLONE_CONFIG", os.path.join(BASE_DIR, 'rclone.conf'))
FOOTAGE_DIR = os.path.join(BASE_DIR, "footage") # Where files are stored locally
CONFIG_BACKUP_DIR = os.path.join(BASE_DIR, "config_backups")

# Ensure log directories exist
os.makedirs(os.path.dirname(UPLOAD_LOG), exist_ok=True)
os.makedirs(os.path.dirname(OFFLOAD_LOG), exist_ok=True)
os.makedirs(FOOTAGE_DIR, exist_ok=True)
os.makedirs(CONFIG_BACKUP_DIR, exist_ok=True)

# -------------------------
# Authentication
# -------------------------
@auth.verify_password
def verify_password(username, password):
    admin_username = os.getenv("ADMIN_USERNAME", "")
    admin_password = os.getenv("ADMIN_PASSWORD", "")
    # Allow access if credentials are not set (first-time setup)
    if not admin_username or not admin_password:
        return True
    # Check credentials
    return (username == admin_username) and (password == admin_password)

# -------------------------
# Helper Functions
# -------------------------
def load_email_config():
    try:
        with open(EMAIL_CONFIG_PATH, 'r') as f:
            return json.load(f)
    except FileNotFoundError:
         print(f"Email config file not found: {EMAIL_CONFIG_PATH}")
         return {"smtp_server": "", "smtp_port": "", "smtp_username": "", "smtp_password": "", "target_email": ""}
    except json.JSONDecodeError:
        print(f"Error decoding JSON from {EMAIL_CONFIG_PATH}")
        return {"smtp_server": "", "smtp_port": "", "smtp_username": "", "smtp_password": "", "target_email": ""}
    except Exception as e:
        print(f"Error loading email config: {e}")
        return {"smtp_server": "", "smtp_port": "", "smtp_username": "", "smtp_password": "", "target_email": ""}

def save_email_config(config):
    try:
        with open(EMAIL_CONFIG_PATH, 'w') as f:
            json.dump(config, f, indent=4) # Use indent for readability
        flash("Email configuration saved.", "success")
    except Exception as e:
        print(f"Error saving email config: {e}")
        flash(f"Error saving email config: {e}", "error")

def update_env_file(new_values):
    """Updates the .env file with new values, preserving existing ones."""
    env_vars = {}
    if os.path.exists(dotenv_path):
        with open(dotenv_path, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, value = line.split('=', 1)
                    env_vars[key.strip()] = value.strip()

    # Update with new values
    env_vars.update(new_values)

    # Write back to .env
    try:
        with open(dotenv_path, 'w') as f:
            for key, value in env_vars.items():
                f.write(f"{key}={value}\n")
        load_dotenv(dotenv_path, override=True) # Reload env vars in current process
        flash("Credentials updated successfully.", "success")
        return True
    except Exception as e:
        print(f"Error writing to .env file: {e}")
        flash(f"Error saving credentials: {e}", "error")
        return False

# -------------------------
# Routes
# -------------------------
@app.route('/')
@auth.login_required
def index():
    # Redirect to credentials page if not set
    admin_username = os.getenv("ADMIN_USERNAME", "")
    admin_password = os.getenv("ADMIN_PASSWORD", "")
    if not admin_username or not admin_password:
        flash("Please set the administrator username and password.", "warning")
        return redirect(url_for('credentials'))

    try:
        usage = shutil.disk_usage("/")
        free_space_mb = usage.free // (1024**2)
        free_space = f"{free_space_mb} MB free"
    except Exception as e:
        print(f"Error getting disk usage: {e}")
        free_space = "N/A"

    try:
        cpu_usage = psutil.cpu_percent(interval=0.5) # Shorter interval for responsiveness
    except Exception as e:
        print(f"Error getting CPU usage: {e}")
        cpu_usage = "N/A"

    try:
        mem_usage = psutil.virtual_memory().percent
    except Exception as e:
        print(f"Error getting memory usage: {e}")
        mem_usage = "N/A"

    return render_template('index.html', space=free_space, cpu=cpu_usage, mem=mem_usage)

@app.route('/status')
@auth.login_required
def status():
    try:
        usage = shutil.disk_usage("/")
        free_space_mb = usage.free // (1024**2)
        free_space = f"{free_space_mb} MB free"
    except Exception as e:
        free_space = "N/A"
        print(f"Error getting disk usage for status: {e}")
    return jsonify({'free_space': free_space})

@app.route('/diagnostics')
@auth.login_required
def diagnostics():
    try:
        uptime = subprocess.check_output("uptime -p", shell=True).decode().strip()
    except Exception as e:
        uptime = f"Error: {e}"

    try:
        cpu_usage = psutil.cpu_percent(interval=0.5)
    except Exception as e:
        cpu_usage = f"Error: {e}"

    try:
        mem = psutil.virtual_memory()
        mem_total_mb = mem.total // (1024**2)
        mem_used_mb = mem.used // (1024**2)
        mem_percent = mem.percent
    except Exception as e:
        mem_total_mb = mem_used_mb = mem_percent = f"Error: {e}"

    try:
        net = psutil.net_io_counters()
        bytes_sent = net.bytes_sent
        bytes_recv = net.bytes_recv
    except Exception as e:
        bytes_sent = bytes_recv = f"Error: {e}"

    try:
        disk_usage = shutil.disk_usage('/')._asdict()
        disk_usage_str = json.dumps(disk_usage, indent=2) # Nicer formatting
    except Exception as e:
        disk_usage_str = f"Error: {e}"

    diagnostics_info = {
        "uptime": uptime,
        "cpu_usage": f"{cpu_usage}%",
        "memory_total": f"{mem_total_mb} MB",
        "memory_used": f"{mem_used_mb} MB",
        "memory_percent": f"{mem_percent}%",
        "bytes_sent": bytes_sent,
        "bytes_recv": bytes_recv,
        "disk_usage": disk_usage_str
    }
    return render_template('diagnostics.html', info=diagnostics_info)

@app.route('/logs')
@auth.login_required
def logs():
    def read_log_safe(log_path):
        try:
            with open(log_path, 'r') as f:
                # Read last N lines for performance if logs get big
                lines = f.readlines()
                return "".join(lines[-100:]) # Show last 100 lines
        except FileNotFoundError:
            return f"Log file not found: {log_path}"
        except Exception as e:
            return f"Could not read log {os.path.basename(log_path)}: {e}"

    upload_log_content = read_log_safe(UPLOAD_LOG)
    offload_log_content = read_log_safe(OFFLOAD_LOG)

    return render_template('logs.html', upload=upload_log_content, offload=offload_log_content)

@app.route('/wifi', methods=['GET', 'POST'])
@auth.login_required
def wifi():
    """
    Wi-Fi Settings route: Allows adding a new Wi-Fi network by appending the configuration
    to /etc/wpa_supplicant/wpa_supplicant.conf. (Scanning is not implemented here.)
    Requires sudo privileges for wpa_cli. Ensure the web server user (zmakey)
    has passwordless sudo rights for 'wpa_cli -i wlan0 reconfigure'.
    WARNING: Granting sudo rights has security implications.
    """
    if request.method == 'POST':
        ssid = request.form.get('ssid') or request.form.get('custom_ssid')
        psk = request.form.get('psk')

        if not ssid or not psk:
            flash("SSID and Password are required.", "error")
            return redirect(url_for('wifi'))

        # Basic validation (improve as needed)
        if '"' in ssid or '\\' in ssid or '\n' in ssid:
            flash("Invalid characters in SSID.", "error")
            return redirect(url_for('wifi'))
        if '"' in psk or '\\' in psk or '\n' in psk:
             flash("Invalid characters in Password.", "error")
             return redirect(url_for('wifi'))

        # Generate config block (ensure newline at start if file exists and doesn't end with one)
        config_block = f'\nnetwork={{\n\tssid="{ssid}"\n\tpsk="{psk}"\n\tkey_mgmt=WPA-PSK\n}}\n'
        wpa_conf_path = '/etc/wpa_supplicant/wpa_supplicant.conf'

        try:
            # Check if file needs a leading newline
            needs_newline = False
            if os.path.exists(wpa_conf_path):
                 with open(wpa_conf_path, 'r') as f:
                    content = f.read()
                    if content and not content.endswith('\n'):
                        needs_newline = True

            # Append the config - requires write permission to /etc/wpa_supplicant/
            # This might require running the Flask app as root (not recommended)
            # or setting specific permissions (better).
            # For now, assume sudo is needed.
            # Creating a temporary file and using sudo tee is safer
            temp_config_path = os.path.join(BASE_DIR, "temp_wpa_append.txt")
            with open(temp_config_path, "w") as temp_f:
                if needs_newline:
                    temp_f.write("\n")
                temp_f.write(config_block)

            append_command = f"sudo tee -a {wpa_conf_path} < {temp_config_path}"
            result_append = subprocess.run(append_command, shell=True, capture_output=True, text=True)
            os.remove(temp_config_path) # Clean up temp file

            if result_append.returncode != 0:
                 flash(f"Error writing to wpa_supplicant.conf: {result_append.stderr}", "error")
                 return redirect(url_for('wifi'))

            # Reconfigure wlan0 - requires sudo
            reconfigure_command = ['sudo', 'wpa_cli', '-i', 'wlan0', 'reconfigure']
            result_reconfig = subprocess.run(reconfigure_command, capture_output=True, text=True)

            if result_reconfig.returncode == 0 and "OK" in result_reconfig.stdout:
                flash(f"Wi-Fi network '{ssid}' added. Reconfiguring interface...", "success")
            else:
                flash(f"Wi-Fi network added, but failed to reconfigure interface: {result_reconfig.stderr or result_reconfig.stdout}", "warning")

        except Exception as e:
            flash(f"Wi-Fi configuration failed: {e}", "error")
            print(f"Wi-Fi config failed: {e}")

        return redirect(url_for('wifi'))

    # Currently, no SSID scanning; pass an empty list.
    # Implementing scanning would require additional packages (like python-wifi)
    # and likely root/sudo privileges.
    return render_template('wifi.html', ssids=[])


@app.route('/notifications', methods=['GET', 'POST'])
@auth.login_required
def notifications():
    if request.method == 'POST':
        config = {
            "smtp_server": request.form.get("smtp_server", "").strip(),
            "smtp_port": request.form.get("smtp_port", "").strip(),
            "smtp_username": request.form.get("smtp_username", "").strip(),
            "smtp_password": request.form.get("smtp_password", ""), # Don't strip password
            "target_email": request.form.get("target_email", "").strip()
        }
        save_email_config(config)
        # Redirect to GET to show the saved config and success message
        return redirect(url_for('notifications'))

    config = load_email_config()
    return render_template('notifications.html', config=config)

@app.route('/backup_config')
@auth.login_required
def backup_config():
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    files_to_backup = [dotenv_path, EMAIL_CONFIG_PATH, RCLONE_CONFIG_PATH] # Add rclone config
    backed_up = []
    errors = []

    for file_path in files_to_backup:
        if os.path.exists(file_path):
            try:
                base_name = os.path.basename(file_path)
                backup_filename = f"{base_name}.{timestamp}.bak"
                dest_path = os.path.join(CONFIG_BACKUP_DIR, backup_filename)
                shutil.copy2(file_path, dest_path) # copy2 preserves metadata
                backed_up.append(backup_filename) # Show relative path in UI
            except Exception as e:
                errors.append(f"Error backing up {os.path.basename(file_path)}: {e}")
                print(f"Error backing up {file_path}: {e}")
        else:
             errors.append(f"Config file not found, skipped: {os.path.basename(file_path)}")


    if backed_up:
        flash(f"Configuration files backed up to {CONFIG_BACKUP_DIR}", "success")
    if errors:
        for error in errors:
            flash(error, "warning")

    # List existing backups in the backup directory for the template
    try:
        existing_backups = sorted(os.listdir(CONFIG_BACKUP_DIR), reverse=True)
    except Exception as e:
        existing_backups = []
        flash(f"Could not list existing backups: {e}", "error")

    return render_template('backup.html', backed_up_now=backed_up, existing_backups=existing_backups, backup_dir=CONFIG_BACKUP_DIR)


@app.route('/update_system')
@auth.login_required
def update_system():
    update_output = ""
    try:
        # Run git pull and restart service
        # Requires passwordless sudo for systemctl restart
        command = f"cd {BASE_DIR} && git pull && sudo systemctl restart pi-gunicorn"
        result = subprocess.run(command, shell=True, capture_output=True, text=True, check=True)
        update_output = result.stdout
        flash("System update attempted successfully via git pull.", "success")
    except subprocess.CalledProcessError as e:
        update_output = f"Error during update:\nSTDOUT:\n{e.stdout}\nSTDERR:\n{e.stderr}"
        flash(f"Error during system update: {e.stderr}", "error")
        print(f"Update Error: {update_output}")
    except Exception as e:
        update_output = f"An unexpected error occurred: {e}"
        flash(f"An unexpected error occurred during update: {e}", "error")
        print(f"Update Error: {update_output}")

    return render_template('update.html', output=update_output)


@app.route('/run/<action>')
@auth.login_required
def run_action(action):
    scripts = {
        'upload': os.path.join(BASE_DIR, 'upload_and_cleanup.sh'),
        'offload': os.path.join(BASE_DIR, 'offload.sh'),
        'retry': os.path.join(BASE_DIR, 'retry_offload.sh'), # Optional
        'eject': os.path.join(BASE_DIR, 'safe_eject.sh'),   # Optional
        'reboot': 'sudo reboot',
        'shutdown': 'sudo shutdown now'
    }
    if action in scripts:
        script_path = scripts[action]
        flash(f"Attempting to run action: {action}", "info")
        try:
            # Use Popen for background execution of shell scripts
            # Use run for immediate commands like reboot/shutdown (though they might kill the server)
            if action in ['reboot', 'shutdown']:
                 subprocess.run(script_path, shell=True)
            else:
                 # Ensure script is executable
                 if os.path.exists(script_path):
                     os.chmod(script_path, 0o755) # Ensure execute permissions
                     subprocess.Popen([script_path], shell=False, cwd=BASE_DIR) # Run in background
                     flash(f"Action '{action}' initiated.", "success")
                 else:
                     flash(f"Script for action '{action}' not found: {script_path}", "error")
                     print(f"Script not found: {script_path}")

        except Exception as e:
            flash(f"Failed to run action {action}: {e}", "error")
            print(f"Failed to run action {action}: {e}")
    else:
        flash(f"Unknown action: {action}", "error")

    # Redirect back to index, messages will be displayed via flash
    return redirect(url_for('index'))


@app.route('/check_creds')
# No login required here, it's for the initial redirect check
def check_creds():
    admin_username = os.getenv("ADMIN_USERNAME", "")
    admin_password = os.getenv("ADMIN_PASSWORD", "")
    creds_set = bool(admin_username and admin_password)
    return jsonify({"creds_set": creds_set})


@app.route('/credentials', methods=['GET', 'POST'])
def credentials():
    """
    Credentials page:
    - If no admin credentials exist in .env, allows setting them without authentication.
    - If they exist, requires current credentials (@auth.login_required applied) to change them.
    """
    admin_username = os.getenv("ADMIN_USERNAME", "")
    admin_password = os.getenv("ADMIN_PASSWORD", "")
    admin_exists = bool(admin_username and admin_password)

    # Apply authentication only if admin credentials already exist
    if admin_exists:
        auth_decorator = auth.login_required
    else:
        auth_decorator = lambda f: f # No-op decorator if creds don't exist

    @auth_decorator
    def handle_request():
        error_message = ""
        if request.method == "POST":
            new_user = request.form.get("new_username", "").strip()
            new_pass = request.form.get("new_password", "") # Don't strip password initially

            if not new_user or not new_pass:
                 error_message = "New username and password cannot be empty."
                 return render_template("credentials.html", admin_exists=admin_exists, error=error_message)

            if admin_exists:
                old_user = request.form.get("old_username", "").strip()
                old_pass = request.form.get("old_password", "")
                if old_user != admin_username or old_pass != admin_password:
                    error_message = "Current credentials do not match!"
                    # Don't return immediately, show the form again with the error
                else:
                    # Old credentials matched, proceed to update
                    pass # Fall through to update logic

            if not error_message: # Only update if no errors so far
                # Prepare new env values
                new_env_values = {
                    "ADMIN_USERNAME": new_user,
                    "ADMIN_PASSWORD": new_pass
                }
                if update_env_file(new_env_values):
                     # Redirect to index only on successful save
                     return redirect(url_for("index"))
                else:
                    # update_env_file already flashed an error
                    error_message = "Failed to save credentials. Check server logs."
                    # Fall through to render template with error

        # Render the form for GET request or POST with errors
        return render_template("credentials.html", admin_exists=admin_exists, error=error_message)

    return handle_request()


@app.route('/drive_auth', methods=['GET', 'POST'])
@auth.login_required # Always require login for Drive auth actions
def drive_auth():
    """
    Google Drive Authentication page:
    - GET: Generates an OAuth URL (via rclone) and displays it.
    - POST: Accepts an authentication token from the user and completes the auth process.
    Uses the RCLONE_CONFIG_PATH.
    """
    rclone_cmd = f'rclone --config "{RCLONE_CONFIG_PATH}"' # Base command

    if request.method == 'POST':
        auth_token = request.form.get('auth_token', "").strip()
        if auth_token:
            try:
                # Command to authorize using the token
                auth_command = f'{rclone_cmd} config update gdrive token \'{{"access_token":"","token_type":"Bearer","refresh_token":"","expiry":""}}\' --token \'{{"access_token":"","token_type":"Bearer","refresh_token":"{auth_token}","expiry":"0001-01-01T00:00:00Z"}}\''
                # Alternative using authorize (might behave differently depending on rclone version):
                # auth_command = f'{rclone_cmd} authorize drive --token \'{{"access_token":"","token_type":"Bearer","refresh_token":"{auth_token}","expiry":"0001-01-01T00:00:00Z"}}\''

                result = subprocess.run(auth_command, shell=True, capture_output=True, text=True, check=True)
                flash("Google Drive authentication successful! Rclone config updated.", "success")
                print(f"Rclone Auth Success: {result.stdout}")

                # Verify config exists
                if not os.path.exists(RCLONE_CONFIG_PATH):
                     flash("Warning: Rclone config file may not have been created.", "warning")

            except subprocess.CalledProcessError as e:
                flash(f"Authentication failed. Rclone command error: {e.stderr}", "error")
                print(f"Rclone Auth Error: {e.stderr}")
            except Exception as e:
                 flash(f"An unexpected error occurred during authentication: {e}", "error")
                 print(f"Rclone Auth Unexpected Error: {e}")
        else:
            flash("Please enter the authentication code obtained from Google.", "error")
        # Redirect back to the same page to show messages
        return redirect(url_for('drive_auth'))
    else: # GET Request
        auth_url = ""
        error_msg = ""
        try:
            # Generate the auth URL without opening a browser
            # Ensure a 'gdrive' remote exists or is being created. If not, this might fail.
            # Consider adding a check or setup step if 'gdrive' remote doesn't exist?
            # For now, assume user ran `rclone config` first to create the 'gdrive' remote stub.
            cmd = f'{rclone_cmd} authorize drive --no-browser'
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, check=True)

            # Parse the output to find the URL
            output_lines = result.stdout.splitlines()
            for line in output_lines:
                 if line.strip().startswith("https://accounts.google.com/"):
                     auth_url = line.strip()
                     break
            if not auth_url:
                 error_msg = "Could not find authorization URL in rclone output. Check logs."
                 print(f"Rclone Auth URL Generation Output:\n{result.stdout}")


        except subprocess.CalledProcessError as e:
            error_msg = f"Error generating auth URL. Ensure rclone is installed and configured with a 'gdrive' remote. Error: {e.stderr}"
            print(f"Rclone Auth URL Generation Error: {e.stderr}")
        except Exception as e:
            error_msg = f"An unexpected error occurred generating auth URL: {e}"
            print(f"Rclone Auth URL Generation Unexpected Error: {e}")

        if error_msg:
             flash(error_msg, "error")

        # Check if config file exists and if 'gdrive' remote is present
        gdrive_configured = False
        if os.path.exists(RCLONE_CONFIG_PATH):
            try:
                with open(RCLONE_CONFIG_PATH, 'r') as f:
                    if '[gdrive]' in f.read():
                        gdrive_configured = True
            except Exception as e:
                print(f"Could not read rclone config to check for gdrive: {e}")

        if not gdrive_configured:
             flash("Warning: Rclone config file not found or '[gdrive]' remote is missing. Please run 'rclone config' in the terminal first to create a remote named 'gdrive', saving the config to {}".format(RCLONE_CONFIG_PATH), "warning")


        return render_template('drive_auth.html', auth_url=auth_url, error_msg=error_msg, gdrive_configured=gdrive_configured)


# -------------------------
# Main Execution
# -------------------------
if __name__ == '__main__':
    # Make sure to set a proper secret key via environment variable or .env
    if app.secret_key == "default_insecure_secret_key_change_me!":
        print("WARNING: Using default Flask secret key. Set FLASK_SECRET_KEY environment variable.")

    # Listen on all interfaces (0.0.0.0) so it's accessible over the network
    # Use debug=False for production environments managed by Gunicorn/Nginx
    # The port 5000 is standard for Flask dev, Gunicorn will bind internally
    app.run(host='0.0.0.0', port=5000, debug=False)