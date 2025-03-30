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

# Install iptables
echo "Installing iptables..."
sudo yum install -y iptables

# Verify iptables installation
if ! command -v iptables &> /dev/null; then
    echo "iptables could not be installed. Exiting."
    exit 1
fi

echo "iptables installed successfully."

# Register kubelet service
echo "Registering kubelet service..."

sudo tee /etc/systemd/system/kubelet.service <<EOF
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=10min
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd to apply the new service
sudo systemctl daemon-reload
sudo systemctl enable --now kubelet

# Verify installation
echo "Verifying Kubernetes binaries installation..."

kubectl version --client
kubelet --version
kubeadm version

echo "Kubernetes installation and kubelet service setup complete."
