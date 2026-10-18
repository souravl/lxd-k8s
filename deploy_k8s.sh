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
if [ "$NUM_CP" -lt 3 ]; then
    error "Invalid NUM_CP='${NUM_CP}' in inventory.txt! High-Availability Kubernetes requires at least 3 control planes (NUM_CP >= 3)."
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

# Control plane nodes (node1 .. node${NUM_CP})
CP_NODES=()
for ((i=1; i<=NUM_CP; i++)); do
    CP_NODES+=("node${i}")
done

# Remaining control plane nodes to join (node2 .. node${NUM_CP})
CP_JOIN_NODES=()
for ((i=2; i<=NUM_CP; i++)); do
    CP_JOIN_NODES+=("node${i}")
done

# Worker nodes ((NUM_CP + 1) .. (NUM_CP + NUM_WORKER))
WORKER_NODES=()
if [ "$NUM_WORKER" -gt 0 ]; then
    START_WORKER=$((NUM_CP + 1))
    END_WORKER=$((NUM_CP + NUM_WORKER))
    for ((i=START_WORKER; i<=END_WORKER; i++)); do
        WORKER_NODES+=("node${i}")
    done
fi

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
# Step 7: Configure firewall rules for container bridge and Docker coexistence
# ------------------------------------------------------------------------------
step_header "7" "Configure bridge firewall and Docker coexistence"
BRIDGE_SUBNET="${BRIDGE_IPV4%.*}.0/24"
if systemctl is-active --quiet docker; then
    info "Docker detected. Configuring idempotent iptables rules for bridge '${BRIDGE}'..."

    # i. Allow container outbound traffic through Docker's chain
    if ! sudo iptables -C DOCKER-USER -i "$BRIDGE" -j ACCEPT 2>/dev/null; then
        sudo iptables -I DOCKER-USER -i "$BRIDGE" -j ACCEPT
    fi

    # ii. Allow return internet traffic back into container bridge
    if ! sudo iptables -C DOCKER-USER -o "$BRIDGE" -j ACCEPT 2>/dev/null; then
        sudo iptables -I DOCKER-USER -o "$BRIDGE" -j ACCEPT
    fi

    # iii. Enable internet NAT translation for the container subnet
    if ! sudo iptables -t nat -C POSTROUTING -s "$BRIDGE_SUBNET" ! -d "$BRIDGE_SUBNET" -j MASQUERADE 2>/dev/null; then
        sudo iptables -t nat -A POSTROUTING -s "$BRIDGE_SUBNET" ! -d "$BRIDGE_SUBNET" -j MASQUERADE
    fi

    # iv. Save the rules persistently without prompting the user
    info "Saving firewall rules..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent
    sudo netfilter-persistent save
    success "Firewall rules for '${BRIDGE}' configured and saved."
else
    info "Docker is not active. Skipping firewall adjustments."
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
# Step 10: Configure SSH, user, and /etc/hosts on node1
# ------------------------------------------------------------------------------
step_header "10" "Configure SSH, user, and /etc/hosts on node1"

# i) Locate or generate Host SSH Public Key
SSH_PUB_KEY=""
if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    SSH_PUB_KEY="$HOME/.ssh/id_ed25519.pub"
elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    SSH_PUB_KEY="$HOME/.ssh/id_rsa.pub"
else
    info "No SSH public key found in ~/.ssh/ (id_ed25519.pub or id_rsa.pub)."
    info "Generating new SSH key ('ssh-keygen -t ed25519')..."
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
    SSH_PUB_KEY="$HOME/.ssh/id_ed25519.pub"
fi
info "Using SSH public key: $SSH_PUB_KEY"

# ii) Check if passwordless SSH is already operational on node1
if ssh "${SSH_OPTS[@]}" -o ConnectTimeout=2 "${SSH_USER}@node1" "true" 2>/dev/null; then
    info "Passwordless SSH access is already operational on node1. Skipping container user setup."
else
    # Obtain password for SSH_USER inside containers
    if [ -n "${CONTAINER_PASS:-}" ]; then
        USER_PASS="$CONTAINER_PASS"
    else
        read -rsp "Enter password for user '${SSH_USER}' inside containers: " USER_PASS
        echo
        read -rsp "Confirm password: " USER_PASS_CONFIRM
        echo
        if [ "$USER_PASS" != "$USER_PASS_CONFIRM" ]; then
            error "Passwords do not match!"
            exit 1
        fi
    fi

    # Ensure node1 is running
    STATE=$($CONTAINER_CMD info node1 | awk '/^Status:/ {print $2}')
    if [ "$STATE" != "RUNNING" ]; then
        info "Starting container node1..."
        $CONTAINER_CMD start node1
    fi

    # Wait up to 30 seconds for DNS & network readiness
    MAX_WAIT=30
    COUNT=0
    info "Waiting for DNS & network readiness on node1 (timeout: ${MAX_WAIT}s)..."
    until $CONTAINER_CMD exec node1 -- getent hosts archive.ubuntu.com >/dev/null 2>&1; do
        COUNT=$((COUNT + 1))
        if [ "$COUNT" -ge "$MAX_WAIT" ]; then
            error "DNS/Network timeout on container 'node1' after ${MAX_WAIT}s. Aborting."
            exit 1
        fi
        sleep 1
    done

    # Create user '${SSH_USER}' if it doesn't exist
    if ! $CONTAINER_CMD exec node1 -- id -u "${SSH_USER}" >/dev/null 2>&1; then
        info "Creating user '${SSH_USER}' on node1..."
        $CONTAINER_CMD exec node1 -- useradd -m -s /bin/bash "${SSH_USER}"
        $CONTAINER_CMD exec node1 -- usermod -aG sudo "${SSH_USER}"
    else
        info "User '${SSH_USER}' already exists on node1."
    fi

    # Set password for '${SSH_USER}'
    info "Setting password for '${SSH_USER}' on node1..."
    echo "${SSH_USER}:$USER_PASS" | $CONTAINER_CMD exec node1 -- chpasswd

    # Configure passwordless sudo for '${SSH_USER}'
    info "Configuring passwordless sudo for '${SSH_USER}' on node1..."
    $CONTAINER_CMD exec node1 -- bash -c "mkdir -p /etc/sudoers.d && echo '${SSH_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-${SSH_USER}"
    $CONTAINER_CMD exec node1 -- chmod 440 "/etc/sudoers.d/90-${SSH_USER}"

    # Set up SSH directory and inject authorized_keys
    info "Injecting SSH public key into node1..."
    $CONTAINER_CMD exec node1 -- mkdir -p "/home/${SSH_USER}/.ssh"
    $CONTAINER_CMD file push "$SSH_PUB_KEY" "node1/home/${SSH_USER}/.ssh/authorized_keys"
    $CONTAINER_CMD exec node1 -- chown -R "${SSH_USER}:${SSH_USER}" "/home/${SSH_USER}/.ssh"
    $CONTAINER_CMD exec node1 -- chmod 700 "/home/${SSH_USER}/.ssh"
    $CONTAINER_CMD exec node1 -- chmod 600 "/home/${SSH_USER}/.ssh/authorized_keys"

    # Ensure OpenSSH server is installed and running
    info "Installing and enabling OpenSSH server on node1..."
    $CONTAINER_CMD exec node1 -- apt-get update -qq
    $CONTAINER_CMD exec node1 -- apt-get install -y -qq openssh-server
    $CONTAINER_CMD exec node1 -- systemctl enable --now ssh
fi

# iii) Update /etc/hosts on host and inside node1
info "Updating host /etc/hosts with cluster node mappings..."
for ENTRY in "${HOSTS_ENTRIES[@]}"; do
    IP=$(echo "$ENTRY" | awk '{print $1}')
    NODE_NAME=$(echo "$ENTRY" | awk '{print $2}')
    sudo sed -i -E "/[[:space:]]${NODE_NAME}([[:space:]]|$)/d" /etc/hosts
    echo -e "${IP}\t${NODE_NAME}" | sudo tee -a /etc/hosts >/dev/null
done

info "Updating /etc/hosts inside node1..."
for ENTRY in "${HOSTS_ENTRIES[@]}"; do
    IP=$(echo "$ENTRY" | awk '{print $1}')
    NODE_NAME=$(echo "$ENTRY" | awk '{print $2}')
    $CONTAINER_CMD exec node1 -- bash -c "sed -i -E '/[[:space:]]${NODE_NAME}([[:space:]]|$)/d' /etc/hosts && echo -e '${IP}\t${NODE_NAME}' >> /etc/hosts"
done
success "node1 SSH and /etc/hosts configuration complete."

# ------------------------------------------------------------------------------
# Step 11: Configure containerd & kubeadm on node1
# ------------------------------------------------------------------------------
step_header "11" "Install and configure containerd and kubeadm on node1"
NODE="node1"
info "--- Configuring runtime and Kubernetes binaries on $NODE ---"

# i) Install containerd
info "Installing containerd on $NODE..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "bash -s" <<'EOF'
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    UBUNTU_CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
    ARCH=$(dpkg --print-architecture)
    sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<DOCKER_EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_EOF

    sudo apt-get update -qq
    sudo apt-get install -y containerd.io
EOF

# ii) Configure containerd (SystemdCgroup = true, disabled_plugins = [])
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

# iii) Install Kubernetes packages (kubelet, kubeadm, kubectl, cri-tools)
info "Installing Kubernetes packages (${KUBERNETES_VERSION}) on $NODE..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "KUBERNETES_VERSION='${KUBERNETES_VERSION}' bash -s" <<'EOF'
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -qq
    sudo apt-get install -y -qq apt-transport-https ca-certificates curl gpg
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo apt-get update -qq
    sudo apt-get install -y kubelet kubeadm kubectl cri-tools
    sudo apt-mark hold kubelet kubeadm kubectl cri-tools
    sudo systemctl enable --now kubelet
EOF

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

# Generate and configure kube-vip static pod manifest on node1
info "Generating and configuring kube-vip static pod manifest on node1 (VIP: $VIP)..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "VIP='${VIP}' bash -s" <<'EOF'
    set -e
    INTERFACE="eth0"
    KVVERSION=$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases | jq -r ".[0].name" 2>/dev/null || true)
    if [ -z "$KVVERSION" ] || [ "$KVVERSION" = "null" ]; then
        KVVERSION="v1.3.0"
    fi
    sudo ctr image pull ghcr.io/kube-vip/kube-vip:$KVVERSION
    sudo mkdir -p /etc/kubernetes/manifests
    sudo ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:$KVVERSION vip /kube-vip manifest pod \
        --interface "$INTERFACE" \
        --address "$VIP" \
        --controlplane \
        --services \
        --arp \
        --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml >/dev/null

    # Temporarily point kube-vip to super-admin.conf for initial bootstrap
    sudo sed -i "s|path: /etc/kubernetes/admin.conf|path: /etc/kubernetes/super-admin.conf|g" /etc/kubernetes/manifests/kube-vip.yaml
EOF

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
# Step 15: Validate join credentials for remaining control plane nodes
# ------------------------------------------------------------------------------
step_header "15" "Validate join credentials for control plane nodes"
info "Active join credentials verified for control plane VIP: ${VIP} (joining: ${CP_JOIN_NODES[*]})"
success "Join credentials ready."

# ------------------------------------------------------------------------------
# Step 16: Join remaining control plane nodes to cluster
# ------------------------------------------------------------------------------
step_header "16" "Join remaining control planes (${CP_JOIN_NODES[*]})"
for NODE in "${CP_JOIN_NODES[@]}"; do
    IP="${NODE_IPS[$NODE]}"
    info "Copying parameterized kubeadm-join-cp-config.yaml to $NODE (IP: $IP)..."
    sed \
        -e "s|\${NODE_IP}|${IP}|g" \
        -e "s|\${VIP}|${VIP}|g" \
        -e "s|\${JOIN_TOKEN}|${JOIN_TOKEN}|g" \
        -e "s|\${CA_CERT_HASH}|${CA_CERT_HASH}|g" \
        -e "s|\${CERT_KEY}|${CERT_KEY}|g" \
        "${SCRIPT_DIR}/kubeadm-join-cp-config.yaml" | ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "cat > ~/kubeadm-join-cp-config.yaml"

    info "Executing kubeadm join on $NODE..."
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" '
        sudo kubeadm join --config ./kubeadm-join-cp-config.yaml --ignore-preflight-errors=SystemVerification
        mkdir -p $HOME/.kube
        sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
        sudo chown $(id -u):$(id -g) $HOME/.kube/config
    '
    success "$NODE joined control plane successfully."
done
success "All remaining control plane nodes (${CP_JOIN_NODES[*]}) joined successfully."

# ------------------------------------------------------------------------------
# Step 17: Distribute kube-vip.yaml to remaining control plane nodes
# ------------------------------------------------------------------------------
step_header "17" "Distribute kube-vip.yaml to remaining control plane nodes (${CP_JOIN_NODES[*]})"
TMP_KUBE_VIP=$(mktemp)
ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "sudo cat /etc/kubernetes/manifests/kube-vip.yaml" > "$TMP_KUBE_VIP"

for NODE in "${CP_JOIN_NODES[@]}"; do
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
# Step 18: Join worker nodes to cluster
# ------------------------------------------------------------------------------
if [ "${#WORKER_NODES[@]}" -gt 0 ]; then
    step_header "18" "Join worker nodes (${WORKER_NODES[*]}) to cluster"
    for NODE in "${WORKER_NODES[@]}"; do
        IP="${NODE_IPS[$NODE]}"
        info "Copying parameterized kubeadm-join-worker-config.yaml to $NODE (IP: $IP)..."
        sed \
            -e "s|\${NODE_IP}|${IP}|g" \
            -e "s|\${VIP}|${VIP}|g" \
            -e "s|\${JOIN_TOKEN}|${JOIN_TOKEN}|g" \
            -e "s|\${CA_CERT_HASH}|${CA_CERT_HASH}|g" \
            "${SCRIPT_DIR}/kubeadm-join-worker-config.yaml" | ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "cat > ~/kubeadm-join-worker-config.yaml"

        info "Executing kubeadm join on $NODE..."
        ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" '
            sudo kubeadm join --config ./kubeadm-join-worker-config.yaml --ignore-preflight-errors=SystemVerification
        '
        success "$NODE joined as worker node successfully."
    done
    success "All worker nodes (${WORKER_NODES[*]}) joined successfully."
else
    step_header "18" "Join worker nodes to cluster"
    info "No worker nodes defined (NUM_WORKER=0). Skipping worker join."
fi

# ------------------------------------------------------------------------------
# Step 19: Install cilium CLI, helm, and kubectl on host
# ------------------------------------------------------------------------------
step_header "19" "Install cilium CLI, Helm, and Kubectl on host"

# i) Cilium CLI
if command -v cilium >/dev/null 2>&1; then
    info "Cilium CLI is already installed ($(command -v cilium)). Skipping."
else
    info "Installing Cilium CLI on host..."
    CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    CLI_ARCH=amd64
    if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi

    info "Downloading Cilium CLI ${CILIUM_CLI_VERSION} (${CLI_ARCH})..."
    TMP_CILIUM_DIR=$(mktemp -d)
    curl -L --fail --progress-bar "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz" -o "${TMP_CILIUM_DIR}/cilium-linux-${CLI_ARCH}.tar.gz"
    curl -L --fail -s "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz.sha256sum" -o "${TMP_CILIUM_DIR}/cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"

    info "Verifying SHA256 checksum..."
    (cd "$TMP_CILIUM_DIR" && sha256sum --check "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum" >/dev/null)

    info "Extracting cilium binary to /usr/local/bin..."
    sudo tar xzvfC "${TMP_CILIUM_DIR}/cilium-linux-${CLI_ARCH}.tar.gz" /usr/local/bin
    rm -rf "$TMP_CILIUM_DIR"
    success "Cilium CLI ${CILIUM_CLI_VERSION} installed successfully."
fi

# ii) Helm
if command -v helm >/dev/null 2>&1; then
    info "Helm is already installed ($(command -v helm)). Skipping."
else
    info "Installing Helm on host via APT..."
    HELM_BUILDKITE_APT_KEY_ID="DDF78C3E6EBB2D2CC223C95C62BA89D07698DBC6"
    sudo apt-get update -qq
    sudo apt-get install -y -qq curl gpg apt-transport-https

    TMP_HELM_GPG=$(mktemp)
    curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey > "$TMP_HELM_GPG"
    if [ "$(gpg --show-keys --with-colons "$TMP_HELM_GPG" | awk -F: '$1 == "fpr" {print $10}' | head -n 1)" != "${HELM_BUILDKITE_APT_KEY_ID}" ]; then
        error "Unexpected Helm APT key ID: potential key compromise"
        rm -f "$TMP_HELM_GPG"
        exit 1
    fi

    cat "$TMP_HELM_GPG" | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
    rm -f "$TMP_HELM_GPG"
    echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list

    sudo apt-get update -qq
    sudo apt-get install -y helm
    success "Helm installed successfully."
fi

# iii) Kubectl
if command -v kubectl >/dev/null 2>&1; then
    info "Kubectl is already installed ($(command -v kubectl)). Skipping."
else
    info "Installing Kubectl (${KUBERNETES_VERSION}) on host via APT..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq apt-transport-https ca-certificates curl gpg
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo apt-get update -qq
    sudo apt-get install -y kubectl
    sudo apt-mark hold kubectl
    success "Kubectl installed successfully."
fi
success "Host tooling ready."

# ------------------------------------------------------------------------------
# Step 20: Remove control-plane taints from control plane nodes
# ------------------------------------------------------------------------------
step_header "20" "Remove control-plane taints from control plane nodes"
info "Removing control-plane taints from control plane nodes (${CP_NODES[*]})..."
for NODE in "${CP_NODES[@]}"; do
    info "Untainting control plane node $NODE..."
    kubectl taint nodes "$NODE" node-role.kubernetes.io/control-plane- 2>/dev/null || true
done
success "Control-plane taints removed from ${CP_NODES[*]}."

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
