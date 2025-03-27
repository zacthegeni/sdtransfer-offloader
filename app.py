from flask import Flask, request, render_template, redirect, url_for, jsonify
import subprocess, shutil, os, json, psutil, datetime
from flask_httpauth import HTTPBasicAuth
from dotenv import load_dotenv

load_dotenv('.env')
app = Flask(__name__)
auth = HTTPBasicAuth()

@auth.verify_password
def verify_password(username, password):
    admin_username = os.getenv("ADMIN_USERNAME", "")
    admin_password = os.getenv("ADMIN_PASSWORD", "")
    # If no credentials are set, allow access.
    if not admin_username or not admin_password:
        return True
    return (username == admin_username) and (password == admin_password)

UPLOAD_LOG = os.getenv("UPLOAD_LOG", "/home/pi/rclone.log")
OFFLOAD_LOG = os.getenv("OFFLOAD_LOG", "/home/pi/offload.log")
EMAIL_CONFIG_PATH = '/home/pi/pi-offloader/email_config.json'

def load_email_config():
    try:
        with open(EMAIL_CONFIG_PATH, 'r') as f:
            return json.load(f)
    except:
        return {"smtp_server": "", "smtp_port": "", "smtp_username": "", "smtp_password": "", "target_email": ""}

def save_email_config(config):
    with open(EMAIL_CONFIG_PATH, 'w') as f:
        json.dump(config, f)

@app.route('/')
@auth.login_required
def index():
    usage = shutil.disk_usage("/")
    free_space = f"{usage.free // (2**20)} MB free"
    cpu_usage = psutil.cpu_percent(interval=1)
    mem_usage = psutil.virtual_memory().percent
    return render_template('index.html', space=free_space, cpu=cpu_usage, mem=mem_usage)

@app.route('/status')
@auth.login_required
def status():
    usage = shutil.disk_usage("/")
    free_space = usage.free // (2**20)
    return jsonify({'free_space': f"{free_space} MB free"})

@app.route('/diagnostics')
@auth.login_required
def diagnostics():
    uptime = subprocess.check_output("uptime -p", shell=True).decode().strip()
    cpu_usage = psutil.cpu_percent(interval=1)
    mem = psutil.virtual_memory()
    net = psutil.net_io_counters()
    diagnostics_info = {
        "uptime": uptime,
        "cpu_usage": f"{cpu_usage}%",
        "memory_total": f"{mem.total // (1024**2)} MB",
        "memory_used": f"{mem.used // (1024**2)} MB",
        "memory_percent": f"{mem.percent}%",
        "bytes_sent": net.bytes_sent,
        "bytes_recv": net.bytes_recv,
        "disk_usage": f"{shutil.disk_usage('/')._asdict()}"
    }
    return render_template('diagnostics.html', info=diagnostics_info)

@app.route('/logs')
@auth.login_required
def logs():
    try:
        with open(UPLOAD_LOG) as f:
            upload = f.read()
    except Exception as e:
        upload = f"Could not read upload log: {e}"
    try:
        with open(OFFLOAD_LOG) as f:
            offload = f.read()
    except Exception as e:
        offload = f"Could not read offload log: {e}"
    return render_template('logs.html', upload=upload, offload=offload)

@app.route('/wifi', methods=['GET', 'POST'])
@auth.login_required
def wifi():
    if request.method == 'POST':
        ssid = request.form.get('ssid') or request.form.get('custom_ssid')
        psk = request.form.get('psk')
        config = f'\nnetwork={{\n ssid="{ssid}"\n psk="{psk}"\n}}\n'
        try:
            with open('/etc/wpa_supplicant/wpa_supplicant.conf', 'a') as f:
                f.write(config)
            subprocess.run(['sudo', 'wpa_cli', '-i', 'wlan0', 'reconfigure'])
        except Exception as e:
            print(f"Wi-Fi config failed: {e}")
        return redirect(url_for('wifi'))
    return render_template('wifi.html')

@app.route('/notifications', methods=['GET', 'POST'])
@auth.login_required
def notifications():
    if request.method == 'POST':
        config = {
            "smtp_server": request.form.get("smtp_server", ""),
            "smtp_port": request.form.get("smtp_port", ""),
            "smtp_username": request.form.get("smtp_username", ""),
            "smtp_password": request.form.get("smtp_password", ""),
            "target_email": request.form.get("target_email", "")
        }
        save_email_config(config)
        return redirect(url_for('notifications'))
    config = load_email_config()
    return render_template('notifications.html', config=config)

@app.route('/backup_config')
@auth.login_required
def backup_config():
    backup_dir = "/home/pi/config_backups"
    os.makedirs(backup_dir, exist_ok=True)
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    files_to_backup = ["/home/pi/pi-offloader/.env", EMAIL_CONFIG_PATH]
    backed_up = []
    for file in files_to_backup:
        if os.path.exists(file):
            dest = os.path.join(backup_dir, os.path.basename(file) + "." + timestamp)
            subprocess.run(["cp", file, dest])
            backed_up.append(dest)
    return render_template('backup.html', files=backed_up)

@app.route('/update_system')
@auth.login_required
def update_system():
    update_output = subprocess.getoutput("cd /home/pi/pi-offloader && git pull && sudo systemctl restart pi-gunicorn")
    return render_template('update.html', output=update_output)

@app.route('/run/<action>')
@auth.login_required
def run_action(action):
    scripts = {
        'upload': '/home/pi/upload_and_cleanup.sh',
        'offload': '/home/pi/offload.sh',
        'retry': '/home/pi/retry_offload.sh',
        'eject': '/home/pi/safe_eject.sh',
        'reboot': 'sudo reboot',
        'shutdown': 'sudo shutdown now'
    }
    if action in scripts:
        try:
            subprocess.Popen(scripts[action], shell=True)
        except Exception as e:
            print(f"Failed to run action {action}: {e}")
    return redirect('/')

# Returns JSON indicating if credentials are set or not
@app.route('/check_creds')
def check_creds():
    admin_username = os.getenv("ADMIN_USERNAME", "")
    admin_password = os.getenv("ADMIN_PASSWORD", "")
    if not admin_username or not admin_password:
        return jsonify({"creds_set": False})
    return jsonify({"creds_set": True})

# Credentials route - if creds exist, require old username/password to change
@app.route('/credentials', methods=['GET', 'POST'])
def credentials():
    admin_username = os.getenv("ADMIN_USERNAME", "")
    admin_password = os.getenv("ADMIN_PASSWORD", "")
    
    if request.method == "POST":
        # If credentials already exist, user must provide old credentials
        if admin_username and admin_password:
            old_user = request.form.get("old_username")
            old_pass = request.form.get("old_password")
            if old_user != admin_username or old_pass != admin_password:
                # Old credentials don't match
                return render_template('credentials.html', 
                                       error="Old credentials do not match!", 
                                       admin_exists=True)
        
        # Either no creds exist or old creds matched, so set new creds
        new_user = request.form.get("new_username")
        new_pass = request.form.get("new_password")
        
        env_content = (
            f"ADMIN_USERNAME={new_user}\n"
            f"ADMIN_PASSWORD={new_pass}\n"
            f"UPLOAD_LOG=/home/pi/rclone.log\n"
            f"OFFLOAD_LOG=/home/pi/offload.log\n"
        )
        with open(".env", "w") as f:
            f.write(env_content)
        load_dotenv(".env")
        
        return redirect(url_for("index"))
    
    # GET request
    admin_exists = bool(admin_username and admin_password)
    return render_template('credentials.html', 
                           admin_exists=admin_exists,
                           error="")

if __name__ == '__main__':
    app.run('0.0.0.0', port=5000)
