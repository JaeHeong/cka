#!/bin/bash
# Kubernetes version selection script for AL2023

# Prompt user to select version or use the latest stable version
read -p "Enter Kubernetes version (e.g., v1.31.0) or press Enter for latest stable version: " VERSION

if [ -z "$VERSION" ]; then
    # If no version is provided, fetch the latest stable version
    VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
fi

echo "Fetching Kubernetes version ${VERSION}..."

# Download binaries for the selected version
curl -LO "https://dl.k8s.io/release/${VERSION}/bin/linux/amd64/kubectl"
curl -LO "https://dl.k8s.io/release/${VERSION}/bin/linux/amd64/kubelet"
curl -LO "https://dl.k8s.io/release/${VERSION}/bin/linux/amd64/kubeadm"

# Make the binaries executable
chmod +x kubectl kubelet kubeadm

# Move binaries to /usr/local/bin/
sudo mv kubectl kubelet kubeadm /usr/local/bin/

# Verify installation
kubectl version --client
kubelet --version
kubeadm version
