#!/bin/bash

# 이 스크립트는 Ubuntu 20.04 LTS 및 이후 버전을 지원합니다.
# 반드시 sudo (root) 권한으로 실행해야 합니다.
# *** bash 로 실행 권장: sudo bash setup-kubetools-specific-version.sh ***

# --- 사용자 설정 변수 ---
# 사용 가능한 버전을 확인하여 아래 값을 수정하세요. (예: 1.30.11-1.1)
KUBE_VERSION_TO_INSTALL="1.30.11-1.1" # <--- 여기를 수정했습니다.

# --- Root 권한 확인 ---
if ! [ "$(id -u)" = 0 ]; then
    echo "오류: 이 스크립트는 sudo (root) 권한으로 실행해야 합니다."
    exit 1
fi

echo "== 이전 Kubernetes 설치 잔여물 제거 시작 (충돌 방지) =="
kubeadm reset -f > /dev/null 2>&1 || echo "정보: 'kubeadm reset' 실패 (아직 설치되지 않았거나 이미 초기화됨)."

echo "이전 Kubernetes 및 Containerd 관련 패키지를 제거합니다..."
apt-get purge -y kubeadm kubectl kubelet kubernetes-cni > /dev/null 2>&1 || echo "정보: 주요 Kubernetes 패키지 제거 중 일부 실패 (설치되지 않았을 수 있음)."
apt-get purge -y containerd.io containerd > /dev/null 2>&1 || echo "정보: Containerd 패키지 제거 중 일부 실패 (설치되지 않았을 수 있음)."
apt-get autoremove -y > /dev/null 2>&1

echo "Kubernetes 및 CRI 관련 설정 디렉터리를 삭제합니다."
rm -rf /etc/cni/ /etc/kubernetes/ /var/lib/dockershim/ /var/lib/etcd/ /var/lib/kubelet/ /var/lib/kubelet-* /var/run/kubernetes/ ~/.kube/ /var/lib/containerd/
rm -f /etc/apt/sources.list.d/kubernetes.list
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "시스템 재부팅 후 다시 시도하는 것이 좋을 수 있습니다 (선택 사항)."
echo "3초 후 계속 진행합니다..."
sleep 3
echo "== 이전 Kubernetes 설치 잔여물 제거 완료 =="
echo ""

# --- OS 정보 확인 ---
OS_LINE=$(hostnamectl | grep "Operating System")
MYOS=$(echo "$OS_LINE" | awk -F': ' '{print $2}' | awk '{print $1}')
OS_VERSION_FULL_STRING=$(echo "$OS_LINE" | awk -F': ' '{print $2}' | awk '{sub($1 FS, ""); print}' | sed 's/^ *//;s/ *$//')
OS_VERSION_NUMBER_PART=$(echo "$OS_VERSION_FULL_STRING" | awk '{print $1}')
OS_MAJOR_VERSION=$(echo "$OS_VERSION_NUMBER_PART" | cut -d. -f1)

echo "운영체제: $MYOS $OS_VERSION_FULL_STRING"

if [ "$MYOS" != "Ubuntu" ] || ! [[ "$OS_MAJOR_VERSION" =~ ^[0-9]+$ ]] || [ "$OS_MAJOR_VERSION" -lt 20 ]; then
    echo "오류: 이 스크립트는 Ubuntu 20.04 LTS 이상 버전에서만 지원됩니다."
    echo "감지된 OS: $MYOS $OS_VERSION_FULL_STRING (주요 버전 문자열: '$OS_MAJOR_VERSION')"
    exit 2
fi

echo "Ubuntu $OS_VERSION_FULL_STRING 환경에서 Kubernetes 설치를 시작합니다."
echo ""

# --- 필수 패키지 설치 (apt-transport-https, curl, ca-certificates, gnupg) ---
echo "== 필수 패키지 설치 =="
apt-get update -qq
apt-get install -y apt-transport-https curl ca-certificates gnupg -qq
echo ""

# --- Kubernetes 패키지 저장소 설정 (pkgs.k8s.io 사용) ---
echo "== Kubernetes apt 저장소 설정 =="
if [[ "$KUBE_VERSION_TO_INSTALL" =~ ^([0-9]+\.[0-9]+) ]]; then
    KUBE_MAJOR_MINOR_FOR_REPO="v${BASH_REMATCH[1]}"
else
    echo "오류: KUBE_VERSION_TO_INSTALL ('$KUBE_VERSION_TO_INSTALL')에서 Major.Minor 버전을 추출할 수 없습니다."
    echo "버전 형식을 확인하세요 (예: 1.30.11-1.1)."
    KUBE_MAJOR_MINOR_FOR_REPO="v1.30" # Fallback
    echo "경고: 저장소 경로에 기본값 '${KUBE_MAJOR_MINOR_FOR_REPO}'를 사용합니다."
fi

KEYRING_PATH="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
echo "Kubernetes GPG 키 다운로드 중 (${KUBE_MAJOR_MINOR_FOR_REPO} 용)..."
if curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBE_MAJOR_MINOR_FOR_REPO}/deb/Release.key" | gpg --dearmor -o "${KEYRING_PATH}"; then
    chmod 644 "${KEYRING_PATH}"
else
    echo "오류: Kubernetes GPG 키 다운로드 또는 GPG 처리 실패."
    echo "URL: https://pkgs.k8s.io/core:/stable:/${KUBE_MAJOR_MINOR_FOR_REPO}/deb/Release.key"
    exit 1
fi

echo "deb [signed-by=${KEYRING_PATH}] https://pkgs.k8s.io/core:/stable:/${KUBE_MAJOR_MINOR_FOR_REPO}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
echo ""

# --- containerd 설치 안내 ---
echo "== Containerd 설치 안내 =="
echo "이 스크립트는 containerd 를 직접 설치하지 않습니다."
echo "사전에 containerd 를 설치하고 Kubernetes 권장 사항에 맞게 설정해야 합니다."
echo "예: sudo apt-get update && sudo apt-get install -y containerd.io"
echo "설치 후에는 systemd cgroup 드라이버 사용을 권장합니다."
echo "  sudo mkdir -p /etc/containerd"
echo "  containerd config default | sudo tee /etc/containerd/config.toml"
echo "  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml"
echo "  sudo systemctl restart containerd"
echo "위 단계를 이미 수행했거나 다른 방식으로 containerd를 설정했다면 계속 진행하세요."
echo "5초 후 계속 진행합니다..."
sleep 5
echo ""


# --- 커널 모듈 로드 및 sysctl 설정 (브릿지 네트워크 및 IP 포워딩) ---
echo "== 커널 모듈 로드 및 sysctl 설정 =="
cat <<EOF | tee /etc/modules-load.d/k8s.conf > /dev/null
overlay
br_netfilter
EOF

modprobe overlay > /dev/null 2>&1
modprobe br_netfilter > /dev/null 2>&1

cat <<EOF | tee /etc/sysctl.d/k8s.conf > /dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system > /dev/null 2>&1
echo ""

# --- kubelet, kubeadm, kubectl 설치 ---
echo "== kubelet, kubeadm, kubectl 설치 =="
apt-get update -qq
echo ""
echo "사용 가능한 kubeadm 버전 목록입니다 (pkgs.k8s.io 저장소 기준):"
apt-cache madison kubeadm || echo "경고: 사용 가능한 kubeadm 버전 정보를 가져올 수 없습니다. 저장소 설정을 확인하세요."
echo ""
echo "현재 스크립트에 설정된 설치 대상 버전: KUBE_VERSION_TO_INSTALL=\"$KUBE_VERSION_TO_INSTALL\""
echo "5초 후에 현재 설정된 버전($KUBE_VERSION_TO_INSTALL)으로 설치를 시도합니다. 중단하려면 Ctrl+C를 누르세요."
sleep 5

echo "지정한 버전($KUBE_VERSION_TO_INSTALL)으로 Kubernetes 컴포넌트 설치를 시도합니다."
if apt-get install -y kubelet="$KUBE_VERSION_TO_INSTALL" kubeadm="$KUBE_VERSION_TO_INSTALL" kubectl="$KUBE_VERSION_TO_INSTALL" -qq; then
    apt-mark hold kubelet kubeadm kubectl
else
    echo "오류: kubelet, kubeadm, kubectl 설치에 실패했습니다."
    echo "지정한 버전($KUBE_VERSION_TO_INSTALL)이 Kubernetes 저장소에 올바른 형식으로 존재하는지 다시 확인하세요."
    echo "위의 'apt-cache madison kubeadm' 결과 목록을 참고하여 정확한 버전을 입력해야 합니다."
    exit 1
fi
echo ""

# --- Swap 비활성화 ---
echo "== Swap 비활성화 =="
swapoff -a
if grep -qE '^\s*[^#].*\sswap\s' /etc/fstab; then
    sed -i.bak -E 's/(^\s*[^#].*\sswap\s)/#\1/' /etc/fstab
    echo "/etc/fstab 에서 swap 라인을 주석 처리했습니다. (백업 파일: /etc/fstab.bak)"
else
    echo "/etc/fstab 에 활성화된 swap 라인이 없거나 이미 주석 처리되었습니다."
fi
echo ""

# --- crictl 설정 (containerd 소켓 사용) ---
echo "== crictl 설정 (containerd 사용) =="
CRICTL_CONFIG_FILE="/etc/crictl.yaml"
cat <<EOF | tee "${CRICTL_CONFIG_FILE}" > /dev/null
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
echo "${CRICTL_CONFIG_FILE} 파일이 생성/업데이트되었습니다."
echo ""

# --- 설치 완료 안내 ---
echo "===================================================================="
echo "Kubernetes 컴포넌트 (kubelet, kubeadm, kubectl) 설치 및 기본 설정이 완료되었습니다."
echo "===================================================================="
echo ""
echo "설치된 버전:"
kubelet --version || echo "kubelet 버전 확인 실패"
kubeadm version || echo "kubeadm 버전 확인 실패"
kubectl version --client --output=yaml || echo "kubectl 버전 확인 실패"
echo ""
echo "다음 단계를 진행하세요:"
echo ""
echo "1. (모든 노드) Containerd 설치 및 설정 확인:"
echo "   - 이 스크립트는 Containerd를 설치하지 않았습니다. 사전에 설치 및 설정을 완료해야 합니다."
echo "   - Containerd가 systemd cgroup 드라이버를 사용하는지 확인하세요 (/etc/containerd/config.toml)."
echo ""
echo "2. (Control Plane 노드) 클러스터 초기화:"
KUBE_VERSION_FOR_INIT=$(echo "$KUBE_VERSION_TO_INSTALL" | cut -d'-' -f1)
echo "   sudo kubeadm init --pod-network-cidr=<your-pod-cidr> --kubernetes-version=\${KUBE_VERSION_FOR_INIT}"
echo "   (예: --pod-network-cidr=192.168.0.0/16 for Calico)"
echo ""
echo "3. (Control Plane 노드) kubectl 설정:"
echo "   초기화 후 출력되는 안내에 따라 kubectl을 설정하세요 (mkdir, cp, chown)."
echo ""
echo "4. (Control Plane 노드) 네트워크 플러그인(CNI) 설치 (예: Calico v3.28.0):"
echo "   kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml"
echo "   (2025년 5월 기준 Calico v3.28.0 사용, 주기적으로 https://www.tigera.io/project-calico/ 에서 최신 안정 버전을 확인하세요.)"
echo ""
echo "5. (Worker 노드) 클러스터 참여:"
echo "   Control Plane 초기화 시 출력된 'kubeadm join' 명령어를 Worker 노드에서 실행하세요."
echo ""

exit 0
