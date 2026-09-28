#!/usr/bin/env bash
#
# jenkins-install.sh
# Installs Jenkins (latest LTS) plus Java 21 on:
#   - Ubuntu / Debian            (apt, official pkg.jenkins.io debian-stable repo)
#   - Amazon Linux 2 / 2023      (yum/dnf, official pkg.jenkins.io redhat-stable repo,
#                                 Amazon Corretto 21)
#
# Usage:
#   chmod +x jenkins-install.sh
#   sudo ./jenkins-install.sh
#

set -euo pipefail

run_step() {
    echo "==========$1==========="
    sleep 3
}

log()  { echo -e "\n\033[1;32m==> $1\033[0m"; }
warn() { echo -e "\033[1;33mWARN: $1\033[0m" >&2; }
err()  { echo -e "\033[1;31mERROR: $1\033[0m" >&2; exit 1; }

# Remove any carriage returns from this script (in case it was edited on Windows)
SELF="${BASH_SOURCE[0]}"
[[ -f "$SELF" ]] && sed -i 's/\r$//' "$SELF"

# ---- Pre-flight -------------------------------------------------------

run_step "0. Pre-flight checks"

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root or with sudo. Try: sudo $0"
fi

os_field() { grep -E "^$1=" /etc/os-release | head -n1 | cut -d= -f2- | tr -d '"'; }
OS_ID="$(os_field ID)"
OS_ID_LIKE="$(os_field ID_LIKE)"

case "$OS_ID" in
    ubuntu|debian) FAMILY="debian" ;;
    amzn)          FAMILY="amazon" ;;
    *)
        if [[ "$OS_ID_LIKE" == *debian* ]]; then
            FAMILY="debian"
        else
            err "Unsupported OS '${OS_ID:-unknown}'. Supported: Ubuntu, Debian, Amazon Linux."
        fi
        ;;
esac
log "Detected OS: $OS_ID (family: $FAMILY)"

if command -v dnf &>/dev/null; then PKG=dnf; else PKG=yum; fi

# ---- Debian / Ubuntu --------------------------------------------------

install_jenkins_debian() {
    local key_url="https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key"
    local keyring_dir="/etc/apt/keyrings"
    local keyring_file="${keyring_dir}/jenkins-keyring.asc"
    local repo_file="/etc/apt/sources.list.d/jenkins.list"

    run_step "1. Update package index"
    apt-get update -y

    run_step "2. Install prerequisites"
    apt-get install -y wget gnupg ca-certificates apt-transport-https fontconfig

    run_step "3. Install Java (Jenkins requires Java 21)"
    apt-get install -y openjdk-21-jre
    java -version

    run_step "4. Clean up any old/broken Jenkins key or repo files"
    rm -f /usr/share/keyrings/jenkins-keyring.asc "$keyring_file" "$repo_file"
    mkdir -p "$keyring_dir"

    run_step "5. Fetch the current Jenkins repository key"
    wget -O "$keyring_file" "$key_url"
    [[ -s "$keyring_file" ]] || err "Failed to download Jenkins key - $keyring_file is empty."

    run_step "6. Add the Jenkins apt repository"
    echo "deb [signed-by=${keyring_file}] https://pkg.jenkins.io/debian-stable binary/" \
        | tee "$repo_file" >/dev/null

    run_step "7. Install Jenkins"
    apt-get update -y
    apt-get install -y jenkins
}

# ---- Amazon Linux -----------------------------------------------------

install_jenkins_amazon() {
    local repo_file="/etc/yum.repos.d/jenkins.repo"

    run_step "1. Install prerequisites"
    $PKG install -y fontconfig

    run_step "2. Install Java (Jenkins requires Java 21)"
    if ! $PKG install -y java-21-amazon-corretto-headless; then
        warn "Corretto 21 not in the default repos - adding the Amazon Corretto repo..."
        rpm --import https://yum.corretto.aws/corretto.key
        curl -fsSL -o /etc/yum.repos.d/corretto.repo https://yum.corretto.aws/corretto.repo
        $PKG install -y java-21-amazon-corretto-devel
    fi
    java -version

    run_step "3. Add the Jenkins yum repository"
    rm -f "$repo_file"
    curl -fsSL -o "$repo_file" https://pkg.jenkins.io/redhat-stable/jenkins.repo
    [[ -s "$repo_file" ]] || err "Failed to download $repo_file"

    # Import whatever signing key the repo file currently points at
    local key_url
    key_url="$(grep -E '^gpgkey=' "$repo_file" | head -n1 | cut -d= -f2- || true)"
    if [[ -n "$key_url" ]]; then
        log "Importing Jenkins key: $key_url"
        rpm --import "$key_url"
    fi

    run_step "4. Install Jenkins"
    $PKG install -y jenkins
    systemctl daemon-reload
}

if [[ "$FAMILY" == "debian" ]]; then
    install_jenkins_debian
else
    install_jenkins_amazon
fi

# ---- Common -----------------------------------------------------------

run_step "8. Start and enable Jenkins service"
systemctl enable jenkins
systemctl start jenkins

run_step "9. Configure firewall (if active)"
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    log "UFW active. Allowing port 8080 (Jenkins)..."
    ufw allow 8080/tcp
elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
    log "firewalld active. Allowing port 8080 (Jenkins)..."
    firewall-cmd --permanent --add-port=8080/tcp
    firewall-cmd --reload
else
    log "No active host firewall detected (on AWS, open TCP 8080 in the instance's security group)."
fi

run_step "10. Show status and initial admin password"
systemctl status jenkins --no-pager || true

# Jenkins can take a little while to generate the password on first start
for _ in $(seq 1 30); do
    [[ -f /var/lib/jenkins/secrets/initialAdminPassword ]] && break
    sleep 2
done

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

echo "To confirm Jenkins is listening:  sudo ss -tulnp | grep 8080"
