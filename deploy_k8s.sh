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

Automates the deployment of a High-Availability Kubernetes cluster on Incus or LXD containers.

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

VIP="${VIP:-10.67.38.250}"
BRIDGE_IPV4="${BRIDGE_IPV4:-10.67.38.1}"

# Local Helm chart repository (chartmuseum, steps 28 and 29): checked here so a wrong value stops the script at the start.
HELM_REPO_SERVER_PORT="${HELM_REPO_SERVER_PORT:-9000}"
CHARTS_DIR="${CHARTS_DIR:-${SCRIPT_DIR}/charts/}"
HOST_IP="${HOST_IP:-$BRIDGE_IPV4}"
if [[ ! "$HELM_REPO_SERVER_PORT" =~ ^[0-9]+$ ]] || [ "$HELM_REPO_SERVER_PORT" -lt 1 ] || [ "$HELM_REPO_SERVER_PORT" -gt 65535 ]; then
    error "Invalid HELM_REPO_SERVER_PORT='${HELM_REPO_SERVER_PORT}' in inventory.txt! It must be a port number (1-65535)."
    exit 1
fi
if [[ "$CHARTS_DIR" != /*/ ]]; then
    error "Invalid CHARTS_DIR='${CHARTS_DIR}' in inventory.txt! It must be an absolute path that ends with '/'."
    exit 1
fi
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
# Options for polling ssh calls (until-loops): ConnectTimeout only limits the connect; the ServerAlive options make a
# connection that hangs after connecting (e.g. the VM reboots mid-session) fail after ~6 seconds, so the loop retries.
SSH_POLL_OPTS=(-o ConnectTimeout=2 -o ServerAliveInterval=2 -o ServerAliveCountMax=3)

# Static IP to node mappings
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
info "Nodes configuration: ${NUM_CP} control plane node(s), ${NUM_WORKER} worker node(s)"

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
step_header "6" "Initialize ${ENGINE_NAME} with the preseed configuration"
if ! $CONTAINER_CMD network show "$BRIDGE" >/dev/null 2>&1; then
    info "Applying parameterized container engine init (preseed) configuration..."
    # The configuration is embedded here (quoted heredoc: the ${...} placeholders stay literal and are replaced by sed).
    # The standalone container-engine-init-config.yaml (kept in backup/) is a reference copy and is not read by this script.
    CONTAINER_ENGINE_INIT_CONFIG=$(cat <<'CONTAINER_ENGINE_INIT_EOF'
config: {}
networks:
- config:
    ipv4.address: ${BRIDGE_IPV4}/24
    ipv4.nat: "true"
    ipv6.address: ${BRIDGE_IPV6}/64
    ipv6.nat: "true"
  description: ""
  name: ${BRIDGE}
  type: bridge
  project: default
storage_pools:
- config:
    source: ${STORAGE_POOL_DIR}
  description: ""
  name: default
  driver: dir
profiles:
- config: {}
  description: Default profile
  devices:
    eth0:
      name: eth0
      network: ${BRIDGE}
      type: nic
    root:
      path: /
      pool: default
      type: disk
  name: default
projects:
- config:
    features.images: "true"
    features.networks: "true"
    features.networks.zones: "true"
    features.profiles: "true"
    features.storage.buckets: "true"
    features.storage.volumes: "true"
  description: Default project
  name: default
CONTAINER_ENGINE_INIT_EOF
)
    sed \
        -e "s|\${BRIDGE}|${BRIDGE}|g" \
        -e "s|\${STORAGE_POOL_DIR}|${STORAGE_POOL_DIR}|g" \
        -e "s|\${BRIDGE_IPV4}|${BRIDGE_IPV4}|g" \
        -e "s|\${BRIDGE_IPV6}|${BRIDGE_IPV6}|g" \
        <<<"$CONTAINER_ENGINE_INIT_CONFIG" | $INIT_CMD --preseed
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
info "Applying parameterized Kubernetes container profile configuration to profile 'k8s'..."
# The configuration is embedded here (quoted heredoc: the ${...} placeholders stay literal and are replaced by sed).
# The standalone k8s-container-profile-config.yaml (kept in backup/) is a reference copy and is not read by this script.
K8S_CONTAINER_PROFILE_CONFIG=$(cat <<'K8S_CONTAINER_PROFILE_EOF'
config:
  limits.cpu: "${LIMITS_CPU}"
  limits.memory: ${LIMITS_MEMORY}
  limits.memory.swap: "false"
  linux.kernel_modules: ip_tables,ip6_tables,nf_nat,overlay,br_netfilter
  raw.lxc: "lxc.apparmor.profile=unconfined\nlxc.cap.drop= \nlxc.cgroup.devices.allow=a\nlxc.mount.auto=proc:rw sys:rw"
  security.nesting: "true"
  security.privileged: "true"
description: Profile for Kubernetes
devices:
  eth0:
    name: eth0
    nictype: bridged
    parent: ${BRIDGE}
    type: nic
  kmsg:
    path: /dev/kmsg
    source: /dev/kmsg
    type: unix-char
  root:
    path: /
    pool: default
    type: disk
name: k8s
K8S_CONTAINER_PROFILE_EOF
)
sed \
    -e "s|\${BRIDGE}|${BRIDGE}|g" \
    -e "s|\${LIMITS_CPU}|${LIMITS_CPU}|g" \
    -e "s|\${LIMITS_MEMORY}|${LIMITS_MEMORY}|g" \
    <<<"$K8S_CONTAINER_PROFILE_CONFIG" | $CONTAINER_CMD profile edit k8s

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
elif [ -f "$HOME/.ssh/id_ed25519" ] || [ -f "$HOME/.ssh/id_rsa" ]; then
    # A private key without its public key: ssh-keygen would ask to overwrite the private key, so stop instead.
    _PRIV_KEY="$HOME/.ssh/id_ed25519"
    [ -f "$_PRIV_KEY" ] || _PRIV_KEY="$HOME/.ssh/id_rsa"
    error "Private key ${_PRIV_KEY} exists but its public key ${_PRIV_KEY}.pub is missing."
    error "Generate public key from private key, then re-run this script:"
    error "    ssh-keygen -y -f ${_PRIV_KEY} > ${_PRIV_KEY}.pub"
    exit 1
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
if ssh "${SSH_OPTS[@]}" "${SSH_POLL_OPTS[@]}" "${SSH_USER}@node1" "true" 2>/dev/null; then
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

    # v) Set hostnames, regenerate machine-ids, and regenerate SSH host keys
    for TARGET_NODE in "${CLONE_NODES[@]}"; do
        info "Setting hostname, regenerating machine-id and SSH host keys on $TARGET_NODE..."
        $CONTAINER_CMD exec "$TARGET_NODE" -- bash -c "echo '$TARGET_NODE' > /etc/hostname && hostname '$TARGET_NODE'"
        $CONTAINER_CMD exec "$TARGET_NODE" -- bash -c "rm -f /etc/machine-id /var/lib/dbus/machine-id && systemd-machine-id-setup" >/dev/null 2>&1
        $CONTAINER_CMD exec "$TARGET_NODE" -- bash -c "rm -f /etc/ssh/ssh_host_* && ssh-keygen -A && systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null" >/dev/null 2>&1
    done
else
    step_header "12" "Single-node deployment (skipping cloning)"
    info "Only node1 is defined; skipping clone step."
fi

# Verify SSH connectivity to all nodes and populate known_hosts
for NODE in "${NODES[@]}"; do
    info "Verifying SSH connectivity to $NODE..."
    until ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "true" 2>/dev/null; do
        sleep 2
    done
    success "SSH to $NODE is operational."
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$NODE" >/dev/null 2>&1 || true
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "${NODE_IPS[$NODE]}" >/dev/null 2>&1 || true
    ssh-keyscan -H "$NODE" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
    ssh-keyscan -H "${NODE_IPS[$NODE]}" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
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
        --leaderElection < /dev/null | sudo tee /tmp/kube-vip.yaml >/dev/null

    # Temporarily point kube-vip to super-admin.conf for initial bootstrap before placing in manifests
    sudo sed -i "s|path: /etc/kubernetes/admin.conf|path: /etc/kubernetes/super-admin.conf|g" /tmp/kube-vip.yaml
    sudo cp -f /tmp/kube-vip.yaml /etc/kubernetes/manifests/kube-vip.yaml
EOF

# Generate dynamic certSANs list for all control plane nodes (1 .. NUM_CP)
info "Generating dynamic certSANs list for ${NUM_CP} control plane node(s)..."
CERT_SANS_BLOCK=$(printf "    - 127.0.0.1\n    - localhost\n    - %s" "$VIP")
for ((i=1; i<=NUM_CP; i++)); do
    var="NODE${i}_IP"
    CERT_SANS_BLOCK=$(printf "%s\n    - %s\n    - node%d" "$CERT_SANS_BLOCK" "${!var}" "$i")
done

# Copy the parameterized kubeadm init configuration (embedded below) to node1
info "Copying parameterized kubeadm-init-config.yaml to node1..."
# ${KUBERNETES_FULL_VERSION} is the full version of the kubeadm installed on node1 (for example v1.37.2). Setting it as
# kubernetesVersion stops kubeadm from trying to look up the latest version on dl.k8s.io (it times out without internet).
KUBERNETES_FULL_VERSION=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "kubeadm version -o short" || true)
if ! [[ "$KUBERNETES_FULL_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    error "Could not read the kubeadm version from node1 (got '${KUBERNETES_FULL_VERSION}')."
    exit 1
fi
info "Kubernetes version for kubeadm init: ${KUBERNETES_FULL_VERSION}"
# The configuration is embedded here (quoted heredoc: the ${...} placeholders stay literal and are replaced below).
# The standalone kubeadm-init-config.yaml (kept in backup/) is a reference copy and is not read by this script.
KUBEADM_INIT_CONFIG=$(cat <<'KUBEADM_INIT_EOF'
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${NODE1_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: ${NODE1_IP}
timeouts:
  controlPlaneComponentHealthCheck: 5m0s
  kubeletHealthCheck: 4m0s
  kubernetesAPICall: 5m0s
  etcdAPICall: 3m0s
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: ${KUBERNETES_FULL_VERSION}
apiServer:
  certSANs:
${CERT_SANS}
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/16
controlPlaneEndpoint: "${VIP}:6443"
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
conntrack:
  maxPerCore: 0
  min: 0
KUBEADM_INIT_EOF
)
KUBEADM_INIT_CONFIG="${KUBEADM_INIT_CONFIG//\$\{NODE1_IP\}/$NODE1_IP}"
KUBEADM_INIT_CONFIG="${KUBEADM_INIT_CONFIG//\$\{VIP\}/$VIP}"
KUBEADM_INIT_CONFIG="${KUBEADM_INIT_CONFIG//\$\{KUBERNETES_FULL_VERSION\}/$KUBERNETES_FULL_VERSION}"
KUBEADM_INIT_CONFIG="${KUBEADM_INIT_CONFIG//\$\{CERT_SANS\}/$CERT_SANS_BLOCK}"
echo "$KUBEADM_INIT_CONFIG" | ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "cat > ~/kubeadm-init-config.yaml"

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
    sudo kubeadm token list 2>/dev/null | awk '/authentication/ {print \$1; exit}'
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
# The configuration is embedded here (quoted heredoc: the ${...} placeholders stay literal and are replaced by sed per node).
# The standalone kubeadm-join-cp-config.yaml (kept in backup/) is a reference copy and is not read by this script.
KUBEADM_JOIN_CP_CONFIG=$(cat <<'KUBEADM_JOIN_CP_EOF'
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: ${NODE_IP}
discovery:
  bootstrapToken:
    token: "${JOIN_TOKEN}"
    apiServerEndpoint: "${VIP}:6443"
    caCertHashes: ["sha256:${CA_CERT_HASH}"]
controlPlane:
  localAPIEndpoint:
    advertiseAddress: ${NODE_IP}
    bindPort: 6443
  certificateKey: "${CERT_KEY}"
timeouts:
  controlPlaneComponentHealthCheck: 5m0s
  kubeletHealthCheck: 4m0s
  kubernetesAPICall: 5m0s
  etcdAPICall: 3m0s
  tlsBootstrap: 5m0s
  discovery: 5m0s
KUBEADM_JOIN_CP_EOF
)
for NODE in "${CP_JOIN_NODES[@]}"; do
    IP="${NODE_IPS[$NODE]}"
    info "Copying parameterized kubeadm-join-cp-config.yaml to $NODE (IP: $IP)..."
    sed \
        -e "s|\${NODE_IP}|${IP}|g" \
        -e "s|\${VIP}|${VIP}|g" \
        -e "s|\${JOIN_TOKEN}|${JOIN_TOKEN}|g" \
        -e "s|\${CA_CERT_HASH}|${CA_CERT_HASH}|g" \
        -e "s|\${CERT_KEY}|${CERT_KEY}|g" \
        <<<"$KUBEADM_JOIN_CP_CONFIG" | ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "cat > ~/kubeadm-join-cp-config.yaml"

    info "Executing kubeadm join on $NODE..."
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" '
        if [ ! -f /etc/kubernetes/admin.conf ]; then
            sudo kubeadm join --config ./kubeadm-join-cp-config.yaml --ignore-preflight-errors=SystemVerification
            mkdir -p $HOME/.kube
            sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
            sudo chown $(id -u):$(id -g) $HOME/.kube/config
        else
            echo "Control plane node has already joined."
        fi
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
    # The configuration is embedded here (quoted heredoc: the ${...} placeholders stay literal and are replaced by sed per node).
    # The standalone kubeadm-join-worker-config.yaml (kept in backup/) is a reference copy and is not read by this script.
    KUBEADM_JOIN_WORKER_CONFIG=$(cat <<'KUBEADM_JOIN_WORKER_EOF'
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: ${NODE_IP}
discovery:
  bootstrapToken:
    token: "${JOIN_TOKEN}"
    apiServerEndpoint: "${VIP}:6443"
    caCertHashes: ["sha256:${CA_CERT_HASH}"]
timeouts:
  kubeletHealthCheck: 4m0s
  kubernetesAPICall: 5m0s
  tlsBootstrap: 5m0s
  discovery: 5m0s
KUBEADM_JOIN_WORKER_EOF
)
    for NODE in "${WORKER_NODES[@]}"; do
        IP="${NODE_IPS[$NODE]}"
        info "Copying parameterized kubeadm-join-worker-config.yaml to $NODE (IP: $IP)..."
        sed \
            -e "s|\${NODE_IP}|${IP}|g" \
            -e "s|\${VIP}|${VIP}|g" \
            -e "s|\${JOIN_TOKEN}|${JOIN_TOKEN}|g" \
            -e "s|\${CA_CERT_HASH}|${CA_CERT_HASH}|g" \
            <<<"$KUBEADM_JOIN_WORKER_CONFIG" | ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "cat > ~/kubeadm-join-worker-config.yaml"

        info "Executing kubeadm join on $NODE..."
        ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" '
            if [ ! -f /etc/kubernetes/kubelet.conf ]; then
                sudo kubeadm join --config ./kubeadm-join-worker-config.yaml --ignore-preflight-errors=SystemVerification
            else
                echo "Worker node has already joined."
            fi
        '
        success "$NODE joined as worker node successfully."
    done
    success "All worker nodes (${WORKER_NODES[*]}) joined successfully."
else
    step_header "18" "Join worker nodes to cluster"
    info "No worker nodes defined (NUM_WORKER=0). Skipping worker join."
fi

# ------------------------------------------------------------------------------
# Step 19: Install the certificate check and renewal scripts on the control plane nodes
# ------------------------------------------------------------------------------
# certs/check_k8s_certs.sh and certs/renew_k8s_control_plane_certs.sh go to /usr/local/bin, the systemd service and timer
# (check every 12 hours, renew when a control plane certificate expires within 60 days) to /etc/systemd/system.
# Only the control plane nodes get them; workers have no control plane certificates.
# DEPLOY_USER in renew_k8s_control_plane_certs.sh is set to ${SSH_USER}: the script also replaces that user's ~/.kube/config.
# certs/renew_k8s_kubelet_client_cert_from_host.sh (kubelet client certificate of a node) is not installed: it is run by hand on the host.
# Its FIRST_NODE is set here to node1 (in the repo copy of the script, so this changes the file on every run).
# certs/renew_k8s_control_plane_certs_from_host.sh (renews the certificates on all control plane nodes, then copies the new
# kubeconfig to the host and the worker nodes) is also not installed: it is run by hand on the host.
# Its FIRST_NODE, OTHER_CP_NODES and WORKER_NODES are set here the same way.
step_header "19" "Install certificate check and renewal scripts on control plane nodes (${CP_NODES[*]})"
CERTS_DIR="${SCRIPT_DIR}/certs"
CERTS_FILES=(check_k8s_certs.sh renew_k8s_control_plane_certs.sh check_k8s_certs.service check_k8s_certs.timer)
KUBELET_RENEW_SCRIPT="renew_k8s_kubelet_client_cert_from_host.sh"
CP_RENEW_HOST_SCRIPT="renew_k8s_control_plane_certs_from_host.sh"
for F in "${CERTS_FILES[@]}" "$KUBELET_RENEW_SCRIPT" "$CP_RENEW_HOST_SCRIPT"; do
    if [ ! -f "${CERTS_DIR}/${F}" ]; then
        error "${CERTS_DIR}/${F} not found!"
        exit 1
    fi
done

info "Setting FIRST_NODE to node1 in ${CERTS_DIR}/${KUBELET_RENEW_SCRIPT}..."
sed -i "s|^FIRST_NODE=.*|FIRST_NODE=\"node1\"|" "${CERTS_DIR}/${KUBELET_RENEW_SCRIPT}"

info "Setting FIRST_NODE, OTHER_CP_NODES and WORKER_NODES in ${CERTS_DIR}/${CP_RENEW_HOST_SCRIPT}..."
sed -i \
    -e "s|^FIRST_NODE=.*|FIRST_NODE=\"node1\"|" \
    -e "s|^OTHER_CP_NODES=.*|OTHER_CP_NODES=\"${CP_NODES[*]:1}\"|" \
    -e "s|^WORKER_NODES=.*|WORKER_NODES=\"${WORKER_NODES[*]}\"|" \
    "${CERTS_DIR}/${CP_RENEW_HOST_SCRIPT}"

for NODE in "${CP_NODES[@]}"; do
    info "Installing the certificate check and renewal scripts on $NODE..."
    for F in "${CERTS_FILES[@]}"; do
        scp "${SSH_OPTS[@]}" "${CERTS_DIR}/${F}" "${SSH_USER}@${NODE}:/tmp/${F}"
    done
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "
        sudo install -m 0755 /tmp/check_k8s_certs.sh /usr/local/bin/check_k8s_certs.sh
        sudo install -m 0755 /tmp/renew_k8s_control_plane_certs.sh /usr/local/bin/renew_k8s_control_plane_certs.sh
        sudo sed -i 's|^DEPLOY_USER=.*|DEPLOY_USER=\"${SSH_USER}\"|' /usr/local/bin/renew_k8s_control_plane_certs.sh
        sudo install -m 0644 /tmp/check_k8s_certs.service /etc/systemd/system/check_k8s_certs.service
        sudo install -m 0644 /tmp/check_k8s_certs.timer /etc/systemd/system/check_k8s_certs.timer
        rm -f /tmp/check_k8s_certs.sh /tmp/renew_k8s_control_plane_certs.sh /tmp/check_k8s_certs.service /tmp/check_k8s_certs.timer
        sudo systemctl daemon-reload
        sudo systemctl enable --now check_k8s_certs.timer
    "
    success "Certificate check and renewal scripts installed on $NODE."
done
success "Certificate check timer enabled on all control plane nodes (${CP_NODES[*]})."

# ------------------------------------------------------------------------------
# Step 20: Install cilium CLI, helm, kubectl, chartmuseum, and containerd (with nerdctl and CNI plugins) on host
# ------------------------------------------------------------------------------
step_header "20" "Install cilium CLI, Helm, Kubectl, chartmuseum, and containerd (with nerdctl and CNI plugins) on host"

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

# iv) chartmuseum (helm/chartmuseum, latest release; the binary path is the one used by chartmuseum.service in step 28)
CHARTMUSEUM_BIN="/usr/local/bin/chartmuseum"
if [ -x "$CHARTMUSEUM_BIN" ]; then
    info "chartmuseum is already installed (${CHARTMUSEUM_BIN}). Skipping."
else
    info "Installing chartmuseum (latest release) on host..."
    CM_ARCH=amd64
    if [ "$(uname -m)" = "aarch64" ]; then CM_ARCH=arm64; fi
    CM_TAG=$(curl -fsSL https://api.github.com/repos/helm/chartmuseum/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
    if [ -z "$CM_TAG" ]; then
        error "Could not determine the latest chartmuseum release."
        exit 1
    fi
    CM_DIST="chartmuseum-${CM_TAG}-linux-${CM_ARCH}.tar.gz"

    info "Downloading ${CM_DIST}..."
    TMP_CM_DIR=$(mktemp -d)
    curl -L --fail --progress-bar "https://get.helm.sh/${CM_DIST}" -o "${TMP_CM_DIR}/${CM_DIST}"
    curl -L --fail -s "https://get.helm.sh/${CM_DIST}.sha256sum" -o "${TMP_CM_DIR}/${CM_DIST}.sha256sum"

    info "Verifying SHA256 checksum..."
    CM_EXPECTED_SHA=$(awk '{print $1}' "${TMP_CM_DIR}/${CM_DIST}.sha256sum")
    CM_ACTUAL_SHA=$(sha256sum "${TMP_CM_DIR}/${CM_DIST}" | awk '{print $1}')
    if [ -z "$CM_EXPECTED_SHA" ] || [ "$CM_EXPECTED_SHA" != "$CM_ACTUAL_SHA" ]; then
        error "chartmuseum checksum verification failed for ${CM_DIST}"
        rm -rf "$TMP_CM_DIR"
        exit 1
    fi

    tar -xzf "${TMP_CM_DIR}/${CM_DIST}" -C "$TMP_CM_DIR"
    sudo install -m 0755 "${TMP_CM_DIR}/linux-${CM_ARCH}/chartmuseum" "$CHARTMUSEUM_BIN"
    rm -rf "$TMP_CM_DIR"
    success "chartmuseum ${CM_TAG} installed successfully."
fi

# v) containerd (with nerdctl and the CNI plugins) on the host. It follows the node1 runtime setup (step 11) without the
# Kubernetes-only parts (pause image, kubeadm image pre-pull, kubelet / kubeadm / cri-tools), so Kubernetes can be added to
# the host later. Every part is skipped if it is already in place; existing files are kept unchanged.
CONTAINERD_CHANGED=false

# a) containerd.io (Docker apt repository)
if dpkg -s containerd.io >/dev/null 2>&1; then
    info "containerd.io is already installed ($(dpkg-query -W -f='${Version}' containerd.io)). Skipping."
else
    info "Installing containerd.io on host via APT (Docker repository)..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl gpg
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    HOST_UBUNTU_CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
    HOST_DPKG_ARCH=$(dpkg --print-architecture)
    printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' \
        "$HOST_UBUNTU_CODENAME" "$HOST_DPKG_ARCH" | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y containerd.io
    success "containerd.io installed successfully."
fi

# b) containerd config (SystemdCgroup = true, disabled_plugins = []); the original config is kept once as config.toml.bak
CONTAINERD_CONFIG="/etc/containerd/config.toml"
if [ -f "$CONTAINERD_CONFIG" ] && grep -q 'SystemdCgroup = true' "$CONTAINERD_CONFIG" && grep -q '^disabled_plugins = \[\]' "$CONTAINERD_CONFIG"; then
    info "containerd is already configured (${CONTAINERD_CONFIG}). Skipping."
else
    info "Writing the default containerd config with SystemdCgroup = true and disabled_plugins = []..."
    sudo mkdir -p /etc/containerd
    if [ -f "$CONTAINERD_CONFIG" ] && [ ! -f "${CONTAINERD_CONFIG}.bak" ]; then
        sudo cp -a "$CONTAINERD_CONFIG" "${CONTAINERD_CONFIG}.bak"
    fi
    containerd config default | sudo tee "$CONTAINERD_CONFIG" >/dev/null
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' "$CONTAINERD_CONFIG"
    sudo sed -i 's/disabled_plugins = .*/disabled_plugins = []/g' "$CONTAINERD_CONFIG"
    CONTAINERD_CHANGED=true
fi

# c) nerdctl (latest release, minimal build, SHA-256 verified; the tag comes from the redirect of .../releases/latest, so there is
# no GitHub API rate limit). /usr/local/bin is on sudo's secure_path, so 'sudo nerdctl' works for the root-owned containerd socket.
NERDCTL_BIN="/usr/local/bin/nerdctl"
if [ -x "$NERDCTL_BIN" ]; then
    info "nerdctl is already installed (${NERDCTL_BIN}). Skipping."
else
    info "Installing nerdctl (latest release) on host..."
    NERDCTL_ARCH=$(dpkg --print-architecture)
    NERDCTL_TAG=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/containerd/nerdctl/releases/latest)
    NERDCTL_TAG="${NERDCTL_TAG##*/}"
    if [[ ! "$NERDCTL_TAG" =~ ^v[0-9] ]]; then
        error "Could not determine the latest nerdctl release (got '${NERDCTL_TAG}')."
        exit 1
    fi
    NERDCTL_TGZ="nerdctl-${NERDCTL_TAG#v}-linux-${NERDCTL_ARCH}.tar.gz"
    NERDCTL_URL="https://github.com/containerd/nerdctl/releases/download/${NERDCTL_TAG}"
    TMP_NERDCTL_DIR=$(mktemp -d)
    curl -fsSL "${NERDCTL_URL}/${NERDCTL_TGZ}" -o "${TMP_NERDCTL_DIR}/${NERDCTL_TGZ}"
    curl -fsSL "${NERDCTL_URL}/SHA256SUMS" -o "${TMP_NERDCTL_DIR}/SHA256SUMS"
    info "Verifying SHA256 checksum..."
    (cd "$TMP_NERDCTL_DIR" && grep " ${NERDCTL_TGZ}\$" SHA256SUMS | sha256sum -c - >/dev/null) || {
        error "nerdctl checksum verification failed for ${NERDCTL_TGZ}"
        rm -rf "$TMP_NERDCTL_DIR"
        exit 1
    }
    tar -xzf "${TMP_NERDCTL_DIR}/${NERDCTL_TGZ}" -C "$TMP_NERDCTL_DIR" nerdctl
    sudo install -m 0755 "${TMP_NERDCTL_DIR}/nerdctl" "$NERDCTL_BIN"
    rm -rf "$TMP_NERDCTL_DIR"
    success "nerdctl ${NERDCTL_TAG} installed successfully."
fi
# Default containerd namespace of nerdctl: the one Kubernetes uses (same as on the golden node)
if [ ! -f /etc/nerdctl/nerdctl.toml ]; then
    sudo mkdir -p /etc/nerdctl
    echo 'namespace = "k8s.io"' | sudo tee /etc/nerdctl/nerdctl.toml >/dev/null
fi

# d) CNI plugins (kubernetes-cni from the Kubernetes apt repository; installs to /opt/cni/bin, where containerd and nerdctl look)
if dpkg -s kubernetes-cni >/dev/null 2>&1; then
    info "kubernetes-cni is already installed ($(dpkg-query -W -f='${Version}' kubernetes-cni)). Skipping."
else
    info "Installing kubernetes-cni (${KUBERNETES_VERSION}) on host via APT..."
    if [ ! -f /etc/apt/sources.list.d/kubernetes.list ]; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq apt-transport-https ca-certificates curl gpg
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    fi
    sudo apt-get update -qq
    sudo apt-get install -y kubernetes-cni
    success "kubernetes-cni installed successfully."
fi

# e) Reload systemd and (re)start containerd: restart only if the config changed above
sudo systemctl daemon-reload
sudo systemctl enable containerd
if [ "$CONTAINERD_CHANGED" = true ]; then
    sudo systemctl restart containerd
else
    sudo systemctl start containerd
fi
success "containerd $(containerd --version | awk '{print $3}') is running on the host ($(nerdctl --version))."

success "Host tooling ready."

# ------------------------------------------------------------------------------
# Step 21: Remove control-plane taints from control plane nodes
# ------------------------------------------------------------------------------
step_header "21" "Remove control-plane taints from control plane nodes"
info "Removing control-plane taints from control plane nodes (${CP_NODES[*]})..."
for NODE in "${CP_NODES[@]}"; do
    info "Untainting control plane node $NODE..."
    kubectl taint nodes "$NODE" node-role.kubernetes.io/control-plane- 2>/dev/null || true
done
success "Control-plane taints removed from ${CP_NODES[*]}."

# ------------------------------------------------------------------------------
# Step 22: Download Cilium Helm chart
# ------------------------------------------------------------------------------
step_header "22" "Download Cilium ${CILIUM_VERSION} Helm chart"
if [ -f "${SCRIPT_DIR}/cilium-${CILIUM_VERSION}.tgz" ]; then
    info "Cilium Helm chart already exists. Skipping download."
else
    info "Pulling Cilium Helm chart from OCI registry..."
    helm pull oci://quay.io/cilium/charts/cilium --version "${CILIUM_VERSION}"
    success "Cilium Helm chart downloaded."
fi

# ------------------------------------------------------------------------------
# Step 23: Template Cilium Helm chart into cilium.yaml
# ------------------------------------------------------------------------------
step_header "23" "Template Cilium Helm chart"
info "Rendering cilium.yaml from values..."
helm template cilium "${SCRIPT_DIR}/cilium-${CILIUM_VERSION}.tgz" \
    --namespace kube-system \
    -f "${SCRIPT_DIR}/cilium-deploy.yaml" > "${SCRIPT_DIR}/cilium.yaml"
success "cilium.yaml templated successfully."

# ------------------------------------------------------------------------------
# Step 24: Apply Cilium manifest
# ------------------------------------------------------------------------------
step_header "24" "Apply Cilium CNI"
info "Applying cilium.yaml..."
kubectl apply -f "${SCRIPT_DIR}/cilium.yaml"
success "Cilium manifest applied."

# ------------------------------------------------------------------------------
# Step 25: Wait for Cilium deployment readiness
# ------------------------------------------------------------------------------
step_header "25" "Wait for Cilium readiness"
info "Waiting for Cilium daemonsets and deployments to become ready..."
until cilium status --wait; do
    warn "Cilium status check timed out or not ready yet. Retrying in 5 seconds..."
    sleep 5
done
success "Cilium CNI is fully operational."

# ------------------------------------------------------------------------------
# Step 26: Check all nodes are in Ready status
# ------------------------------------------------------------------------------
step_header "26" "Verify all cluster nodes are Ready"
info "Waiting for all nodes to report condition Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes -o wide

# ------------------------------------------------------------------------------
# Step 27: Apply dnsutils test pod
# ------------------------------------------------------------------------------
step_header "27" "Apply dnsutils test pod"
kubectl apply -f "${SCRIPT_DIR}/dnsutils.yaml"
info "Waiting for dnsutils pod to be created/ready..."
kubectl wait --for=condition=Ready pod/dnsutils --timeout=120s || true
kubectl get pods -A

# ------------------------------------------------------------------------------
# Step 28: Install chartmuseum.service (local Helm chart repository, HELM_REPO_SERVER_PORT / CHARTS_DIR from inventory.txt)
# ------------------------------------------------------------------------------
step_header "28" "Install chartmuseum.service (port ${HELM_REPO_SERVER_PORT}, charts in ${CHARTS_DIR})"
# Created as the login user, so the directory is not owned by root (the service itself runs as root).
mkdir -p "$CHARTS_DIR"
info "Writing /etc/systemd/system/chartmuseum.service (overwritten if it exists)..."
sudo tee /etc/systemd/system/chartmuseum.service >/dev/null <<CHARTMUSEUM_EOF
[Unit]
Description=Chartmuseum for serving Helm charts locally
After=kubelet.service

[Service]
Type=exec
ExecStart=/usr/local/bin/chartmuseum --debug --port=${HELM_REPO_SERVER_PORT} --storage=local --storage-local-rootdir=${CHARTS_DIR}
TimeoutStartSec=600
LogLevelMax=notice

[Install]
WantedBy=multi-user.target
CHARTMUSEUM_EOF
sudo systemctl daemon-reload
sudo systemctl enable chartmuseum.service
# 'restart' (not 'start'): a re-run with a changed port or directory must also take effect when the service is running.
sudo systemctl restart chartmuseum.service

info "Waiting for chartmuseum to answer on port ${HELM_REPO_SERVER_PORT}..."
CM_READY=false
for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${HELM_REPO_SERVER_PORT}/health" >/dev/null 2>&1; then
        CM_READY=true
        break
    fi
    sleep 1
done
if ! $CM_READY; then
    error "chartmuseum did not become healthy on port ${HELM_REPO_SERVER_PORT}. Check: sudo journalctl -u chartmuseum.service"
    exit 1
fi
success "chartmuseum.service is running (http://${HOST_IP}:${HELM_REPO_SERVER_PORT}, charts in ${CHARTS_DIR})."

# ------------------------------------------------------------------------------
# Step 29: Set up the local Helm repo (served by chartmuseum, step 28)
# ------------------------------------------------------------------------------
step_header "29" "Set up the local Helm repo (http://${HOST_IP}:${HELM_REPO_SERVER_PORT})"
helm repo remove local || true
helm repo add local "http://${HOST_IP}:${HELM_REPO_SERVER_PORT}"
helm repo update
helm repo list

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${GREEN}==> Kubernetes HA Cluster on ${ENGINE_NAME} completed successfully!${NC}"
echo -e "${GREEN}======================================================================${NC}"
