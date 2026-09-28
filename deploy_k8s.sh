#!/usr/bin/env bash
# ==============================================================================
# deploy_k8s.sh - High-Availability Kubernetes Cluster on LXD
# Implements all steps from steps.txt
# ==============================================================================
set -euo pipefail

# Text formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

step_header() {
    echo -e "\n${CYAN}======================================================================${NC}"
    echo -e "${CYAN}==> Step $1: $2${NC}"
    echo -e "${CYAN}======================================================================${NC}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SSH_USER="${USER}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes)

# Static IP to node mappings (passed to setup_ssh_lxd_nodes.sh)
HOSTS_ENTRIES=(
    "10.67.38.87 node1"
    "10.67.38.221 node2"
    "10.67.38.211 node3"
)

NODES=()
declare -A NODE_IPS
for ENTRY in "${HOSTS_ENTRIES[@]}"; do
    IP=$(echo "$ENTRY" | awk '{print $1}')
    NODE=$(echo "$ENTRY" | awk '{print $2}')
    NODES+=("$NODE")
    NODE_IPS["$NODE"]="$IP"
done

# ------------------------------------------------------------------------------
# Step 1: ufw disable on host machine if present
# ------------------------------------------------------------------------------
step_header "1" "Disable UFW on host machine if present"
if command -v ufw >/dev/null 2>&1; then
    info "Disabling UFW..."
    sudo ufw disable || true
else
    info "UFW is not installed. Skipping."
fi

# ------------------------------------------------------------------------------
# Step 2: create /etc/modules-load.d/k8s.conf on host & load modules
# ------------------------------------------------------------------------------
step_header "2" "Configure and load kernel modules (overlay, br_netfilter, nf_conntrack)"
info "Writing /etc/modules-load.d/k8s.conf..."
sudo tee /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
nf_conntrack
EOF

info "Loading kernel modules into current host system..."
sudo modprobe overlay
sudo modprobe br_netfilter
sudo modprobe nf_conntrack

# ------------------------------------------------------------------------------
# Step 3: create /etc/sysctl.d/99-k8s.conf on host & load sysctl
# ------------------------------------------------------------------------------
step_header "3" "Configure and apply sysctl settings"
info "Writing /etc/sysctl.d/99-k8s.conf..."
sudo tee /etc/sysctl.d/99-k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

info "Applying sysctl parameters..."
sudo sysctl --system

# ------------------------------------------------------------------------------
# Step 4: Install lxc via apt
# ------------------------------------------------------------------------------
step_header "4" "Install LXC via apt"
info "Updating apt repositories and installing lxc..."
sudo apt-get update
sudo apt-get install -y lxc

# ------------------------------------------------------------------------------
# Step 5: Install lxd via snap
# ------------------------------------------------------------------------------
step_header "5" "Install LXD via snap"
if ! command -v snap >/dev/null 2>&1; then
    info "Installing snapd..."
    sudo apt-get install -y snapd
fi
if ! snap list lxd >/dev/null 2>&1; then
    info "Installing lxd via snap..."
    sudo snap install lxd
else
    info "LXD snap is already installed."
fi

# ------------------------------------------------------------------------------
# Step 6: Make current user member of lxd group; ensure lxc does not need sudo
# ------------------------------------------------------------------------------
step_header "6" "Configure LXD group membership for $SSH_USER"
if ! id -nG "$SSH_USER" | grep -qw "lxd"; then
    info "Adding $SSH_USER to group 'lxd'..."
    sudo usermod -aG lxd "$SSH_USER"
fi

# If lxd is not in current shell's active groups, re-execute the script using sg lxd
if ! id -nG | grep -qw "lxd"; then
    info "Activating 'lxd' group for the current session without requiring logout..."
    exec sg lxd -c "$0 \"$@\""
fi
success "User $SSH_USER is in lxd group and lxc commands can run without sudo."

# ------------------------------------------------------------------------------
# Step 7: do lxd init with lxd-init-config file
# ------------------------------------------------------------------------------
step_header "7" "Initialize LXD with lxd-init-config"
if ! lxc network show lxdbr0 >/dev/null 2>&1; then
    info "Applying lxd-init-config preseed..."
    cat "${SCRIPT_DIR}/lxd-init-config" | lxd init --preseed
else
    info "LXD bridge 'lxdbr0' already exists. Skipping preseed."
fi

# ------------------------------------------------------------------------------
# Step 8: run lxd_docker_iptables.sh
# ------------------------------------------------------------------------------
step_header "8" "Run lxd_docker_iptables.sh"
if [ -f "${SCRIPT_DIR}/lxd_docker_iptables.sh" ]; then
    bash "${SCRIPT_DIR}/lxd_docker_iptables.sh"
else
    error "File ${SCRIPT_DIR}/lxd_docker_iptables.sh not found!"
    exit 1
fi

# ------------------------------------------------------------------------------
# Step 9: create lxd profile 'k8s' from k8s-profile-config
# ------------------------------------------------------------------------------
step_header "9" "Create/Update LXD profile 'k8s'"
if ! lxc profile list | grep -qw "k8s"; then
    info "Creating lxd profile 'k8s'..."
    lxc profile create k8s
fi
info "Applying k8s-profile-config to profile 'k8s'..."
lxc profile edit k8s < "${SCRIPT_DIR}/k8s-profile-config"

# ------------------------------------------------------------------------------
# Step 10: launch 3 lxd containers node1, node2, node3
# ------------------------------------------------------------------------------
step_header "10" "Launch and start LXD containers: ${NODES[*]}"
for NODE in "${NODES[@]}"; do
    IP="${NODE_IPS[$NODE]}"
    if ! lxc info "$NODE" >/dev/null 2>&1; then
        info "Launching $NODE (IP: $IP) with profile 'k8s'..."
        lxc launch ubuntu:24.04 "$NODE" --profile k8s --config devices.eth0.ipv4.address="$IP"
    else
        info "Container $NODE already exists."
    fi

    STATE=$(lxc info "$NODE" | awk '/^Status:/ {print $2}')
    if [ "$STATE" != "RUNNING" ]; then
        info "Starting $NODE..."
        lxc start "$NODE"
    fi
done

# ------------------------------------------------------------------------------
# Step 11: Run setup_ssh_lxd_nodes.sh for ssh setup
# ------------------------------------------------------------------------------
step_header "11" "Run setup_ssh_lxd_nodes.sh"
bash "${SCRIPT_DIR}/setup_ssh_lxd_nodes.sh" "${HOSTS_ENTRIES[@]}"

# ------------------------------------------------------------------------------
# Step 12: Configure containerd & kubeadm on all 3 nodes
# ------------------------------------------------------------------------------
step_header "12" "Install and configure containerd and kubeadm on all 3 nodes"
for NODE in "${NODES[@]}"; do
    info "--- Configuring runtime and Kubernetes binaries on $NODE ---"
    
    # i) scp containerd_install.sh, kubeadm_install.sh
    info "Copying installation scripts to $NODE..."
    scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/containerd_install.sh" "${SCRIPT_DIR}/kubeadm_install.sh" "${SSH_USER}@${NODE}:~/"

    # ii) & iii) run containerd_install.sh
    info "Running containerd_install.sh on $NODE..."
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "export DEBIAN_FRONTEND=noninteractive; bash ~/containerd_install.sh"

    # iv) rm config.toml; mkdir -p; containerd config default | tee
    # v) SystemdCgroup = true, disabled_plugins = []
    # vi) daemon-reload and restart containerd
    info "Configuring containerd on $NODE..."
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "
        sudo rm -rf /etc/containerd/config.toml
        sudo mkdir -p /etc/containerd
        containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
        sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
        sudo sed -i 's/disabled_plugins = .*/disabled_plugins = []/g' /etc/containerd/config.toml
        sudo systemctl daemon-reload
        sudo systemctl restart containerd
    "

    # vii) run kubeadm_install.sh
    info "Running kubeadm_install.sh on $NODE..."
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "export DEBIAN_FRONTEND=noninteractive; bash ~/kubeadm_install.sh"

    # viii) kubeadm config images pull - check which version of pause
    # ix) change the sandbox in containerd config.toml to this version
    # x) daemon-reload and restart containerd
    info "Detecting pause container image version on $NODE and updating containerd config..."
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" '
        sudo kubeadm config images pull
        PAUSE_IMAGE=$(sudo kubeadm config images list 2>/dev/null | grep -E "/pause:" | head -n 1)
        if [ -z "$PAUSE_IMAGE" ]; then
            PAUSE_IMAGE="registry.k8s.io/pause:3.10.2"
        fi
        echo "Detected pause image: $PAUSE_IMAGE"
        if grep -q "sandbox_image = " /etc/containerd/config.toml; then
            sudo sed -i "s|sandbox_image = .*|sandbox_image = \"${PAUSE_IMAGE}\"|g" /etc/containerd/config.toml
        fi
        if grep -q "sandbox = " /etc/containerd/config.toml; then
            sudo sed -i "s|sandbox = .*|sandbox = \"${PAUSE_IMAGE}\"|g" /etc/containerd/config.toml
        fi
        sudo systemctl daemon-reload
        sudo systemctl restart containerd
    '
    success "Runtime configured on $NODE."
done

# ------------------------------------------------------------------------------
# Step 13: Bootstrap node1 with kube-vip and kubeadm init
# ------------------------------------------------------------------------------
step_header "13" "Bootstrap control plane on node1"

# i) scp kube-vip.sh and kubeadm-init-config.yaml
info "Copying kube-vip.sh and kubeadm-init-config.yaml to node1..."
scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/kube-vip.sh" "${SCRIPT_DIR}/kubeadm-init-config.yaml" "${SSH_USER}@node1:~/"

# ii) & iii) Run kube-vip.sh and update hostPath to super-admin.conf
info "Installing prerequisites, running kube-vip.sh, and modifying hostPath for bootstrap..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" '
    sudo apt-get update -qq
    sudo apt-get install -y -qq jq
    sudo mkdir -p /etc/kubernetes/manifests
    sudo bash ~/kube-vip.sh
    # Match the line containing "hostPath:", then replace "admin.conf" on the next line
    sudo sed -i "/hostPath:/{n;s/admin.conf/super-admin.conf/;}" /etc/kubernetes/manifests/kube-vip.yaml
'

# iv) run kubeadm init
info "Running kubeadm init on node1..."
KUBEADM_INIT_OUTPUT=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "sudo kubeadm init --config ./kubeadm-init-config.yaml --upload-certs --ignore-preflight-errors=SystemVerification")
echo "$KUBEADM_INIT_OUTPUT"

# v) Note the token, discovery-token-ca-cert-hash and certificate-key
info "Extracting join credentials from kubeadm init output..."
JOIN_TOKEN=$(echo "$KUBEADM_INIT_OUTPUT" | grep -oP -- '--token\s+\K\S+' | head -n 1 || true)
JOIN_CA_HASH=$(echo "$KUBEADM_INIT_OUTPUT" | grep -oP -- '--discovery-token-ca-cert-hash\s+\K\S+' | head -n 1 || true)
JOIN_CERT_KEY=$(echo "$KUBEADM_INIT_OUTPUT" | grep -oP -- '--certificate-key\s+\K\S+' | head -n 1 || true)

# Fallbacks if output parsing missed any field
if [ -z "$JOIN_TOKEN" ]; then
    info "Retrieving token directly from node1..."
    JOIN_TOKEN=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "sudo kubeadm token list" | awk 'NR>1 {print $1; exit}')
    if [ -z "$JOIN_TOKEN" ]; then
        JOIN_TOKEN=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "sudo kubeadm token create")
    fi
fi

if [ -z "$JOIN_CA_HASH" ]; then
    info "Generating CA cert hash directly from node1..."
    RAW_HASH=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //'")
    JOIN_CA_HASH="sha256:${RAW_HASH}"
fi

if [ -z "$JOIN_CERT_KEY" ]; then
    info "Uploading certs on node1 to obtain certificate key..."
    JOIN_CERT_KEY=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "sudo kubeadm init phase upload-certs --upload-certs 2>/dev/null" | tail -n 1)
fi

info "Join Token:             $JOIN_TOKEN"
info "Discovery CA Hash:      $JOIN_CA_HASH"
info "Control Plane Cert Key: $JOIN_CERT_KEY"

# vi) Copy admin.conf to $HOME/.kube/config on node1
# vii) Check if API server is reachable
# viii) Revert hostPath back to admin.conf safely
# ix) Move kube-vip.yaml to /tmp/
# x) Check kube-vip pod is deleted
# xi) Move back /tmp/kube-vip.yaml to /etc/kubernetes/manifests/
# xii) Check kube-vip pod is created
# xiii) Exit out of node1 back to host machine
info "Finalizing node1 configuration and cycling kube-vip..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" '
    mkdir -p $HOME/.kube
    sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config

    echo "Checking API server response on node1..."
    until kubectl get nodes >/dev/null 2>&1; do
        sleep 2
    done
    kubectl get nodes

    echo "Reverting kube-vip hostPath to admin.conf..."
    sudo sed -i "/hostPath:/{n;s/super-admin.conf/admin.conf/;}" /etc/kubernetes/manifests/kube-vip.yaml

    echo "Moving kube-vip.yaml to /tmp/ to restart pod..."
    sudo mv /etc/kubernetes/manifests/kube-vip.yaml /tmp/

    echo "Waiting for kube-vip pod to stop..."
    while sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock pods --name kube-vip -q 2>/dev/null | grep -q .; do
        sleep 2
    done

    echo "Restoring kube-vip.yaml to manifests..."
    sudo mv /tmp/kube-vip.yaml /etc/kubernetes/manifests/

    echo "Waiting for kube-vip pod to become ready..."
    until sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock pods --name kube-vip --state Ready -q 2>/dev/null | grep -q .; do
        sleep 2
    done

    echo "Verifying API server responds after kube-vip restart..."
    until kubectl get nodes >/dev/null 2>&1; do
        sleep 2
    done
'
success "Node1 bootstrap and kube-vip configuration complete."

# ------------------------------------------------------------------------------
# Step 14: Copy k8s config file from node1 to host
# ------------------------------------------------------------------------------
step_header "14" "Copy k8s config from node1 to host"
mkdir -p "$HOME/.kube"
scp "${SSH_OPTS[@]}" "${SSH_USER}@node1:/home/${SSH_USER}/.kube/config" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
success "Kubeconfig successfully copied to $HOME/.kube/config."

# ------------------------------------------------------------------------------
# Step 15: Update kubeadm-join-cp2-config.yaml and kubeadm-join-cp3-config.yaml
# ------------------------------------------------------------------------------
step_header "15" "Update join configs for node2 and node3"
sed -i "s|token: \".*\"|token: \"${JOIN_TOKEN}\"|g" "${SCRIPT_DIR}/kubeadm-join-cp2-config.yaml"
sed -i "s|caCertHashes: \[\".*\"\]|caCertHashes: [\"${JOIN_CA_HASH}\"]|g" "${SCRIPT_DIR}/kubeadm-join-cp2-config.yaml"
sed -i "s|certificateKey: \".*\"|certificateKey: \"${JOIN_CERT_KEY}\"|g" "${SCRIPT_DIR}/kubeadm-join-cp2-config.yaml"

sed -i "s|token: \".*\"|token: \"${JOIN_TOKEN}\"|g" "${SCRIPT_DIR}/kubeadm-join-cp3-config.yaml"
sed -i "s|caCertHashes: \[\".*\"\]|caCertHashes: [\"${JOIN_CA_HASH}\"]|g" "${SCRIPT_DIR}/kubeadm-join-cp3-config.yaml"
sed -i "s|certificateKey: \".*\"|certificateKey: \"${JOIN_CERT_KEY}\"|g" "${SCRIPT_DIR}/kubeadm-join-cp3-config.yaml"
success "Join configurations updated with new tokens and certificate key."

# ------------------------------------------------------------------------------
# Step 16: Join node2
# ------------------------------------------------------------------------------
step_header "16" "Join node2 to control plane"
info "Copying kubeadm-join-cp2-config.yaml to node2..."
scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/kubeadm-join-cp2-config.yaml" "${SSH_USER}@node2:~/"

info "Executing kubeadm join on node2..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@node2" '
    sudo kubeadm join --config ./kubeadm-join-cp2-config.yaml --ignore-preflight-errors=SystemVerification
    mkdir -p $HOME/.kube
    sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
'
success "Node2 joined successfully."

# ------------------------------------------------------------------------------
# Step 17: Join node3
# ------------------------------------------------------------------------------
step_header "17" "Join node3 to control plane"
info "Copying kubeadm-join-cp3-config.yaml to node3..."
scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/kubeadm-join-cp3-config.yaml" "${SSH_USER}@node3:~/"

info "Executing kubeadm join on node3..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@node3" '
    sudo kubeadm join --config ./kubeadm-join-cp3-config.yaml --ignore-preflight-errors=SystemVerification
    mkdir -p $HOME/.kube
    sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
'
success "Node3 joined successfully."

# ------------------------------------------------------------------------------
# Step 18: Copy node1 kube-vip.yaml to node2 and node3
# ------------------------------------------------------------------------------
step_header "18" "Distribute kube-vip.yaml to node2 and node3"
TMP_KUBE_VIP=$(mktemp /tmp/kube-vip-XXXXXX.yaml)
ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "sudo cat /etc/kubernetes/manifests/kube-vip.yaml" > "$TMP_KUBE_VIP"

for NODE in node2 node3; do
    info "Copying kube-vip manifest to $NODE..."
    scp "${SSH_OPTS[@]}" "$TMP_KUBE_VIP" "${SSH_USER}@${NODE}:/tmp/kube-vip.yaml"
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "
        sudo mkdir -p /etc/kubernetes/manifests
        sudo cp -f /tmp/kube-vip.yaml /etc/kubernetes/manifests/kube-vip.yaml
        rm -f /tmp/kube-vip.yaml
    "
done
rm -f "$TMP_KUBE_VIP"
success "Kube-vip manifests distributed to all control plane nodes."

# ------------------------------------------------------------------------------
# Step 19: Install cilium CLI, helm, and kubectl on host
# ------------------------------------------------------------------------------
step_header "19" "Install cilium CLI, Helm, and Kubectl on host"
info "Running cilium_cli_install.sh..."
bash "${SCRIPT_DIR}/cilium_cli_install.sh"

info "Running helm_install.sh..."
bash "${SCRIPT_DIR}/helm_install.sh"

info "Running kubectl_install.sh..."
bash "${SCRIPT_DIR}/kubectl_install.sh"

# ------------------------------------------------------------------------------
# Step 20: Remove control-plane taints from all nodes
# ------------------------------------------------------------------------------
step_header "20" "Remove control-plane taints from all nodes"
info "Removing control-plane taints so all nodes can schedule workloads..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

# ------------------------------------------------------------------------------
# Step 21: Download Cilium helm chart
# ------------------------------------------------------------------------------
step_header "21" "Download Cilium 1.18.13 Helm chart"
if [ ! -f "${SCRIPT_DIR}/cilium-1.18.13.tgz" ]; then
    info "Fetching cilium-1.18.13.tgz..."
    wget -nc https://helm.isovalent.com/cilium-1.18.13.tgz
else
    info "cilium-1.18.13.tgz already exists."
fi

# ------------------------------------------------------------------------------
# Step 22: Generate cilium.yaml using helm template
# ------------------------------------------------------------------------------
step_header "22" "Template Cilium Helm chart into cilium.yaml"
helm template cilium ./cilium-1.18.13.tgz --namespace kube-system -f ./cilium-deploy.yaml > cilium.yaml
success "Rendered cilium.yaml."

# ------------------------------------------------------------------------------
# Step 23: Apply cilium.yaml
# ------------------------------------------------------------------------------
step_header "23" "Apply Cilium manifest"
kubectl apply -f ./cilium.yaml

# ------------------------------------------------------------------------------
# Step 24: Wait for Cilium status
# ------------------------------------------------------------------------------
step_header "24" "Wait for Cilium readiness"
info "Running cilium status --wait until successful..."
until cilium status --wait; do
    warn "Cilium status timed out or exited before complete. Retrying in 5 seconds..."
    sleep 5
done
success "Cilium is healthy and ready!"

# ------------------------------------------------------------------------------
# Step 25: Check for all 3 nodes status Ready
# ------------------------------------------------------------------------------
step_header "25" "Check all 3 nodes are in Ready status"
info "Waiting for all nodes to report condition=Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes -o wide

# ------------------------------------------------------------------------------
# Step 26: Apply dnsutils.yaml
# ------------------------------------------------------------------------------
step_header "26" "Apply dnsutils test pod"
kubectl apply -f "${SCRIPT_DIR}/dnsutils.yaml"
info "Waiting for dnsutils pod to be created/ready..."
kubectl wait --for=condition=Ready pod/dnsutils --timeout=120s || true
kubectl get pods -A

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${GREEN}==> Kubernetes HA Cluster setup completed successfully!${NC}"
echo -e "${GREEN}======================================================================${NC}"
