#!/usr/bin/env bash
#
# install_jenkins.sh
# Installs Jenkins (latest LTS) on Ubuntu/Debian, along with Java 21
# and required dependencies, using the official pkg.jenkins.io repo.
#
# Usage:
#   chmod +x install_jenkins.sh
#   sudo ./install_jenkins.sh
#

set -euo pipefail
run_step() {
     echo "==========$1==========="
     sleep 3
}

JENKINS_KEY_URL="https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key"
KEYRING_DIR="/etc/apt/keyrings"
KEYRING_FILE="${KEYRING_DIR}/jenkins-keyring.asc"
REPO_FILE="/etc/apt/sources.list.d/jenkins.list"

# ---- Helper functions -------------------------------------------------

log() {
    echo -e "\n\033[1;32m==> $1\033[0m"
}

err() {
    echo -e "\033[1;31mERROR: $1\033[0m" >&2
    exit 1
}

# remove any carriage returns from this script (in case it was edited on Windows)
sed -i 's/\r$//' jenkins_install.sh

run_step "0. Pre-flight checks"

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root or with sudo. Try: sudo $0"
fi

if ! command -v apt-get &>/dev/null; then
    err "This script only supports Debian/Ubuntu systems (apt-get not found)."
fi

run_step "1. Update package index"

log "Updating package index..."
apt-get update -y

run_step "2. Install prerequisites"

log "Installing prerequisites (wget, gnupg, ca-certificates, fontconfig)..."
apt-get install -y wget gnupg ca-certificates apt-transport-https fontconfig

run_step "3. Install Java (Jenkins requires Java 21)"

log "Installing OpenJDK 21 (required by Jenkins)..."
apt-get install -y openjdk-21-jre

java -version

run_step "4. Clean up any old/broken Jenkins key or repo files"

log "Removing any stale Jenkins keyring/repo files..."
rm -f /usr/share/keyrings/jenkins-keyring.asc
rm -f "$KEYRING_FILE"
rm -f "$REPO_FILE"

mkdir -p "$KEYRING_DIR"

run_step "5. Fetch the current Jenkins repository key"

log "Fetching Jenkins repository GPG key..."
wget -O "$KEYRING_FILE" "$JENKINS_KEY_URL"

if [[ ! -s "$KEYRING_FILE" ]]; then
    err "Failed to download Jenkins key — $KEYRING_FILE is empty."
fi

run_step "6. Add the Jenkins apt repository"

log "Adding Jenkins apt repository..."
echo "deb [signed-by=${KEYRING_FILE}] https://pkg.jenkins.io/debian-stable binary/" \
    | tee "$REPO_FILE" >/dev/null

run_step "7. Install Jenkins"

log "Updating package index with Jenkins repo..."
apt-get update -y

log "Installing Jenkins..."
apt-get install -y jenkins

run_step "8. Start and enable Jenkins service"

log "Enabling and starting Jenkins service..."
systemctl enable jenkins
systemctl start jenkins

run_step "9. Configure firewall (if ufw is active) ------------------------------

if command -v ufw &>/dev/null; then
    if ufw status | grep -q "Status: active"; then
        log "UFW detected and active. Allowing port 8080 (Jenkins)..."
        ufw allow 8080/tcp
    fi
fi

run_step "10. Show status and initial admin password"

log "Checking Jenkins service status..."
systemctl status jenkins --no-pager || true

sleep 5
log "Jenkins installation complete!"
echo -e "\nAccess Jenkins in your browser at: http://<your-server-ip>:8080\n"

if [[ -f /var/lib/jenkins/secrets/initialAdminPassword ]]; then
    echo "Initial Admin Password:"
    cat /var/lib/jenkins/secrets/initialAdminPassword
    echo
else
    echo "Initial admin password file not found yet. Jenkins may still be starting."
    echo "Once running, retrieve it with:"
    echo "  sudo cat /var/lib/jenkins/secrets/initialAdminPassword"
fi

echo "sudo ss -tulnp | grep 8080"
