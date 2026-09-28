#!/usr/bin/env bash
#
# terraform-install.sh
# Installs Terraform from HashiCorp's official repositories on:
#   - Ubuntu / Debian        (apt)
#   - Amazon Linux 2 / 2023  (yum/dnf)
#
# Usage:
#   chmod +x terraform-install.sh
#   ./terraform-install.sh            # installs the latest version
#   ./terraform-install.sh 1.9.5      # installs a specific version

set -euo pipefail

VERSION="${1:-}"

SUDO=""
if [[ $EUID -ne 0 ]]; then
    command -v sudo &>/dev/null || { echo "ERROR: run as root or install sudo." >&2; exit 1; }
    SUDO="sudo"
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
            echo "ERROR: Unsupported OS '${OS_ID:-unknown}'. Supported: Ubuntu, Debian, Amazon Linux." >&2
            exit 1
        fi
        ;;
esac
echo "==> Detected OS: $OS_ID (family: $FAMILY)"

if [[ "$FAMILY" == "debian" ]]; then
    echo "==> Updating package index..."
    $SUDO apt-get update -y

    echo "==> Installing prerequisites (gnupg, curl, ca-certificates, lsb-release)..."
    $SUDO apt-get install -y gnupg curl ca-certificates lsb-release

    echo "==> Adding the HashiCorp GPG key..."
    curl -fsSL https://apt.releases.hashicorp.com/gpg | \
      $SUDO gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

    CODENAME="$(os_field VERSION_CODENAME)"
    [[ -n "$CODENAME" ]] || CODENAME="$(lsb_release -cs)"

    echo "==> Adding the HashiCorp apt repository..."
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${CODENAME} main" | \
      $SUDO tee /etc/apt/sources.list.d/hashicorp.list > /dev/null

    echo "==> Updating package index again..."
    $SUDO apt-get update -y

    if [[ -z "$VERSION" ]]; then
        echo "==> Installing latest Terraform..."
        $SUDO apt-get install -y terraform
    else
        echo "==> Installing Terraform version ${VERSION}..."
        $SUDO apt-get install -y "terraform=${VERSION}-*"
    fi
else
    if command -v dnf &>/dev/null; then PKG=dnf; else PKG=yum; fi

    echo "==> Adding the HashiCorp yum repository..."
    $SUDO curl -fsSL -o /etc/yum.repos.d/hashicorp.repo \
      https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo

    if [[ -z "$VERSION" ]]; then
        echo "==> Installing latest Terraform..."
        $SUDO $PKG install -y terraform
    else
        echo "==> Installing Terraform version ${VERSION}..."
        $SUDO $PKG install -y "terraform-${VERSION}"
    fi
fi

echo "==> Verifying installation..."
terraform -version

echo "==> Done. Terraform installed successfully."
