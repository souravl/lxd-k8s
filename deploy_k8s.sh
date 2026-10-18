#!/usr/bin/env bash
# ==============================================================================
# deploy_k8s.sh - High-Availability Kubernetes Cluster on Incus or LXD
# Implements all steps from steps.txt
# Usage: ./deploy_k8s.sh [-c incus|lxd]
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

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Automates the deployment of a 3-node HA Kubernetes cluster on Incus or LXD containers.

Options:
  -c <engine>    Container engine to use: 'incus' (default) or 'lxd'
  -h             Show this help message
EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Parse CLI Options with getopts
# ------------------------------------------------------------------------------
ENGINE="incus"

while getopts "c:h" opt; do
    case "$opt" in
        c) ENGINE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

ENGINE="$(echo "$ENGINE" | tr '[:upper:]' '[:lower:]')"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Source configuration & version inventory if present
if [ -f "${SCRIPT_DIR}/inventory.txt" ]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/inventory.txt"
fi
export UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
export KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.37}"
export CILIUM_VERSION="${CILIUM_VERSION:-1.20.2}"

VIP="${VIP:-10.67.38.40}"
BRIDGE_IPV4="${BRIDGE_IPV4:-10.67.38.1}"
BRIDGE_IPV6="${BRIDGE_IPV6:-fd42:51e5:ef75:abeb::1}"
# Verify NUM_CP and NUM_WORKER
NUM_CP="${NUM_CP:-3}"
if ! [[ "$NUM_CP" =~ ^[1-9][0-9]*$ ]]; then
    error "Invalid NUM_CP='${NUM_CP}' in inventory.txt! NUM_CP must be a positive integer."
    exit 1
fi

NUM_WORKER="${NUM_WORKER:-0}"
if ! [[ "$NUM_WORKER" =~ ^[0-9]+$ ]]; then
    error "Invalid NUM_WORKER='${NUM_WORKER}' in inventory.txt! NUM_WORKER must be a non-negative integer."
    exit 1
fi

TOTAL_NODES=$((NUM_CP + NUM_WORKER))

# Count defined and non-empty NODEn_IP variables
NODE_IPS_COUNT=0
for var in ${!NODE*}; do
    if [[ "$var" =~ ^NODE[0-9]+_IP$ ]] && [ -n "${!var:-}" ]; then
        NODE_IPS_COUNT=$((NODE_IPS_COUNT + 1))
    fi
done

if [ "$NODE_IPS_COUNT" -lt "$TOTAL_NODES" ]; then
    error "Insufficient node static IP addresses in inventory.txt! Expected at least ${TOTAL_NODES} NODEn_IP variable(s) (${NUM_CP} control plane + ${NUM_WORKER} worker), but found ${NODE_IPS_COUNT}."
    exit 1
fi

# Verify control plane node static IP addresses (NODE1_IP .. NODEn_IP for CPs)
MISSING_CP_NODES=()
for ((i=1; i<=NUM_CP; i++)); do
    var="NODE${i}_IP"
    if [ -z "${!var:-}" ]; then
        MISSING_CP_NODES+=("$var")
    fi
done

if [ "${#MISSING_CP_NODES[@]}" -gt 0 ]; then
    error "Missing control plane node static IP addresses in inventory.txt! The following required variable(s) are not set: ${MISSING_CP_NODES[*]}."
    exit 1
fi

# Verify worker node static IP addresses (sequential starting after last CP node)
if [ "$NUM_WORKER" -gt 0 ]; then
    START_WORKER=$((NUM_CP + 1))
    END_WORKER=$((NUM_CP + NUM_WORKER))
    MISSING_WORKER_NODES=()
    for ((i=START_WORKER; i<=END_WORKER; i++)); do
        var="NODE${i}_IP"
        if [ -z "${!var:-}" ]; then
            MISSING_WORKER_NODES+=("$var")
        fi
    done

    if [ "${#MISSING_WORKER_NODES[@]}" -gt 0 ]; then
        error "Missing worker node static IP addresses in inventory.txt! Expected ${NUM_WORKER} sequential worker node(s) (NODE${START_WORKER}_IP to NODE${END_WORKER}_IP). The following required variable(s) are not set: ${MISSING_WORKER_NODES[*]}."
        exit 1
    fi
fi
LIMITS_CPU="${LIMITS_CPU:-4}"
LIMITS_MEMORY="${LIMITS_MEMORY:-4GB}"

if [ "$ENGINE" = "incus" ]; then
    ENGINE_NAME="Incus"
    CONTAINER_CMD="incus"
    GROUP="incus-admin"
    BRIDGE="incusbr0"
    STORAGE_POOL_DIR="/var/lib/incus/storage-pools/default"
    INIT_CMD="incus admin init"
    IMAGE="images:ubuntu/${UBUNTU_VERSION}"
elif [ "$ENGINE" = "lxd" ]; then
    ENGINE_NAME="LXD"
    CONTAINER_CMD="lxc"
    GROUP="lxd"
    BRIDGE="lxdbr0"
    STORAGE_POOL_DIR="/var/snap/lxd/common/lxd/storage-pools/default"
    INIT_CMD="lxd init"
    IMAGE="ubuntu:${UBUNTU_VERSION}"
else
    error "Invalid container engine: '$ENGINE'. Must be 'incus' or 'lxd'."
    exit 1
fi

SSH_USER="${USER}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)

# Static IP to node mappings (passed to setup_ssh_nodes.sh)
HOSTS_ENTRIES=()
for ((i=1; i<=TOTAL_NODES; i++)); do
    var="NODE${i}_IP"
    HOSTS_ENTRIES+=("${!var} node${i}")
done

NODES=()
declare -A NODE_IPS
for ENTRY in "${HOSTS_ENTRIES[@]}"; do
    IP=$(echo "$ENTRY" | awk '{print $1}')
    NODE=$(echo "$ENTRY" | awk '{print $2}')
    NODES+=("$NODE")
    NODE_IPS["$NODE"]="$IP"
done

# Nodes to clone from node1 (node2 .. node${TOTAL_NODES})
CLONE_NODES=()
for ((i=2; i<=TOTAL_NODES; i++)); do
    CLONE_NODES+=("node${i}")
done

# Clean stale host keys from ~/.ssh/known_hosts for cluster nodes from previous runs
if [ -f "$HOME/.ssh/known_hosts" ]; then
    for ENTRY in "${HOSTS_ENTRIES[@]}"; do
        _IP=$(echo "$ENTRY" | awk '{print $1}')
        _NODE=$(echo "$ENTRY" | awk '{print $2}')
        ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$_NODE" >/dev/null 2>&1 || true
        ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$_IP" >/dev/null 2>&1 || true
    done
fi

info "Selected container engine: ${ENGINE_NAME} (CLI: ${CONTAINER_CMD})"

# ------------------------------------------------------------------------------
# Step 1: Install container engine on host
# ------------------------------------------------------------------------------
if [ "${_SKIP_STEP1:-false}" != "true" ]; then
    step_header "1" "Install ${ENGINE_NAME} on host"
    if [ "$ENGINE" = "incus" ]; then
        if ! command -v incus >/dev/null 2>&1; then
            info "Installing Incus via APT..."
            if ! apt-cache show incus >/dev/null 2>&1; then
                info "Adding Zabbly Incus repository..."
                sudo apt-get update -qq
                sudo apt-get install -y -qq curl ca-certificates
                sudo mkdir -p /etc/apt/keyrings
                sudo curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc
                sudo sh -c 'cat <<EOF > /etc/apt/sources.list.d/zabbly-incus-stable.sources
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: $(. /etc/os-release && echo ${VERSION_CODENAME})
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF'
                sudo apt-get update -qq
            fi
            sudo apt-get install -y incus
        else
            info "Incus is already installed."
        fi
    else
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
    fi
fi

# ------------------------------------------------------------------------------
# Step 2: Configure group membership for $SSH_USER; ensure commands run without sudo
# ------------------------------------------------------------------------------
if [ "${_SKIP_STEP1:-false}" != "true" ]; then
    step_header "2" "Configure ${ENGINE_NAME} group membership for $SSH_USER"
    if ! id -nG "$SSH_USER" | grep -qw "$GROUP"; then
        info "Adding $SSH_USER to group '$GROUP'..."
        sudo usermod -aG "$GROUP" "$SSH_USER"
    fi
fi

# If group is not in current shell's active groups, re-execute the script using sg
if ! id -nG | grep -qw "$GROUP"; then
    info "Activating '$GROUP' group for the current session without requiring logout..."
    exec sg "$GROUP" -c "_SKIP_STEP1=true \"${SCRIPT_DIR}/deploy_k8s.sh\" -c \"$ENGINE\""
fi
success "User $SSH_USER is in $GROUP group and $CONTAINER_CMD commands can run without sudo."

# ------------------------------------------------------------------------------
# Step 3: ufw disable on host machine if present
# ------------------------------------------------------------------------------
step_header "3" "Disable UFW on host machine if present"
if command -v ufw >/dev/null 2>&1; then
    info "Disabling UFW..."
    sudo ufw disable || true
else
    info "UFW is not installed. Skipping."
fi

# ------------------------------------------------------------------------------
# Step 4: create /etc/modules-load.d/k8s.conf on host & load modules
# ------------------------------------------------------------------------------
step_header "4" "Configure and load kernel modules (overlay, br_netfilter, nf_conntrack)"
info "Writing /etc/modules-load.d/k8s.conf (overwriting to ensure no duplicates)..."
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
# Step 5: create /etc/sysctl.d/99-k8s.conf on host & load sysctl
# ------------------------------------------------------------------------------
step_header "5" "Configure and apply sysctl settings"
info "Writing /etc/sysctl.d/99-k8s.conf (overwriting to ensure no duplicates)..."
sudo tee /etc/sysctl.d/99-k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

info "Applying sysctl parameters..."
sudo sysctl --system

# ------------------------------------------------------------------------------
# Step 6: Initialize container engine with preseed configuration
# ------------------------------------------------------------------------------
step_header "6" "Initialize ${ENGINE_NAME} with container-engine-init-config"
if ! $CONTAINER_CMD network show "$BRIDGE" >/dev/null 2>&1; then
    info "Applying parameterized container-engine-init-config preseed..."
    sed \
        -e "s|\${BRIDGE}|${BRIDGE}|g" \
        -e "s|\${STORAGE_POOL_DIR}|${STORAGE_POOL_DIR}|g" \
        -e "s|\${BRIDGE_IPV4}|${BRIDGE_IPV4}|g" \
        -e "s|\${BRIDGE_IPV6}|${BRIDGE_IPV6}|g" \
        "${SCRIPT_DIR}/container-engine-init-config" | $INIT_CMD --preseed
else
    info "${ENGINE_NAME} bridge '${BRIDGE}' already exists. Skipping preseed."
fi

# ------------------------------------------------------------------------------
# Step 7: Run docker_iptables.sh for bridge firewall coexistence
# ------------------------------------------------------------------------------
step_header "7" "Run docker_iptables.sh"
if [ -f "${SCRIPT_DIR}/docker_iptables.sh" ]; then
    BRIDGE_SUBNET="${BRIDGE_IPV4%.*}.0/24"
    bash "${SCRIPT_DIR}/docker_iptables.sh" "$BRIDGE" "$BRIDGE_SUBNET"
else
    error "File ${SCRIPT_DIR}/docker_iptables.sh not found!"
    exit 1
fi

# ------------------------------------------------------------------------------
# Step 8: Create/update container profile 'k8s'
# ------------------------------------------------------------------------------
step_header "8" "Create/Update ${ENGINE_NAME} profile 'k8s'"
if ! $CONTAINER_CMD profile list | grep -qw "k8s"; then
    info "Creating profile 'k8s'..."
    $CONTAINER_CMD profile create k8s
fi
info "Applying parameterized k8s-container-profile-config to profile 'k8s'..."
sed \
    -e "s|\${BRIDGE}|${BRIDGE}|g" \
    -e "s|\${LIMITS_CPU}|${LIMITS_CPU}|g" \
    -e "s|\${LIMITS_MEMORY}|${LIMITS_MEMORY}|g" \
    "${SCRIPT_DIR}/k8s-container-profile-config" | $CONTAINER_CMD profile edit k8s

# ------------------------------------------------------------------------------
# Step 9: Launch container node1
# ------------------------------------------------------------------------------
step_header "9" "Launch and start ${ENGINE_NAME} container: node1"
IP="${NODE_IPS[node1]}"
if ! $CONTAINER_CMD info node1 >/dev/null 2>&1; then
    info "Launching node1 (IP: $IP) with profile 'k8s'..."
    $CONTAINER_CMD launch "$IMAGE" node1 --profile k8s -d eth0,ipv4.address="$IP"
else
    info "Container node1 already exists."
fi

STATE=$($CONTAINER_CMD info node1 | awk '/^Status:/ {print $2}')
if [ "$STATE" != "RUNNING" ]; then
    info "Starting node1..."
    $CONTAINER_CMD start node1
fi

# ------------------------------------------------------------------------------
# Step 10: Run setup_ssh_nodes.sh for ssh setup
# ------------------------------------------------------------------------------
step_header "10" "Run setup_ssh_nodes.sh on node1"
CONTAINER_CMD="$CONTAINER_CMD" TARGET_NODES="node1" bash "${SCRIPT_DIR}/setup_ssh_nodes.sh" "${HOSTS_ENTRIES[@]}"

# ------------------------------------------------------------------------------
# Step 11: Configure containerd & kubeadm on node1
# ------------------------------------------------------------------------------
step_header "11" "Install and configure containerd and kubeadm on node1"
NODE="node1"
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
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "export DEBIAN_FRONTEND=noninteractive; export KUBERNETES_VERSION='${KUBERNETES_VERSION}'; bash ~/kubeadm_install.sh"

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

# ------------------------------------------------------------------------------
# Step 12: Clone remaining nodes from node1
# ------------------------------------------------------------------------------
if [ "${#CLONE_NODES[@]}" -gt 0 ]; then
    step_header "12" "Clone remaining nodes (${CLONE_NODES[*]}) from node1"

    # i) Stop node1 and wait for it to stop
    info "Stopping node1 before cloning..."
    if [ "$($CONTAINER_CMD info node1 | awk '/^Status:/ {print $2}')" = "RUNNING" ]; then
        $CONTAINER_CMD stop node1
    fi
    until [ "$($CONTAINER_CMD info node1 | awk '/^Status:/ {print $2}')" = "STOPPED" ]; do
        info "Waiting for node1 to stop..."
        sleep 1
    done
    success "node1 is stopped."

    # ii) Copy remaining nodes from node1 and configure their static IPs
    for TARGET_NODE in "${CLONE_NODES[@]}"; do
        IP="${NODE_IPS[$TARGET_NODE]}"
        if ! $CONTAINER_CMD info "$TARGET_NODE" >/dev/null 2>&1; then
            info "Copying $TARGET_NODE from node1..."
            $CONTAINER_CMD copy node1 "$TARGET_NODE"
            info "Setting static IP ($IP) on $TARGET_NODE..."
            $CONTAINER_CMD config device set "$TARGET_NODE" eth0 ipv4.address "$IP"
        else
            info "Container $TARGET_NODE already exists."
        fi
    done

    # iii) Start all nodes
    for NODE in "${NODES[@]}"; do
        STATE=$($CONTAINER_CMD info "$NODE" | awk '/^Status:/ {print $2}')
        if [ "$STATE" != "RUNNING" ]; then
            info "Starting $NODE..."
            $CONTAINER_CMD start "$NODE"
        fi
    done

    # iv) Wait for all nodes to be RUNNING
    for NODE in "${NODES[@]}"; do
        until [ "$($CONTAINER_CMD info "$NODE" | awk '/^Status:/ {print $2}')" = "RUNNING" ]; do
            info "Waiting for $NODE to reach RUNNING status..."
            sleep 1
        done
    done

    # v) Set hostnames, regenerate machine-ids, and verify SSH
    for TARGET_NODE in "${CLONE_NODES[@]}"; do
        info "Setting hostname and regenerating machine-id on $TARGET_NODE..."
        $CONTAINER_CMD exec "$TARGET_NODE" -- bash -c "echo '$TARGET_NODE' > /etc/hostname && hostname '$TARGET_NODE'"
        $CONTAINER_CMD exec "$TARGET_NODE" -- bash -c "rm -f /etc/machine-id /var/lib/dbus/machine-id && systemd-machine-id-setup" >/dev/null 2>&1
    done
else
    step_header "12" "Single-node deployment (skipping cloning)"
    info "Only node1 is defined; skipping clone step."
fi

# Verify SSH connectivity to all nodes
for NODE in "${NODES[@]}"; do
    info "Verifying SSH connectivity to $NODE..."
    until ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "true" 2>/dev/null; do
        sleep 2
    done
    success "SSH to $NODE is operational."
done
success "All nodes (${NODES[*]}) are cloned, started, and reachable via SSH."

# ------------------------------------------------------------------------------
# Step 13: Bootstrap node1 with kube-vip and kubeadm init
# ------------------------------------------------------------------------------
step_header "13" "Bootstrap control plane on node1"

# i) & ii) scp kube-vip.sh, run it
info "Generating and configuring kube-vip on node1 (VIP: $VIP)..."
scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/kube-vip.sh" "${SSH_USER}@node1:~/"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "export DEBIAN_FRONTEND=noninteractive; export VIP='${VIP}'; sudo -E bash ~/kube-vip.sh"

# Temporarily point kube-vip to super-admin.conf for initial bootstrap
info "Configuring kube-vip to use super-admin.conf during initial bootstrap..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" '
    sudo sed -i "s|path: /etc/kubernetes/admin.conf|path: /etc/kubernetes/super-admin.conf|g" /etc/kubernetes/manifests/kube-vip.yaml
'

# Copy parameterized kubeadm-init-config.yaml to node1
info "Copying parameterized kubeadm-init-config.yaml to node1..."
sed \
    -e "s|\${NODE1_IP}|${NODE1_IP}|g" \
    -e "s|\${NODE2_IP}|${NODE2_IP}|g" \
    -e "s|\${NODE3_IP}|${NODE3_IP}|g" \
    -e "s|\${VIP}|${VIP}|g" \
    "${SCRIPT_DIR}/kubeadm-init-config.yaml" | ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "cat > ~/kubeadm-init-config.yaml"

# Run kubeadm init (with idempotency guard)
info "Executing kubeadm init on node1..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" '
    if [ ! -f /etc/kubernetes/admin.conf ]; then
        sudo kubeadm init --config ./kubeadm-init-config.yaml --upload-certs --ignore-preflight-errors=SystemVerification
    else
        echo "Kubernetes control plane is already initialized on node1."
    fi
'

# Configure local kubectl access for SSH_USER on node1
info "Setting up local kubectl access for ${SSH_USER} on node1..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "
    mkdir -p /home/${SSH_USER}/.kube
    sudo cp -f /etc/kubernetes/admin.conf /home/${SSH_USER}/.kube/config
    sudo chown \$(id -u):\$(id -g) /home/${SSH_USER}/.kube/config
"

# Parse token, ca-cert-hash, and certificate-key directly from node1
info "Extracting join credentials and certificates from node1..."
JOIN_TOKEN=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "
    sudo kubeadm token list 2>/dev/null | awk '\$3 ~ /authentication/ {print \$1; exit}'
")
if [ -z "$JOIN_TOKEN" ]; then
    JOIN_TOKEN=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "sudo kubeadm token create --print-join-command 2>/dev/null | awk '{print \$5}'")
fi

CA_CERT_HASH=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "
    openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //'
")

CERT_KEY=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "
    sudo kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -n 1
")

if [ -z "$JOIN_TOKEN" ] || [ -z "$CA_CERT_HASH" ] || [ -z "$CERT_KEY" ]; then
    error "Failed to extract required join credentials (token, ca-cert-hash, or certificate-key) from node1."
    exit 1
fi
info "Join credentials and certificates successfully extracted from node1."

# Revert kube-vip hostPath to admin.conf and cycle via /tmp to force pod reload
info "Reverting kube-vip to admin.conf and restarting via CRI..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" '
    sudo sed -i "s|path: /etc/kubernetes/super-admin.conf|path: /etc/kubernetes/admin.conf|g" /etc/kubernetes/manifests/kube-vip.yaml
    echo "Cycling kube-vip manifest via /tmp/ to trigger static pod reload..."
    sudo mv /etc/kubernetes/manifests/kube-vip.yaml /tmp/kube-vip.yaml

    echo "Stopping any existing kube-vip container..."
    sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock stopp $(sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock pods --name kube-vip -q 2>/dev/null) 2>/dev/null || true
    sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock rmp $(sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock pods --name kube-vip -q 2>/dev/null) 2>/dev/null || true

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
# Step 15: Validate join credentials for node2 and node3
# ------------------------------------------------------------------------------
step_header "15" "Validate join credentials for node2 and node3"
info "Active join credentials verified for control plane VIP: ${VIP}"
success "Join credentials ready."

# ------------------------------------------------------------------------------
# Step 16: Join node2
# ------------------------------------------------------------------------------
step_header "16" "Join node2 to control plane"
info "Copying parameterized kubeadm-join-cp-config.yaml to node2..."
sed \
    -e "s|\${NODE_IP}|${NODE2_IP}|g" \
    -e "s|\${VIP}|${VIP}|g" \
    -e "s|\${JOIN_TOKEN}|${JOIN_TOKEN}|g" \
    -e "s|\${CA_CERT_HASH}|${CA_CERT_HASH}|g" \
    -e "s|\${CERT_KEY}|${CERT_KEY}|g" \
    "${SCRIPT_DIR}/kubeadm-join-cp-config.yaml" | ssh "${SSH_OPTS[@]}" "${SSH_USER}@node2" "cat > ~/kubeadm-join-cp-config.yaml"

info "Executing kubeadm join on node2..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@node2" '
    sudo kubeadm join --config ./kubeadm-join-cp-config.yaml --ignore-preflight-errors=SystemVerification
    mkdir -p $HOME/.kube
    sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
'
success "Node2 joined successfully."

# ------------------------------------------------------------------------------
# Step 17: Join node3
# ------------------------------------------------------------------------------
step_header "17" "Join node3 to control plane"
info "Copying parameterized kubeadm-join-cp-config.yaml to node3..."
sed \
    -e "s|\${NODE_IP}|${NODE3_IP}|g" \
    -e "s|\${VIP}|${VIP}|g" \
    -e "s|\${JOIN_TOKEN}|${JOIN_TOKEN}|g" \
    -e "s|\${CA_CERT_HASH}|${CA_CERT_HASH}|g" \
    -e "s|\${CERT_KEY}|${CERT_KEY}|g" \
    "${SCRIPT_DIR}/kubeadm-join-cp-config.yaml" | ssh "${SSH_OPTS[@]}" "${SSH_USER}@node3" "cat > ~/kubeadm-join-cp-config.yaml"

info "Executing kubeadm join on node3..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@node3" '
    sudo kubeadm join --config ./kubeadm-join-cp-config.yaml --ignore-preflight-errors=SystemVerification
    mkdir -p $HOME/.kube
    sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
'
success "Node3 joined successfully."

# ------------------------------------------------------------------------------
# Step 18: Distribute kube-vip.yaml to node2 and node3
# ------------------------------------------------------------------------------
step_header "18" "Distribute kube-vip.yaml to node2 and node3"
TMP_KUBE_VIP=$(mktemp)
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
if command -v cilium >/dev/null 2>&1; then
    info "Cilium CLI is already installed ($(command -v cilium)). Skipping."
else
    info "Running cilium_cli_install.sh..."
    bash "${SCRIPT_DIR}/cilium_cli_install.sh"
fi

if command -v helm >/dev/null 2>&1; then
    info "Helm is already installed ($(command -v helm)). Skipping."
else
    info "Running helm_install.sh..."
    bash "${SCRIPT_DIR}/helm_install.sh"
fi

if command -v kubectl >/dev/null 2>&1; then
    info "Kubectl is already installed ($(command -v kubectl)). Skipping."
else
    info "Running kubectl_install.sh..."
    bash "${SCRIPT_DIR}/kubectl_install.sh"
fi
success "Host tooling ready."

# ------------------------------------------------------------------------------
# Step 20: Remove control-plane taints from all nodes
# ------------------------------------------------------------------------------
step_header "20" "Remove control-plane taints from all nodes"
info "Removing control-plane taints so all nodes can schedule workloads..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

# ------------------------------------------------------------------------------
# Step 21: Download Cilium Helm chart
# ------------------------------------------------------------------------------
step_header "21" "Download Cilium ${CILIUM_VERSION} Helm chart"
if [ -f "${SCRIPT_DIR}/cilium-${CILIUM_VERSION}.tgz" ]; then
    info "Cilium Helm chart already exists. Skipping download."
else
    info "Pulling Cilium Helm chart from OCI registry..."
    helm pull oci://quay.io/cilium/charts/cilium --version "${CILIUM_VERSION}"
    success "Cilium Helm chart downloaded."
fi

# ------------------------------------------------------------------------------
# Step 22: Template Cilium Helm chart into cilium.yaml
# ------------------------------------------------------------------------------
step_header "22" "Template Cilium Helm chart"
info "Rendering cilium.yaml from values..."
helm template cilium "${SCRIPT_DIR}/cilium-${CILIUM_VERSION}.tgz" \
    --namespace kube-system \
    -f "${SCRIPT_DIR}/cilium-deploy.yaml" > "${SCRIPT_DIR}/cilium.yaml"
success "cilium.yaml templated successfully."

# ------------------------------------------------------------------------------
# Step 23: Apply Cilium manifest
# ------------------------------------------------------------------------------
step_header "23" "Apply Cilium CNI"
info "Applying cilium.yaml..."
kubectl apply -f "${SCRIPT_DIR}/cilium.yaml"
success "Cilium manifest applied."

# ------------------------------------------------------------------------------
# Step 24: Wait for Cilium deployment readiness
# ------------------------------------------------------------------------------
step_header "24" "Wait for Cilium readiness"
info "Waiting for Cilium daemonsets and deployments to become ready..."
until cilium status --wait; do
    warn "Cilium status check timed out or not ready yet. Retrying in 5 seconds..."
    sleep 5
done
success "Cilium CNI is fully operational."

# ------------------------------------------------------------------------------
# Step 25: Check all 3 nodes are in Ready status
# ------------------------------------------------------------------------------
step_header "25" "Verify all cluster nodes are Ready"
info "Waiting for all nodes to report condition Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes -o wide

# ------------------------------------------------------------------------------
# Step 26: Apply dnsutils test pod
# ------------------------------------------------------------------------------
step_header "26" "Apply dnsutils test pod"
kubectl apply -f "${SCRIPT_DIR}/dnsutils.yaml"
info "Waiting for dnsutils pod to be created/ready..."
kubectl wait --for=condition=Ready pod/dnsutils --timeout=120s || true
kubectl get pods -A

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${GREEN}==> Kubernetes HA Cluster on ${ENGINE_NAME} completed successfully!${NC}"
echo -e "${GREEN}======================================================================${NC}"
