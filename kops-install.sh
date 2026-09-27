#!/usr/bin/env bash
#
# kops-setup.sh - Install kops + kubectl and create a Kubernetes cluster on AWS
#
# Usage:
#   ./kops-setup.sh install     Install kubectl, kops (and AWS CLI on Linux if missing)
#   ./kops-setup.sh create      Create S3 state bucket + cluster, wait until healthy
#   ./kops-setup.sh all         install + create
#   ./kops-setup.sh validate    Validate an existing cluster
#   ./kops-setup.sh delete      Delete the cluster (asks for confirmation)
#
# When run in a terminal, create/all ask for each cluster setting with `read`
# (press Enter to keep the value shown in [brackets]). validate/delete ask only
# for the cluster name and region. Prompts are skipped when ASSUME_YES=true,
# PROMPT=false, or input is not a terminal.
#
# If the script stops unexpectedly, the failing line and command are printed.
# Run with DEBUG=true to trace every command.
#
# Every setting below can also be set with an environment variable, which becomes
# the default shown in the prompt, e.g.:
#   CLUSTER_NAME=dev.k8s.local NODE_COUNT=3 AWS_REGION=eu-west-1 ./kops-setup.sh all
#
# Prerequisites:
#   - AWS credentials configured (`aws configure` or env vars / SSO profile)
#   - The IAM user/role needs: EC2, ELB, Auto Scaling, IAM, S3, SQS, EventBridge,
#     and Route53 (only if you use a real DNS name instead of gossip DNS).
#
set -Eeuo pipefail

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
# Names ending in ".k8s.local" use gossip DNS (no Route53 hosted zone needed).
# For a real domain use e.g. CLUSTER_NAME=k8s.example.com (needs a Route53 zone).
CLUSTER_NAME="${CLUSTER_NAME:-demo.k8s.local}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ZONES="${ZONES:-}"                                                    # empty = <region>a,b,c (worker zones)
CONTROL_PLANE_ZONES="${CONTROL_PLANE_ZONES:-}"                        # empty = <region>a (1 zone = 1 control-plane node)
NODE_COUNT="${NODE_COUNT:-2}"
NODE_SIZE="${NODE_SIZE:-t3.medium}"
CONTROL_PLANE_SIZE="${CONTROL_PLANE_SIZE:-t3.medium}"
K8S_VERSION="${K8S_VERSION:-}"                                        # empty = kops default
KOPS_VERSION="${KOPS_VERSION:-}"                                      # empty = latest release
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$HOME/.ssh/id_rsa.pub}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
VALIDATE_TIMEOUT="${VALIDATE_TIMEOUT:-15m}"
ASSUME_YES="${ASSUME_YES:-false}"                                     # true = skip all prompts
PROMPT="${PROMPT:-true}"                                              # false = don't ask for settings
KOPS_STATE_BUCKET="${KOPS_STATE_BUCKET:-}"                            # empty = auto-generated

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

WORKDIR=""
cleanup() { [[ -n "$WORKDIR" ]] && rm -rf "$WORKDIR"; return 0; }
trap cleanup EXIT

# Report exactly which command made the script stop (errexit is otherwise silent).
on_err() {
  local code="$1" line="$2" cmd="$3"
  printf '\033[1;31mERROR:\033[0m command failed (exit %s) at line %s:\n         %s\n' "$code" "$line" "$cmd" >&2
}
trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR

# DEBUG=true ./script.sh ...  prints every command as it runs.
if [[ "${DEBUG:-false}" == "true" ]]; then set -x; fi

confirm() {
  [[ "$ASSUME_YES" == "true" ]] && return 0
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# Fill in zone defaults from the region if they were not set explicitly.
apply_zone_defaults() {
  [[ -n "$ZONES" ]] || ZONES="${AWS_REGION}a,${AWS_REGION}b,${AWS_REGION}c"
  [[ -n "$CONTROL_PLANE_ZONES" ]] || CONTROL_PLANE_ZONES="${AWS_REGION}a"
  return 0
}

# ask VAR "Label" - show the current value as the default and read a new one.
ask() {
  local var="$1" label="$2" current reply=""
  current="${!var}"
  read -r -p "  ${label} [${current:-<default>}]: " reply || true
  if [[ -n "$reply" ]]; then
    printf -v "$var" '%s' "$reply"
  fi
  return 0
}

# prompt_config full|basic - interactively collect settings with `read`.
prompt_config() {
  local mode="${1:-full}"
  if [[ "$PROMPT" != "true" || "$ASSUME_YES" == "true" || ! -t 0 ]]; then
    apply_zone_defaults
    return 0
  fi

  echo
  log "Enter values (press Enter to keep the value shown in [brackets]):"
  ask CLUSTER_NAME "Cluster name"
  ask AWS_REGION   "AWS region"
  apply_zone_defaults    # zone defaults depend on the region just entered

  if [[ "$mode" == "full" ]]; then
    ask ZONES               "Worker node zones (comma-separated)"
    ask CONTROL_PLANE_ZONES "Control-plane zones (1 zone = 1 node)"
    ask NODE_COUNT          "Worker node count"
    ask NODE_SIZE           "Worker instance type"
    ask CONTROL_PLANE_SIZE  "Control-plane instance type"
    ask K8S_VERSION         "Kubernetes version (blank = kops default)"
    ask SSH_PUBLIC_KEY      "SSH public key path"
    ask VALIDATE_TIMEOUT    "Validation timeout"
  fi
  echo

  [[ -n "$CLUSTER_NAME" ]] || die "Cluster name cannot be empty."
  [[ -n "$AWS_REGION" ]]   || die "AWS region cannot be empty."
  [[ "$NODE_COUNT" =~ ^[0-9]+$ && "$NODE_COUNT" -ge 1 ]] || die "Worker node count must be a positive number."
}

SUDO=""
detect_sudo() {
  if [[ ! -w "$INSTALL_DIR" ]]; then
    have sudo || die "$INSTALL_DIR is not writable and sudo is not available. Set INSTALL_DIR to a writable path."
    SUDO="sudo"
  fi
}

detect_platform() {
  case "$(uname -s)" in
    Linux)  OS="linux" ;;
    Darwin) OS="darwin" ;;
    *) die "Unsupported OS: $(uname -s). Use Linux or macOS (or WSL on Windows)." ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

verify_sha256() {  # verify_sha256 <file> <expected_hash>
  local file="$1" expected="$2" actual
  if have sha256sum; then
    actual="$(sha256sum "$file" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  fi
  [[ "$actual" == "$expected" ]] || die "Checksum mismatch for $file"
}

# --------------------------------------------------------------------------
# Installers
# --------------------------------------------------------------------------
install_kubectl() {
  if have kubectl; then
    log "kubectl already installed: $(kubectl version --client 2>/dev/null | head -n1)"
    return
  fi
  log "Installing kubectl..."
  local ver
  ver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSL -o "$WORKDIR/kubectl" "https://dl.k8s.io/release/${ver}/bin/${OS}/${ARCH}/kubectl"
  verify_sha256 "$WORKDIR/kubectl" "$(curl -fsSL "https://dl.k8s.io/release/${ver}/bin/${OS}/${ARCH}/kubectl.sha256")"
  $SUDO install -m 0755 "$WORKDIR/kubectl" "$INSTALL_DIR/kubectl"
  log "Installed kubectl ${ver}"
}

install_kops() {
  local ver="$KOPS_VERSION"
  if [[ -z "$ver" ]]; then
    ver="$(curl -fsSL https://api.github.com/repos/kubernetes/kops/releases/latest \
            | grep '"tag_name"' | head -n1 | cut -d '"' -f 4 || true)"
    [[ -n "$ver" ]] || die "Could not determine latest kops version (GitHub rate limit?). Set KOPS_VERSION=v1.xx.x"
  fi

  if have kops && [[ "$(kops version 2>/dev/null)" == *"${ver#v}"* ]]; then
    log "kops ${ver} already installed"
    return
  fi

  log "Installing kops ${ver}..."
  local url
  url="https://github.com/kubernetes/kops/releases/download/${ver}/kops-${OS}-${ARCH}"
  curl -fsSL -o "$WORKDIR/kops" "$url"
  if curl -fsSL -o "$WORKDIR/kops.sha256" "${url}.sha256" 2>/dev/null; then
    verify_sha256 "$WORKDIR/kops" "$(awk '{print $1}' "$WORKDIR/kops.sha256")"
  else
    warn "No checksum file found for kops ${ver}; skipping verification."
  fi
  $SUDO install -m 0755 "$WORKDIR/kops" "$INSTALL_DIR/kops"
  log "Installed $(kops version | head -n1)"
}

install_unzip() {
  have unzip && return 0
  log "unzip not found - installing it..."
  local pkg_sudo=""
  if [[ "$EUID" -ne 0 ]]; then
    have sudo || die "'unzip' is missing and sudo is not available to install it. Install unzip manually and re-run."
    pkg_sudo="sudo"
  fi
  if   have apt-get; then $pkg_sudo apt-get update -y >/dev/null && $pkg_sudo apt-get install -y unzip
  elif have dnf;     then $pkg_sudo dnf install -y unzip
  elif have yum;     then $pkg_sudo yum install -y unzip
  elif have zypper;  then $pkg_sudo zypper --non-interactive install unzip
  elif have apk;     then $pkg_sudo apk add --no-cache unzip
  elif have pacman;  then $pkg_sudo pacman -Sy --noconfirm unzip
  else die "No supported package manager found. Install 'unzip' manually and re-run."
  fi
  have unzip || die "unzip installation failed. Install it manually and re-run."
}

install_awscli() {
  if have aws; then
    log "AWS CLI already installed: $(aws --version 2>&1 | head -n1)"
    return
  fi
  if [[ "$OS" != "linux" ]]; then
    die "AWS CLI not found. Install it first (macOS: 'brew install awscli')."
  fi
  install_unzip
  log "Installing AWS CLI v2..."
  local arch
  [[ "$ARCH" == "arm64" ]] && arch="aarch64" || arch="x86_64"
  curl -fsSL -o "$WORKDIR/awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip"
  unzip -q "$WORKDIR/awscliv2.zip" -d "$WORKDIR"
  ${SUDO:-} "$WORKDIR/aws/install" --update
  log "Installed $(aws --version 2>&1 | head -n1)"
}

do_install() {
  have curl || die "curl is required."
  detect_platform
  detect_sudo
  WORKDIR="$(mktemp -d)"
  install_awscli
  install_kubectl
  install_kops
}

# --------------------------------------------------------------------------
# Cluster operations
# --------------------------------------------------------------------------
preflight() {
  have aws     || die "aws CLI not found. Run: $0 install"
  have kops    || die "kops not found. Run: $0 install"
  have kubectl || die "kubectl not found. Run: $0 install"

  export AWS_DEFAULT_REGION="$AWS_REGION"
  local account
  account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
    || die "AWS credentials are not configured or have expired. Run 'aws configure' (or 'aws sso login')."

  KOPS_STATE_BUCKET="${KOPS_STATE_BUCKET:-kops-state-${account}-${AWS_REGION}}"
  export KOPS_STATE_STORE="s3://${KOPS_STATE_BUCKET}"
}

ensure_ssh_key() {
  if [[ -f "$SSH_PUBLIC_KEY" ]]; then
    return
  fi
  log "No SSH public key at $SSH_PUBLIC_KEY - generating one..."
  local private="${SSH_PUBLIC_KEY%.pub}"
  mkdir -p "$(dirname "$private")"
  ssh-keygen -t rsa -b 4096 -N "" -f "$private" -C "kops-${CLUSTER_NAME}" >/dev/null
}

ensure_state_bucket() {
  if aws s3api head-bucket --bucket "$KOPS_STATE_BUCKET" 2>/dev/null; then
    log "State bucket s3://${KOPS_STATE_BUCKET} already exists"
    return
  fi

  log "Creating state bucket s3://${KOPS_STATE_BUCKET}..."
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$KOPS_STATE_BUCKET" --region "$AWS_REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$KOPS_STATE_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi

  aws s3api put-bucket-versioning --bucket "$KOPS_STATE_BUCKET" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$KOPS_STATE_BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "$KOPS_STATE_BUCKET" \
    --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
}

print_summary() {
  cat <<EOF

  Cluster name        : ${CLUSTER_NAME}
  Region              : ${AWS_REGION}
  Worker zones        : ${ZONES}
  Control-plane zones : ${CONTROL_PLANE_ZONES}
  Worker nodes        : ${NODE_COUNT} x ${NODE_SIZE}
  Control-plane size  : ${CONTROL_PLANE_SIZE}
  Kubernetes version  : ${K8S_VERSION:-<kops default>}
  State store         : ${KOPS_STATE_STORE}
  SSH public key      : ${SSH_PUBLIC_KEY}

EOF
}

do_create() {
  preflight
  log "Cluster configuration:"
  print_summary
  confirm "Create this cluster? (this will launch billable AWS resources)" || die "Aborted."

  ensure_ssh_key
  ensure_state_bucket

  if kops get cluster --name "$CLUSTER_NAME" >/dev/null 2>&1; then
    warn "Cluster ${CLUSTER_NAME} already exists in the state store - skipping 'create cluster'."
  else
    local args=(
      create cluster
      --name "$CLUSTER_NAME"
      --cloud aws
      --zones "$ZONES"
      --control-plane-zones "$CONTROL_PLANE_ZONES"
      --node-count "$NODE_COUNT"
      --node-size "$NODE_SIZE"
      --control-plane-size "$CONTROL_PLANE_SIZE"
      --ssh-public-key "$SSH_PUBLIC_KEY"
    )
    [[ -n "$K8S_VERSION" ]] && args+=(--kubernetes-version "$K8S_VERSION")

    log "Creating cluster spec..."
    kops "${args[@]}"
  fi

  log "Applying cluster (this provisions the AWS resources)..."
  kops update cluster --name "$CLUSTER_NAME" --yes --admin

  do_validate
}

do_validate() {
  preflight
  log "Waiting up to ${VALIDATE_TIMEOUT} for the cluster to become ready..."
  kops validate cluster --name "$CLUSTER_NAME" --wait "$VALIDATE_TIMEOUT"
  log "Cluster is ready. Try: kubectl get nodes"
}

do_delete() {
  preflight
  warn "This will DESTROY cluster ${CLUSTER_NAME} and all its AWS resources."
  confirm "Are you sure?" || die "Aborted."
  kops delete cluster --name "$CLUSTER_NAME" --yes
  log "Cluster deleted. The state bucket s3://${KOPS_STATE_BUCKET} was left in place."
}

usage() {
  sed -n '3,/^# Prerequisites:/{/^# Prerequisites:/!p}' "$0" | sed 's/^# \{0,1\}//'
}

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------
case "${1:-help}" in
  install)  do_install ;;
  create)   prompt_config full;  do_create ;;
  all)      do_install; prompt_config full;  do_create ;;
  validate) prompt_config basic; do_validate ;;
  delete)   prompt_config basic; do_delete ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
