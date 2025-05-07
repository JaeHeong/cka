#!/bin/bash
# Script to install kubeadm, kubelet, and kubectl.
# Supports Ubuntu (20.04+) and Amazon Linux 2023.
# Allows specifying a Kubernetes version or installs the latest stable version.

# Exit immediately if a command exits with a non-zero status.
set -e
# set -x # Uncomment for debug mode

echo "Starting Kubernetes tools (kubeadm, kubelet, kubectl) installation script..."

# --- Configuration ---
K8S_RELEASE_URL="https://dl.k8s.io/release"
K8S_PACKAGES_URL="https://pkgs.k8s.io"

# --- Check Prerequisites ---
if ! [ "$(id -u)" = 0 ]; then
  echo "ERROR: This script must be run as root or with sudo."
  exit 1
fi

if ! [ -f /tmp/container.txt ]; then
    echo "ERROR: Prerequisite script (setup-container.sh or similar) not completed."
    echo "       Please run the container runtime setup script first (it creates /tmp/container.txt)."
    exit 4
fi

# --- Determine OS ---
OS_NAME=""
OS_VERSION_ID=""
if [ -f /etc/os-release ]; then
    . /etc/os-release # Source the file to get $NAME, $ID, $VERSION_ID etc.
    OS_NAME=$NAME
    OS_ID=$ID # e.g., ubuntu, amzn
    OS_VERSION_ID=$VERSION_ID
else
    echo "ERROR: Cannot determine OS information from /etc/os-release."
    exit 1
fi
echo "INFO: Detected OS: $OS_NAME ($OS_ID) $OS_VERSION_ID"

# --- Determine Kubernetes Version ---
USER_K8S_VERSION_INPUT="${1:-}" # First argument to the script

KUBE_MAJOR_MINOR_FOR_REPO="" # e.g., v1.28
KUBE_VERSION_FOR_INSTALL_PKG="" # e.g., 1.28.5 (for package manager)

if [ -n "$USER_K8S_VERSION_INPUT" ]; then
    echo "INFO: User specified Kubernetes version: $USER_K8S_VERSION_INPUT"
    TEMP_VERSION=$(echo "$USER_K8S_VERSION_INPUT" | sed 's/^v//') # Remove leading 'v' -> 1.28.5 or 1.28

    if [[ "$TEMP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then # Full version like 1.28.5
        KUBE_MAJOR_MINOR_FOR_REPO="v$(echo "$TEMP_VERSION" | cut -d. -f1,2)" # v1.28
        KUBE_VERSION_FOR_INSTALL_PKG="$TEMP_VERSION"
    elif [[ "$TEMP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then # Minor version like 1.28
        KUBE_MAJOR_MINOR_FOR_REPO="v$TEMP_VERSION" # v1.28
        # For minor version, install latest patch. KUBE_VERSION_FOR_INSTALL_PKG remains empty.
    else
        echo "ERROR: Invalid Kubernetes version format: '$USER_K8S_VERSION_INPUT'."
        echo "       Use format X.Y (e.g., 1.28) or X.Y.Z (e.g., 1.28.5), with an optional 'v' prefix."
        exit 1
    fi
else
    echo "INFO: No Kubernetes version specified by user. Fetching latest stable version..."
    LATEST_STABLE_K8S_VERSION=$(curl -sL "${K8S_RELEASE_URL}/stable.txt") # e.g., v1.29.3
    if [ -z "$LATEST_STABLE_K8S_VERSION" ]; then
        echo "ERROR: Could not fetch latest stable Kubernetes version from ${K8S_RELEASE_URL}/stable.txt"
        exit 1
    fi
    echo "INFO: Latest stable Kubernetes version: $LATEST_STABLE_K8S_VERSION"
    KUBE_MAJOR_MINOR_FOR_REPO="v$(echo "$LATEST_STABLE_K8S_VERSION" | sed 's/^v//' | cut -d. -f1,2)" # e.g. v1.29
    # For latest stable, install latest patch. KUBE_VERSION_FOR_INSTALL_PKG remains empty.
fi

echo "INFO: Kubernetes Major.Minor for repository: $KUBE_MAJOR_MINOR_FOR_REPO"
if [ -n "$KUBE_VERSION_FOR_INSTALL_PKG" ]; then
    echo "INFO: Specific Kubernetes version for package installation: $KUBE_VERSION_FOR_INSTALL_PKG"
else
    echo "INFO: Will install the latest available patch version for $KUBE_MAJOR_MINOR_FOR_REPO from the repository."
fi

# --- Install Prerequisite Packages (curl, gpg, jq if not present) ---
echo "INFO: Ensuring curl, gpg, jq are installed..."
if [[ "$OS_ID" == "ubuntu" ]]; then
    if ! dpkg -s curl > /dev/null 2>&1 || ! dpkg -s gpg > /dev/null 2>&1 || ! dpkg -s jq > /dev/null 2>&1 ; then
        sudo apt-get update -qq
        sudo apt-get install -y curl gpg jq apt-transport-https
    fi
elif [[ "$OS_ID" == "amzn" ]] && [[ "$OS_VERSION_ID" == "2023"* ]]; then
     if ! rpm -q curl > /dev/null 2>&1 || ! rpm -q gnupg2 > /dev/null 2>&1 || ! rpm -q jq > /dev/null 2>&1 ; then
        sudo dnf install -y --allowerasing curl gnupg2 jq # gnupg2 provides gpg
    fi
else
    echo "WARNING: OS ($OS_ID) not explicitly handled for jq/curl/gpg prerequisite check. Assuming they are present."
fi


# --- Disable Swap ---
echo "INFO: Disabling swap..."
sudo swapoff -a
echo "INFO: Commenting out swap entries in /etc/fstab..."
# Make a backup and then comment out lines containing " swap "
sudo cp /etc/fstab /etc/fstab.bak-kubeadm-$(date +%F-%T)
sudo sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab
echo "INFO: Swap disabled and fstab updated. A backup /etc/fstab.bak was created."

# --- Kernel Modules and Sysctl (br_netfilter might be loaded by containerd setup too) ---
echo "INFO: Ensuring br_netfilter module is loaded on boot..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
br_netfilter
EOF
sudo modprobe br_netfilter # Load it now

# Sysctl params for Kubernetes networking are typically set by the container runtime script.
# If not, they should be:
# sudo tee /etc/sysctl.d/k8s.conf <<EOF
# net.bridge.bridge-nf-call-ip6tables = 1
# net.bridge.bridge-nf-call-iptables = 1
# net.ipv4.ip_forward = 1
# EOF
# sudo sysctl --system
echo "INFO: Note: net.bridge.bridge-nf-call-iptables, net.ipv4.ip_forward, etc., should have been set by the container runtime setup."

# --- OS-Specific Installation ---
if [[ "$OS_ID" == "ubuntu" ]]; then
    echo "INFO: Starting Kubernetes tools installation for Ubuntu..."
    sudo apt-get update -qq
    # apt-transport-https is needed for https sources, curl for fetching keys
    # gpg for dearmoring keys
    sudo apt-get install -y apt-transport-https curl gpg

    # Add Kubernetes APT repository
    echo "INFO: Adding Kubernetes APT repository for $KUBE_MAJOR_MINOR_FOR_REPO..."
    KEYRING_PATH="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
    curl -fsSL "${K8S_PACKAGES_URL}/core:/stable:/${KUBE_MAJOR_MINOR_FOR_REPO}/deb/Release.key" | sudo gpg --dearmor -o "${KEYRING_PATH}"
    echo "deb [signed-by=${KEYRING_PATH}] ${K8S_PACKAGES_URL}/core:/stable:/${KUBE_MAJOR_MINOR_FOR_REPO}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

    sudo apt-get update -qq

    echo "INFO: Installing kubelet, kubeadm, kubectl..."
    if [ -n "$KUBE_VERSION_FOR_INSTALL_PKG" ]; then
        VERSION_STRING="${KUBE_VERSION_FOR_INSTALL_PKG}-*" # Match any build revision for the specified version
        sudo apt-get install -y kubelet="=${VERSION_STRING}" kubeadm="=${VERSION_STRING}" kubectl="=${VERSION_STRING}"
    else
        sudo apt-get install -y kubelet kubeadm kubectl
    fi
    sudo apt-mark hold kubelet kubeadm kubectl
    echo "INFO: kubelet, kubeadm, kubectl installed and held on Ubuntu."

elif [[ "$OS_ID" == "amzn" ]] && [[ "$OS_VERSION_ID" == "2023"* ]]; then
    echo "INFO: Starting Kubernetes tools installation for Amazon Linux 2023..."
    # Add Kubernetes YUM/DNF repository
    echo "INFO: Adding Kubernetes DNF repository for $KUBE_MAJOR_MINOR_FOR_REPO..."
    sudo tee /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=${K8S_PACKAGES_URL}/core:/stable:/${KUBE_MAJOR_MINOR_FOR_REPO}/rpm/
enabled=1
gpgcheck=1
gpgkey=${K8S_PACKAGES_URL}/core:/stable:/${KUBE_MAJOR_MINOR_FOR_REPO}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
    # The exclude line prevents accidental upgrades. We use --disableexcludes for explicit installs/upgrades.

    echo "INFO: Installing kubelet, kubeadm, kubectl..."
    if [ -n "$KUBE_VERSION_FOR_INSTALL_PKG" ]; then
        # For dnf, version format is typically kubelet-1.28.5
        sudo dnf install -y "kubelet-${KUBE_VERSION_FOR_INSTALL_PKG}" "kubeadm-${KUBE_VERSION_FOR_INSTALL_PKG}" "kubectl-${KUBE_VERSION_FOR_INSTALL_PKG}" --disableexcludes=kubernetes
    else
        sudo dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
    fi

    echo "INFO: Enabling and starting kubelet service..."
    sudo systemctl enable --now kubelet

    # Hold packages using dnf versionlock
    # Ensure dnf-plugins-core which provides versionlock is installed
    if ! rpm -q dnf-plugins-core > /dev/null 2>&1; then
        echo "INFO: Installing dnf-plugins-core for versionlock capability..."
        sudo dnf install -y dnf-plugins-core
    fi
    echo "INFO: Locking versions for kubelet, kubeadm, kubectl..."
    # Clear existing locks for these packages first in case of re-run with different version
    sudo dnf versionlock delete kubelet kubeadm kubectl > /dev/null 2>&1 || true 
    sudo dnf versionlock add kubelet kubeadm kubectl
    echo "INFO: kubelet, kubeadm, kubectl installed and versionlocked on Amazon Linux 2023."

else
    echo "ERROR: Unsupported OS: $OS_NAME ($OS_ID). This script supports Ubuntu and Amazon Linux 2023."
    exit 1
fi

# --- Configure crictl ---
# This ensures crictl (if installed, typically comes with containerd) uses the correct endpoint.
# The container runtime script should have installed containerd and crictl.
echo "INFO: Configuring crictl to use containerd runtime endpoint..."
if command -v crictl &> /dev/null; then
    sudo crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock --set image-endpoint=unix:///run/containerd/containerd.sock
    echo "INFO: crictl runtime-endpoint configured."
else
    echo "WARNING: crictl command not found. Skipping crictl configuration. Ensure your container runtime (containerd) and crictl are properly installed."
fi


echo "SUCCESS: Kubernetes tools installation script completed."
echo ""
echo "NEXT STEPS:"
echo " -> For Control Plane Node: Initialize with 'sudo kubeadm init <options>'"
echo "    After init, apply a CNI plugin. For Calico: kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml (check for latest Calico version)"
echo " -> For Worker Nodes: Use the 'sudo kubeadm join ...' command provided by 'kubeadm init' on the control plane."

exit 0
