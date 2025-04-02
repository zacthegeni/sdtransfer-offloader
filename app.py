from flask import Flask, render_template, redirect, url_for, request, flash
import os
import subprocess
from flask_httpauth import HTTPBasicAuth
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__)
app.secret_key = 'your_secret_key'  # Replace with your actual secret key

auth = HTTPBasicAuth()

users = {
    "admin": generate_password_hash("password")
}

@auth.verify_password
def verify_password(username, password):
    if username in users and check_password_hash(users.get(username), password):
        return username

@app.route('/')
@auth.login_required
def index():
    return render_template('index.html')

@app.route('/clean-local-storage', methods=['POST'])
def clean_local_storage():
    try:
        subprocess.run(["/home/zmakey/sdtransfer-offloader/clean_local_storage.sh"], check=True)
        flash("Local footage storage cleaned successfully.", "success")
    except subprocess.CalledProcessError:
        flash("Failed to clean local storage.", "error")
    return redirect(url_for('index'))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
