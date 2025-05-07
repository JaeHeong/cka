#!/bin/bash
# Script to set up container runtime (containerd) for Kubernetes.
# Based on https://kubernetes.io/docs/setup/production-environment/container-runtimes/
# Original script changes March 14 2023: introduced $PLATFORM for amd64/arm64.
# This version (May 07 2025): Adapted for Amazon Linux 2023 and improved robustness.
# This version (May 07 2025 UTC): Added --allowerasing for dnf on AL2023 to handle curl conflicts.

set -e # Exit immediately if a command exits with a non-zero status.
# set -x # Uncomment for debug mode

echo "Starting container runtime setup script..."

# Determine OS and Architecture
PLATFORM=""
CURRENT_ARCH=$(arch)
if [ "$CURRENT_ARCH" = "aarch64" ]; then
    PLATFORM="arm64"
elif [ "$CURRENT_ARCH" = "x86_64" ]; then
    PLATFORM="amd64"
else
    echo "ERROR: Unsupported architecture: $CURRENT_ARCH"
    exit 1
fi

OS_NAME=""
OS_VERSION_ID=""
if [ -f /etc/os-release ]; then
    . /etc/os-release # Source the file to get $NAME, $VERSION_ID etc.
    OS_NAME=$NAME
    OS_VERSION_ID=$VERSION_ID
else
    echo "ERROR: Cannot determine OS information from /etc/os-release. This script cannot proceed."
    exit 1
fi

echo "Detected OS: $OS_NAME $OS_VERSION_ID, Architecture: $PLATFORM ($CURRENT_ARCH)"

# Common prerequisite function for kernel modules and sysctl
setup_kernel_prereqs() {
    echo "INFO: Setting up kernel prerequisites (modules and sysctl)..."
    cat <<- EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

    sudo modprobe overlay
    sudo modprobe br_netfilter

    # Setup required sysctl params, these persist across reboots.
    cat <<- EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

    # Apply sysctl params without reboot
    sudo sysctl --system
    echo "INFO: Kernel prerequisites set."
}

# Common function to install containerd and runc from binaries
install_containerd_runc_from_binary() {
    echo "INFO: Installing containerd and runc from binaries..."

    echo "INFO: Installing prerequisites (jq, curl, wget)..."
    if [ "$OS_NAME" = "Ubuntu" ]; then
        sudo apt-get update -qq
        sudo apt-get install -y jq curl wget
    elif [ "$OS_NAME" = "Amazon Linux" ] && [[ "$OS_VERSION_ID" == "2023"* ]]; then
        # On AL2023, dnf is the default. yum is often an alias.
        # Added --allowerasing to handle conflicts with pre-installed minimal packages like curl-minimal
        sudo dnf install -y --allowerasing jq curl wget
    else
        echo "WARNING: OS '$OS_NAME' not explicitly handled for prerequisite installation (jq, curl, wget)."
        echo "         Please ensure they are installed. Attempting to proceed..."
        if ! command -v jq &> /dev/null || ! command -v curl &> /dev/null || ! command -v wget &> /dev/null; then
            echo "ERROR: jq, curl, or wget not found. Please install them manually for $OS_NAME."
            exit 1
        fi
    fi

    # (Install containerd)
    echo "INFO: Fetching latest containerd version..."
    CONTAINERD_VERSION_TAG=$(curl -s https://api.github.com/repos/containerd/containerd/releases/latest | jq -r '.tag_name')
    if [ -z "$CONTAINERD_VERSION_TAG" ] || [ "$CONTAINERD_VERSION_TAG" == "null" ]; then
        echo "ERROR: Could not fetch latest containerd version tag from GitHub API."
        exit 1
    fi
    CONTAINERD_VERSION=${CONTAINERD_VERSION_TAG#v} # Remove 'v' prefix
    echo "INFO: Latest containerd version: $CONTAINERD_VERSION"

    echo "INFO: Downloading containerd v${CONTAINERD_VERSION} for ${PLATFORM}..."
    wget --quiet "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-${PLATFORM}.tar.gz" -O "/tmp/containerd-${CONTAINERD_VERSION}-linux-${PLATFORM}.tar.gz"
    echo "INFO: Extracting containerd to /usr/local..."
    sudo tar xvf "/tmp/containerd-${CONTAINERD_VERSION}-linux-${PLATFORM}.tar.gz" -C /usr/local
    rm "/tmp/containerd-${CONTAINERD_VERSION}-linux-${PLATFORM}.tar.gz"

    # Configure containerd
    echo "INFO: Configuring containerd..."
    sudo mkdir -p /etc/containerd
    cat <<- TOML | sudo tee /etc/containerd/config.toml
version = 2
[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    [plugins."io.containerd.grpc.v1.cri".containerd]
      # snapshotter = "overlayfs" # Explicitly set if needed, often defaults correctly
      default_runtime_name = "runc"
      discard_unpacked_layers = true # Set to false if layer caching is critical and disk space is not an issue
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true
TOML

    # Install runc
    echo "INFO: Fetching latest runc version..."
    RUNC_VERSION_TAG=$(curl -s https://api.github.com/repos/opencontainers/runc/releases/latest | jq -r '.tag_name')
    if [ -z "$RUNC_VERSION_TAG" ] || [ "$RUNC_VERSION_TAG" == "null" ]; then
        echo "ERROR: Could not fetch latest runc version tag from GitHub API."
        exit 1
    fi
    echo "INFO: Latest runc version: $RUNC_VERSION_TAG"

    echo "INFO: Downloading runc ${RUNC_VERSION_TAG} for ${PLATFORM}..."
    wget --quiet "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION_TAG}/runc.${PLATFORM}" -O "/tmp/runc.${PLATFORM}"
    sudo install -m 755 "/tmp/runc.${PLATFORM}" /usr/local/sbin/runc
    rm "/tmp/runc.${PLATFORM}"

    # Setup systemd service for containerd
    echo "INFO: Setting up systemd service for containerd..."
    # Download the service file to /tmp first
    wget --quiet https://raw.githubusercontent.com/containerd/containerd/main/containerd.service -O "/tmp/containerd.service"
    # Place it in /etc/systemd/system/ for user-managed services
    sudo mv "/tmp/containerd.service" /etc/systemd/system/containerd.service

    sudo systemctl daemon-reload
    sudo systemctl enable --now containerd
    echo "INFO: containerd and runc installation complete. containerd service started and enabled."
}


# --- Main OS-specific logic ---
if [ "$OS_NAME" = "Ubuntu" ]; then
    echo "INFO: Detected Ubuntu. Proceeding with Ubuntu-specific setup."
    setup_kernel_prereqs
    install_containerd_runc_from_binary

    echo "INFO: Configuring AppArmor for runc on Ubuntu (if applicable)..."
    # This attempts to disable/unload a potentially restrictive default runc AppArmor profile.
    # The runc profile itself (/etc/apparmor.d/runc) is assumed to be provided by other means
    # if it's needed; this script does not install a specific runc AppArmor profile.
    if [ -f /etc/apparmor.d/runc ]; then
        if ! command -v apparmor_parser &> /dev/null; then
            echo "INFO: apparmor_parser not found. Installing apparmor-utils..."
            sudo apt-get update -qq
            sudo apt-get install -y apparmor-utils
        fi
        echo "INFO: Disabling and unloading existing runc AppArmor profile (if any)..."
        sudo ln -sf /etc/apparmor.d/runc /etc/apparmor.d/disable/runc
        # Attempt to unload/remove. This might show a warning if not loaded, which is fine.
        sudo apparmor_parser -R /etc/apparmor.d/runc || echo "WARNING: 'apparmor_parser -R /etc/apparmor.d/runc' had issues. This might be okay if the profile wasn't loaded or already removed."
    else
        echo "INFO: AppArmor profile /etc/apparmor.d/runc not found. Skipping AppArmor configuration for runc on Ubuntu."
    fi

elif [ "$OS_NAME" = "Amazon Linux" ] && [[ "$OS_VERSION_ID" == "2023"* ]]; then
    echo "INFO: Detected Amazon Linux 2023. Proceeding with AL2023-specific setup."
    setup_kernel_prereqs
    install_containerd_runc_from_binary

    echo "INFO: Amazon Linux 2023 uses SELinux, not AppArmor, by default."
    echo "      Ensure SELinux is configured appropriately for containers."
    echo "      For example, Kubernetes might require SELinux to be in permissive mode or have specific policies."
    echo "      To set SELinux to permissive mode for testing (effective until reboot): 'sudo setenforce 0'"
    echo "      To make permissive mode persistent across reboots (for testing only):"
    echo "      'sudo sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config' (then reboot or run setenforce 0)"
    CURRENT_SELINUX_MODE=$(getenforce)
    echo "INFO: Current SELinux mode: $CURRENT_SELINUX_MODE"

else
    echo "ERROR: Unsupported OS: '$OS_NAME $OS_VERSION_ID'. This script currently supports Ubuntu and Amazon Linux 2023."
    exit 1
fi

echo "INFO: Verifying containerd service status..."
if sudo systemctl is-active --quiet containerd; then
    echo "SUCCESS: containerd service is active."
else
    echo "ERROR: containerd service is NOT active. Please check logs for errors:"
    echo "       sudo journalctl -xeu containerd"
    echo "       systemctl status containerd"
    # exit 1 # You might want to exit here in a stricter script
fi

echo "INFO: Verifying crictl (CLI for CRI-compatible container runtimes)..."
# crictl should be in /usr/local/bin (from containerd tarball)
if command -v crictl &> /dev/null; then
    echo "INFO: crictl version:"
    sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock version
    echo "INFO: Listing crictl pods (will be empty if no pods running via CRI):"
    sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock pods
    echo "INFO: crictl check done. Note: Full crictl functionality for pods (e.g., running new pods) requires CNI plugins to be installed and configured in Kubernetes."
else
    echo "WARNING: crictl command not found in PATH. It should have been installed with containerd in /usr/local/bin/."
fi

echo "INFO: Script finished. Creating marker file /tmp/container.txt"
sudo touch /tmp/container.txt # Use sudo if script is run as non-root but needs to write here, though /tmp is usually world-writable.
# Changed to sudo touch for consistency, though /tmp is usually writable.
# If script is run with sudo, then sudo is not strictly needed here.
# If run as user, and user has sudo rights, this is fine.
# Original script did not use sudo for touch.

echo "SUCCESS: Container runtime setup script completed."
exit 0
