#!/usr/bin/env bash
# ==============================================================================
# deploy_k8s_libvirt.sh - High-Availability Kubernetes Cluster on libvirt (KVM VMs)
# Implements all steps from steps_libvirt.txt
# Usage: ./deploy_k8s_libvirt.sh
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

Automates the deployment of a High-Availability Kubernetes cluster on libvirt (KVM Virtual Machines).
Cluster configuration and node counts are defined in 'inventory.txt'.

Options:
  -h             Show this help message
EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Parse CLI Options
# ------------------------------------------------------------------------------
while getopts "h" opt; do
    case "$opt" in
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

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
export LONGHORN_VERSION="${LONGHORN_VERSION:-v1.13.0}"
export LONGHORN_PORT="${LONGHORN_PORT:-9080}"
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

VIP="${VIP:-10.67.38.250}"
BRIDGE_IPV4="${BRIDGE_IPV4:-10.67.38.1}"

# Local Helm chart repository (chartmuseum, steps 30 and 31): checked here so a wrong value stops the script at the start.
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
BRIDGE="virbr0"
ENGINE_NAME="libvirt"

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
LIMITS_DISK="${LIMITS_DISK:-20GB}"

# Convert memory to MB for virt-install
MEM_NUM=$(echo "$LIMITS_MEMORY" | grep -o -E '[0-9]+')
if [[ "$LIMITS_MEMORY" =~ [gG] ]]; then
    MEM_MB=$((MEM_NUM * 1024))
else
    MEM_MB="$MEM_NUM"
fi

# Normalize disk size for qemu-img (e.g., 20GB or 20G -> 20G)
DISK_SIZE=$(echo "$LIMITS_DISK" | sed 's/[bB]$//')

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
declare -A NODE_MACS
declare -A BOOT_IDS   # boot ID of each clone before its reboot (used to detect the reboot)
for ((i=1; i<=TOTAL_NODES; i++)); do
    ENTRY="${HOSTS_ENTRIES[$((i-1))]}"
    IP=$(echo "$ENTRY" | awk '{print $1}')
    NODE=$(echo "$ENTRY" | awk '{print $2}')
    NODES+=("$NODE")
    NODE_IPS["$NODE"]="$IP"
    # Deterministic MAC: 52:54:00:10:00:<hex of IP 4th octet>
    LAST_OCTET=$(echo "$IP" | awk -F. '{printf "%02x", $4}')
    MAC="52:54:00:10:00:${LAST_OCTET}"
    NODE_MACS["$NODE"]="$MAC"
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

info "Selected hypervisor: ${ENGINE_NAME} (KVM Virtual Machines)"
info "Nodes configuration: ${NUM_CP} control plane node(s), ${NUM_WORKER} worker node(s)"

# ------------------------------------------------------------------------------
# Step 1: Install Hypervisor & Virtualization Tools on host
# ------------------------------------------------------------------------------
if [ "${_SKIP_STEP1:-false}" != "true" ]; then
    step_header "1" "Install QEMU/KVM, libvirt, virtinst, chrony, and python-is-python3 on host"
    MISSING_PKGS=()
    for pkg in qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst libguestfs-tools chrony python-is-python3; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            MISSING_PKGS+=("$pkg")
        fi
    done

    if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
        info "Installing missing virtualization packages: ${MISSING_PKGS[*]}..."
        sudo apt-get update -qq
        sudo apt-get install -y "${MISSING_PKGS[@]}"
    else
        info "All required virtualization packages are already installed."
    fi

    info "Ensuring libvirt daemon is running..."
    sudo systemctl enable --now libvirtd 2>/dev/null || true
    sudo systemctl start libvirtd 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# Step 2: Configure group membership for $SSH_USER
# ------------------------------------------------------------------------------
if [ "${_SKIP_STEP1:-false}" != "true" ]; then
    step_header "2" "Configure libvirt & kvm group membership for $SSH_USER"
    for GRP in libvirt kvm; do
        if ! id -nG "$SSH_USER" | grep -qw "$GRP"; then
            info "Adding $SSH_USER to group '$GRP'..."
            sudo usermod -aG "$GRP" "$SSH_USER"
        fi
    done
fi

# If libvirt group is not in current shell's active groups, re-execute the script using sg
if ! id -nG | grep -qw "libvirt"; then
    info "Activating 'libvirt' group for the current session without requiring logout..."
    exec sg "libvirt" -c "_SKIP_STEP1=true bash \"${SCRIPT_DIR}/deploy_k8s_libvirt.sh\""
fi
success "User $SSH_USER is in libvirt group and virsh commands can run without sudo."
if [ -f "$HOME/.bashrc" ] && ! grep -qs "LIBVIRT_DEFAULT_URI" "$HOME/.bashrc"; then
    echo 'export LIBVIRT_DEFAULT_URI="qemu:///system"' >> "$HOME/.bashrc"
fi

# ------------------------------------------------------------------------------
# Step 3: Disable UFW on host machine if present
# ------------------------------------------------------------------------------
step_header "3" "Disable UFW on host machine if present"
if command -v ufw >/dev/null 2>&1; then
    info "Disabling UFW..."
    sudo ufw disable || true
else
    info "UFW is not installed. Skipping."
fi

# ------------------------------------------------------------------------------
# Step 4: Configure kernel modules on host (vhost_net)
# ------------------------------------------------------------------------------
step_header "4" "Configure and load host kernel modules (vhost_net)"
info "Writing /etc/modules-load.d/k8s-libvirt.conf..."
sudo tee /etc/modules-load.d/k8s-libvirt.conf <<EOF
vhost_net
EOF

info "Loading vhost_net module..."
sudo modprobe vhost_net

# ------------------------------------------------------------------------------
# Step 5: Configure sysctl settings on host (net.ipv4.ip_forward = 1)
# ------------------------------------------------------------------------------
step_header "5" "Configure and apply host sysctl settings"
info "Writing /etc/sysctl.d/99-k8s-libvirt.conf..."
sudo tee /etc/sysctl.d/99-k8s-libvirt.conf <<EOF
net.ipv4.ip_forward = 1
EOF

info "Applying sysctl parameters..."
sudo sysctl --system

# ------------------------------------------------------------------------------
# Step 6: Initialize / update libvirt 'default' network (virbr0)
# ------------------------------------------------------------------------------
step_header "6" "Configure libvirt 'default' network for gateway ${BRIDGE_IPV4}"
SUBNET_PREFIX="${BRIDGE_IPV4%.*}"

# If 'default' network is not defined at all in libvirt, define it
if ! virsh net-info default >/dev/null 2>&1; then
    if [ -f /etc/libvirt/qemu/networks/default.xml ]; then
        info "Defining default network from /etc/libvirt/qemu/networks/default.xml..."
        sudo virsh net-define /etc/libvirt/qemu/networks/default.xml
    else
        info "Creating default network definition..."
        TMP_DEF=$(mktemp)
        cat <<EOF > "$TMP_DEF"
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='${BRIDGE}' stp='on' delay='0'/>
  <ip address='${BRIDGE_IPV4}' netmask='255.255.255.0'>
    <dhcp>
      <range start='${SUBNET_PREFIX}.100' end='${SUBNET_PREFIX}.200'/>
    </dhcp>
  </ip>
</network>
EOF
        virsh net-define "$TMP_DEF"
        rm -f "$TMP_DEF"
    fi
fi

CURRENT_IP=$(virsh net-dumpxml default 2>/dev/null | grep -o "ip address='[^']*'" | head -n 1 | cut -d"'" -f2 || true)

if [ "$CURRENT_IP" != "$BRIDGE_IPV4" ]; then
    info "Reconfiguring default libvirt network for gateway ${BRIDGE_IPV4}..."
    TMP_NET=$(mktemp)
    virsh net-dumpxml default > "$TMP_NET"
    sed -i "s|ip address='[^']*'|ip address='${BRIDGE_IPV4}'|g" "$TMP_NET"
    sed -i -E "s|<range start=['\"][^'\"]*['\"] end=['\"][^'\"]*['\"]/>|<range start='${SUBNET_PREFIX}.100' end='${SUBNET_PREFIX}.200'/>|g" "$TMP_NET"
    virsh net-define "$TMP_NET"
    virsh net-destroy default 2>/dev/null || true
    virsh net-start default
    virsh net-autostart default
    rm -f "$TMP_NET"
    success "Default libvirt network configured on ${BRIDGE_IPV4}."
else
    info "Default libvirt network is already active on ${BRIDGE_IPV4}."
    if ! virsh net-list | grep -qw "default"; then
        virsh net-start default
    fi
    virsh net-autostart default 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# Step 7: Configure firewall rules for bridge and Docker coexistence
# ------------------------------------------------------------------------------
step_header "7" "Configure bridge firewall and Docker coexistence"
BRIDGE_SUBNET="${SUBNET_PREFIX}.0/24"
if systemctl is-active --quiet docker; then
    info "Docker detected. Configuring idempotent iptables rules for bridge '${BRIDGE}'..."

    # Allow VM outbound traffic through Docker's chain
    if ! sudo iptables -C DOCKER-USER -i "$BRIDGE" -j ACCEPT 2>/dev/null; then
        sudo iptables -I DOCKER-USER -i "$BRIDGE" -j ACCEPT
    fi

    # Allow return internet traffic back into VM bridge
    if ! sudo iptables -C DOCKER-USER -o "$BRIDGE" -j ACCEPT 2>/dev/null; then
        sudo iptables -I DOCKER-USER -o "$BRIDGE" -j ACCEPT
    fi

    # Enable internet NAT translation for the VM subnet
    if ! sudo iptables -t nat -C POSTROUTING -s "$BRIDGE_SUBNET" ! -d "$BRIDGE_SUBNET" -j MASQUERADE 2>/dev/null; then
        sudo iptables -t nat -A POSTROUTING -s "$BRIDGE_SUBNET" ! -d "$BRIDGE_SUBNET" -j MASQUERADE
    fi

    info "Saving firewall rules..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent
    sudo netfilter-persistent save
    success "Firewall rules for '${BRIDGE}' configured and saved."
else
    info "Docker is not active. Skipping firewall adjustments."
fi

# ------------------------------------------------------------------------------
# Step 8: Download base Ubuntu Cloud Image & prepare directories
# ------------------------------------------------------------------------------
step_header "8" "Download base Ubuntu Cloud Image & prepare directories"
mkdir -p "${SCRIPT_DIR}/images"
case "$UBUNTU_VERSION" in
    24.04|noble) UBUNTU_CODENAME="noble" ;;
    22.04|jammy) UBUNTU_CODENAME="jammy" ;;
    *) UBUNTU_CODENAME="noble" ;;
esac

BASE_IMAGE="${SCRIPT_DIR}/images/ubuntu-${UBUNTU_VERSION}-base.qcow2"
if [ ! -f "$BASE_IMAGE" ]; then
    info "Downloading Ubuntu ${UBUNTU_VERSION} cloud image (${UBUNTU_CODENAME})..."
    curl -L --fail --progress-bar \
        -o "$BASE_IMAGE" \
        "https://cloud-images.ubuntu.com/${UBUNTU_CODENAME}/current/${UBUNTU_CODENAME}-server-cloudimg-amd64.img"
    success "Base cloud image saved to $BASE_IMAGE."
else
    info "Base cloud image already present at $BASE_IMAGE."
fi

# ------------------------------------------------------------------------------
# Step 9: Launch virtual machine node1
# ------------------------------------------------------------------------------
step_header "9" "Launch and start virtual machine: node1"
NODE1_IP="${NODE_IPS[node1]}"
NODE1_MAC="${NODE_MACS[node1]}"

# i) Register node1 static DHCP reservation in libvirt
if ! virsh net-dumpxml default 2>/dev/null | grep -q "$NODE1_MAC"; then
    info "Registering DHCP reservation for node1 ($NODE1_IP, $NODE1_MAC)..."
    sudo virsh net-update default add ip-dhcp-host "<host mac='${NODE1_MAC}' name='node1' ip='${NODE1_IP}'/>" --live --config
else
    info "DHCP reservation for node1 already exists."
fi

# ii) Locate or generate Host SSH Public Key
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
SSH_PUB_KEY_CONTENT=$(cat "$SSH_PUB_KEY")
info "Using SSH public key: $SSH_PUB_KEY"

# iii) Prepare node1 disk and launch VM if not present
if ! virsh dominfo node1 >/dev/null 2>&1; then
    info "Creating node1 disk in /var/lib/libvirt/images/node1.qcow2 (${DISK_SIZE})..."
    sudo cp "$BASE_IMAGE" /var/lib/libvirt/images/node1.qcow2
    sudo qemu-img resize /var/lib/libvirt/images/node1.qcow2 "$DISK_SIZE"

    info "Generating cloud-init user-data for ${SSH_USER}..."
    cat <<EOF > "${SCRIPT_DIR}/cloud-init-user-data.yaml"
#cloud-config
hostname: node1
fqdn: node1
users:
  - name: ${SSH_USER}
    gecos: ${SSH_USER}
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${SSH_PUB_KEY_CONTENT}
EOF

    info "Launching node1 using virt-install..."
    sudo virt-install \
        --name node1 \
        --vcpus "$LIMITS_CPU" \
        --memory "$MEM_MB" \
        --osinfo "ubuntu${UBUNTU_VERSION}" \
        --disk path=/var/lib/libvirt/images/node1.qcow2,format=qcow2,bus=virtio,cache=none \
        --network network=default,model=virtio,mac="$NODE1_MAC" \
        --cloud-init user-data="${SCRIPT_DIR}/cloud-init-user-data.yaml" \
        --import \
        --noautoconsole
else
    info "Virtual machine node1 already exists."
fi

# Ensure node1 is running
STATE=$(virsh domstate node1 2>/dev/null || true)
if [ "$STATE" != "running" ]; then
    info "Starting virtual machine node1..."
    virsh start node1
fi

info "Waiting for node1 to complete first boot and become reachable over SSH (${NODE1_IP})..."
until ssh "${SSH_OPTS[@]}" "${SSH_POLL_OPTS[@]}" "${SSH_USER}@${NODE1_IP}" "true" 2>/dev/null; do
    sleep 2
done
success "node1 is running and accessible via SSH."

# ------------------------------------------------------------------------------
# Step 10: Configure chrony on host (time server for the VMs)
# chrony is installed in step 1. The host uses its own clock as the reference (local stratum 8) and lets the VMs of
# the bridge subnet (BRIDGE_SUBNET, set in step 7) sync to it; the VMs' chrony points at BRIDGE_IPV4 (golden node, step 12).
# ------------------------------------------------------------------------------
step_header "10" "Configure chrony on host (time server for ${BRIDGE_SUBNET})"
if [ ! -f /etc/chrony/chrony.conf.bak ]; then
    info "Backing up /etc/chrony/chrony.conf to /etc/chrony/chrony.conf.bak..."
    sudo mv -f /etc/chrony/chrony.conf /etc/chrony/chrony.conf.bak
fi
info "Writing /etc/chrony/chrony.conf (allow ${BRIDGE_SUBNET})..."
sudo tee /etc/chrony/chrony.conf >/dev/null <<CHRONY_EOF
# Use the local clock as a reference time source
local stratum 8

# Allow manual adjustments and use it for drift calculation
manual

# Allow VMs to connect
allow ${BRIDGE_SUBNET}

# Record the rate at which the system clock gains/losses time
driftfile /var/lib/chrony/drift
CHRONY_EOF
sudo systemctl enable chrony 2>/dev/null || true
sudo systemctl restart chrony
chronyc -n sources || true
chronyc -n tracking || true
success "Host chrony configured (serving ${BRIDGE_SUBNET})."

# ------------------------------------------------------------------------------
# Step 11: Configure /etc/hosts on host and inside node1
# ------------------------------------------------------------------------------
step_header "11" "Configure /etc/hosts on host and inside node1"
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
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "sudo sed -i -E '/[[:space:]]${NODE_NAME}([[:space:]]|$)/d' /etc/hosts && echo -e '${IP}\t${NODE_NAME}' | sudo tee -a /etc/hosts >/dev/null"
done
success "node1 /etc/hosts configuration complete."

# ------------------------------------------------------------------------------
# Step 12: Configure Golden Node (node1) with runtime & k8s packages
# ------------------------------------------------------------------------------
step_header "12" "Prepare Golden Node (node1) with OS updates, containerd, chrony, Kubernetes packages, and Longhorn prerequisites"
NODE="node1"
info "--- Configuring runtime and Kubernetes binaries on $NODE ---"

ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "KUBERNETES_VERSION='${KUBERNETES_VERSION}' CHRONY_SERVER='${BRIDGE_IPV4}' HOST_IP='${HOST_IP}' bash -s" <<'EOF'
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive

    echo "==> 1. Updating and upgrading OS packages..."
    sudo apt-get update -qq
    sudo apt-get upgrade -y -qq

    echo "==> 2. Disabling UFW firewall and disabling swap..."
    sudo ufw disable 2>/dev/null || true
    sudo swapoff -a
    sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab

    echo "==> 3. Configuring kernel modules (overlay, br_netfilter)..."
    sudo tee /etc/modules-load.d/k8s.conf >/dev/null <<MODULES_EOF
overlay
br_netfilter
MODULES_EOF
    sudo modprobe overlay
    sudo modprobe br_netfilter

    echo "==> 4. Configuring sysctl parameters..."
    sudo tee /etc/sysctl.d/99-k8s.conf >/dev/null <<SYSCTL_EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL_EOF
    sudo sysctl --system >/dev/null

    echo "==> 5. Installing containerd.io, qemu-guest-agent, and chrony..."
    sudo apt-get install -y -qq ca-certificates curl gpg apt-transport-https jq qemu-guest-agent chrony
    sudo systemctl enable --now qemu-guest-agent
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

    echo "==> 6. Configuring containerd (SystemdCgroup = true, disabled_plugins = [], plain-http registry ${HOST_IP}:5000)..."
    sudo rm -rf /etc/containerd/config.toml
    sudo mkdir -p /etc/containerd
    containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    sudo sed -i 's/disabled_plugins = .*/disabled_plugins = []/g' /etc/containerd/config.toml
    # Plain-http registry on the host (containerd 2.x): point the registry section's config_path at /etc/containerd/certs.d
    # (only the config_path line inside the [plugins.'io.containerd.cri.v1.images'.registry] section is changed) ...
    sudo sed -i "/^[[:space:]]*\[plugins\.'io\.containerd\.cri\.v1\.images'\.registry\][[:space:]]*\$/,/^[[:space:]]*\[/ s|config_path = .*|config_path = '/etc/containerd/certs.d'|" /etc/containerd/config.toml
    if ! grep -q "config_path = '/etc/containerd/certs.d'" /etc/containerd/config.toml; then
        echo "ERROR: could not set config_path in the [plugins.'io.containerd.cri.v1.images'.registry] section of /etc/containerd/config.toml (is this not containerd 2.x?)." >&2
        exit 1
    fi
    # ... and add the host entry for the registry at ${HOST_IP}:5000 (plain http, pull / resolve / push, no TLS verification).
    sudo mkdir -p "/etc/containerd/certs.d/${HOST_IP}:5000"
    sudo tee "/etc/containerd/certs.d/${HOST_IP}:5000/hosts.toml" >/dev/null <<HOSTS_EOF
server = "http://${HOST_IP}:5000"
[host."http://${HOST_IP}:5000"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
HOSTS_EOF
    sudo systemctl daemon-reload
    sudo systemctl restart containerd

    echo "==> 7. Installing Kubernetes packages (${KUBERNETES_VERSION})..."
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo apt-get update -qq
    sudo apt-get install -y kubelet kubeadm kubectl cri-tools
    sudo apt-mark hold kubelet kubeadm kubectl cri-tools
    sudo systemctl enable --now kubelet

    echo "==> 8. Pre-pulling Kubernetes images and updating sandbox image..."
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

    echo "==> 9. Longhorn prerequisites (nfs-common, multipath off, kernel modules, iscsid)..."
    # Done on the golden node so every cloned node inherits it. The 'systemctl stop/disable' calls end with
    # '|| true' because some multipath units do not exist on every Ubuntu release (e.g. multipath-tools-boot).
    sudo apt-get update -qq
    sudo apt-get install -y -qq nfs-common
    for UNIT in multipathd.service multipathd.socket multipath-tools.service multipath-tools-boot.service; do
        sudo systemctl stop "$UNIT" 2>/dev/null || true
        sudo systemctl disable "$UNIT" 2>/dev/null || true
    done
    sudo modprobe dm_crypt
    echo dm_crypt | sudo tee /etc/modules-load.d/longhorn.conf >/dev/null
    sudo modprobe iscsi_tcp
    echo iscsi_tcp | sudo tee -a /etc/modules-load.d/longhorn.conf >/dev/null
    sudo modprobe nfs
    echo nfs | sudo tee -a /etc/modules-load.d/longhorn.conf >/dev/null
    sudo systemctl start iscsid
    sudo systemctl enable iscsid

    echo "==> 10. Generalizing netplan configuration for cloned nodes..."
    sudo tee /etc/netplan/50-cloud-init.yaml >/dev/null <<NETPLAN_EOF
network:
  version: 2
  ethernets:
    id0:
      match:
        name: "en*"
      dhcp4: true
      dhcp-identifier: mac
NETPLAN_EOF
    sudo chmod 600 /etc/netplan/50-cloud-init.yaml
    sudo netplan apply

    echo "==> 11. Configuring chrony to sync from the host (${CHRONY_SERVER})..."
    # Done on the golden node so every cloned node inherits it. The original config is kept once as chrony.conf.bak.
    if [ ! -f /etc/chrony/chrony.conf.bak ]; then
        sudo mv -f /etc/chrony/chrony.conf /etc/chrony/chrony.conf.bak
    fi
    sudo tee /etc/chrony/chrony.conf >/dev/null <<CHRONY_EOF
# Chrony server
server ${CHRONY_SERVER} iburst

# This directive records the rate at which the system clock gains or loses time.
driftfile /var/lib/chrony/chrony.drift

# If the clock offset is larger than 1 second, step it rather than slew.
makestep 1 3
CHRONY_EOF
    sudo systemctl enable chrony 2>/dev/null || true
    sudo systemctl restart chrony
    chronyc -n sources || true
    chronyc -n tracking || true
EOF
success "Golden Node (node1) configured with runtime, packages, and pre-cached images."

# ------------------------------------------------------------------------------
# Step 13: Clone remaining nodes from node1 (Golden Image)
# ------------------------------------------------------------------------------
if [ "${#CLONE_NODES[@]}" -gt 0 ]; then
    step_header "13" "Clone remaining nodes (${CLONE_NODES[*]}) from node1"

    # i) Gracefully stop node1 and wait for it to stop
    info "Gracefully stopping node1 before cloning..."
    if [ "$(virsh domstate node1 2>/dev/null)" != "shut off" ]; then
        virsh shutdown node1 2>/dev/null || true
    fi
    until [ "$(virsh domstate node1 2>/dev/null)" = "shut off" ]; do
        info "Waiting for node1 to shut down..."
        sleep 1
    done
    success "node1 is shut off."

    # Eject cloud-init cdrom if attached
    sudo virsh change-media node1 sda --eject --config --force 2>/dev/null || true

    # ii) Register static DHCP reservations and clone nodes
    for TARGET_NODE in "${CLONE_NODES[@]}"; do
        IP="${NODE_IPS[$TARGET_NODE]}"
        MAC="${NODE_MACS[$TARGET_NODE]}"

        if ! virsh net-dumpxml default 2>/dev/null | grep -q "$MAC"; then
            info "Registering DHCP reservation for $TARGET_NODE ($IP, $MAC)..."
            sudo virsh net-update default add ip-dhcp-host "<host mac='${MAC}' name='${TARGET_NODE}' ip='${IP}'/>" --live --config
        fi

        if ! virsh dominfo "$TARGET_NODE" >/dev/null 2>&1; then
            info "Cloning $TARGET_NODE from node1 (MAC: $MAC)..."
            sudo virt-clone -o node1 -n "$TARGET_NODE" -m "$MAC" -f "/var/lib/libvirt/images/${TARGET_NODE}.qcow2"
        else
            info "Virtual machine $TARGET_NODE already exists."
        fi
    done

    # iii) Start all nodes
    for NODE in "${NODES[@]}"; do
        STATE=$(virsh domstate "$NODE" 2>/dev/null || true)
        if [ "$STATE" != "running" ]; then
            info "Starting $NODE..."
            virsh start "$NODE"
        fi
    done

    # iv) Personalize hostname, regenerate machine-id, and reboot each clone
    for TARGET_NODE in "${CLONE_NODES[@]}"; do
        IP="${NODE_IPS[$TARGET_NODE]}"
        info "Waiting for $TARGET_NODE ($IP) SSH to respond..."
        until ssh "${SSH_OPTS[@]}" "${SSH_POLL_OPTS[@]}" "${SSH_USER}@${IP}" "true" 2>/dev/null; do
            sleep 1
        done

        # Remember the boot ID, so that step v can tell the reboot below really happened
        BOOT_IDS["$TARGET_NODE"]=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" "cat /proc/sys/kernel/random/boot_id")

        info "Personalizing hostname, machine-id, and regenerating SSH host keys on $TARGET_NODE..."
        ssh "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" "
            sudo hostnamectl set-hostname ${TARGET_NODE}
            sudo rm -f /etc/machine-id /var/lib/dbus/machine-id
            sudo systemd-machine-id-setup
            sudo rm -f /etc/ssh/ssh_host_*
            sudo ssh-keygen -A
            sudo reboot
        " || true
    done

    # v) Wait for all nodes to reboot, verify SSH connectivity and hostnames, and populate known_hosts
    info "Verifying all nodes (${NODES[*]}) are running and reachable via SSH..."
    for NODE in "${NODES[@]}"; do
        # Clones: first wait until the node runs a new boot (boot ID differs from the one recorded before the
        # reboot), so that an SSH answer from the still-running old boot is not taken as "rebooted".
        if [ -n "${BOOT_IDS[$NODE]:-}" ]; then
            info "Waiting for $NODE to reboot (boot ID change)..."
            BOOT_DEADLINE=$((SECONDS + 600))
            until NEW_BOOT_ID=$(ssh "${SSH_OPTS[@]}" "${SSH_POLL_OPTS[@]}" "${SSH_USER}@${NODE}" "cat /proc/sys/kernel/random/boot_id" 2>/dev/null) \
                  && [ -n "$NEW_BOOT_ID" ] && [ "$NEW_BOOT_ID" != "${BOOT_IDS[$NODE]}" ]; do
                if [ "$SECONDS" -ge "$BOOT_DEADLINE" ]; then
                    error "$NODE did not come back with a new boot ID within 600 seconds."
                    exit 1
                fi
                sleep 1
            done
        fi
        until ssh "${SSH_OPTS[@]}" "${SSH_POLL_OPTS[@]}" "${SSH_USER}@${NODE}" "hostname" 2>/dev/null | grep -q "$NODE"; do
            sleep 1
        done
        success "Node $NODE is running, personalized, and reachable via SSH."
        ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$NODE" >/dev/null 2>&1 || true
        ssh-keygen -f "$HOME/.ssh/known_hosts" -R "${NODE_IPS[$NODE]}" >/dev/null 2>&1 || true
        ssh-keyscan -H "$NODE" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
        ssh-keyscan -H "${NODE_IPS[$NODE]}" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
    done
else
    step_header "13" "Single-node deployment (skipping cloning)"
    info "Only node1 is defined; skipping clone step."
fi
success "All nodes (${NODES[*]}) are cloned, started, and reachable via SSH."

# ------------------------------------------------------------------------------
# Step 14: Bootstrap node1 with kube-vip and kubeadm init
# ------------------------------------------------------------------------------
step_header "14" "Bootstrap control plane on node1"

# Generate and configure kube-vip static pod manifest on node1
info "Generating and configuring kube-vip static pod manifest on node1 (VIP: $VIP)..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "VIP='${VIP}' bash -s" <<'EOF'
    set -e
    # Detect primary virtio network interface
    INTERFACE=$(ip -4 route show default | awk '{print $5}' | head -n1)
    if [ -z "$INTERFACE" ]; then
        INTERFACE="enp1s0"
    fi
    echo "Using primary network interface: $INTERFACE"

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
        sudo kubeadm init --config ./kubeadm-init-config.yaml --upload-certs
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
# Step 15: Copy k8s config file from node1 to host
# ------------------------------------------------------------------------------
step_header "15" "Copy k8s config from node1 to host"
mkdir -p "$HOME/.kube"
scp "${SSH_OPTS[@]}" "${SSH_USER}@node1:/home/${SSH_USER}/.kube/config" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
success "Kubeconfig successfully copied to $HOME/.kube/config."

# ------------------------------------------------------------------------------
# Step 16: Validate join credentials for remaining control plane nodes
# ------------------------------------------------------------------------------
step_header "16" "Validate join credentials for control plane nodes"
info "Active join credentials verified for control plane VIP: ${VIP} (joining: ${CP_JOIN_NODES[*]})"
success "Join credentials ready."

# ------------------------------------------------------------------------------
# Step 17: Join remaining control plane nodes to cluster
# ------------------------------------------------------------------------------
step_header "17" "Join remaining control planes (${CP_JOIN_NODES[*]})"
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
            sudo kubeadm join --config ./kubeadm-join-cp-config.yaml
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
# Step 18: Distribute kube-vip.yaml to remaining control plane nodes
# ------------------------------------------------------------------------------
step_header "18" "Distribute kube-vip.yaml to remaining control plane nodes (${CP_JOIN_NODES[*]})"
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
# Step 19: Join worker nodes to cluster
# ------------------------------------------------------------------------------
if [ "${#WORKER_NODES[@]}" -gt 0 ]; then
    step_header "19" "Join worker nodes (${WORKER_NODES[*]}) to cluster"
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
                sudo kubeadm join --config ./kubeadm-join-worker-config.yaml
            else
                echo "Worker node has already joined."
            fi
        '
        success "$NODE joined as worker node successfully."
    done
    success "All worker nodes (${WORKER_NODES[*]}) joined successfully."
else
    step_header "19" "Join worker nodes to cluster"
    info "No worker nodes defined (NUM_WORKER=0). Skipping worker join."
fi

# ------------------------------------------------------------------------------
# Step 20: Install the certificate check and renewal scripts on the control plane nodes
# ------------------------------------------------------------------------------
# certs/check_k8s_certs.sh and certs/renew_k8s_control_plane_certs.sh go to /usr/local/bin, the systemd service and timer
# (check every 12 hours, renew when a control plane certificate expires within 60 days) to /etc/systemd/system.
# Only the control plane nodes get them; workers have no control plane certificates.
# DEPLOY_USER in renew_k8s_control_plane_certs.sh is set to ${SSH_USER}: the script also replaces that user's ~/.kube/config.
# certs/renew_k8s_kubelet_client_cert_from_host.sh (kubelet client certificate of a node) is not installed: it is run by hand on the host.
# The repo holds it as certs/renew_k8s_kubelet_client_cert_from_host.sh.template; this step renders certs/renew_k8s_kubelet_client_cert_from_host.sh
# from it (FIRST_NODE set to node1, mode 0755). The rendered file is not tracked by git and is overwritten on every run.
# certs/renew_k8s_control_plane_certs_from_host.sh (renews the certificates on all control plane nodes, then copies the new
# kubeconfig to the host and the worker nodes) is also not installed: it is run by hand on the host.
# Its template certs/renew_k8s_control_plane_certs_from_host.sh.template is rendered the same way (FIRST_NODE, OTHER_CP_NODES, WORKER_NODES set).
step_header "20" "Install certificate check and renewal scripts on control plane nodes (${CP_NODES[*]})"
CERTS_DIR="${SCRIPT_DIR}/certs"
CERTS_FILES=(check_k8s_certs.sh renew_k8s_control_plane_certs.sh check_k8s_certs.service check_k8s_certs.timer)
KUBELET_RENEW_SCRIPT="renew_k8s_kubelet_client_cert_from_host.sh"
CP_RENEW_HOST_SCRIPT="renew_k8s_control_plane_certs_from_host.sh"
for F in "${CERTS_FILES[@]}" "${KUBELET_RENEW_SCRIPT}.template" "${CP_RENEW_HOST_SCRIPT}.template"; do
    if [ ! -f "${CERTS_DIR}/${F}" ]; then
        error "${CERTS_DIR}/${F} not found!"
        exit 1
    fi
done

info "Rendering ${CERTS_DIR}/${KUBELET_RENEW_SCRIPT} from its template (FIRST_NODE=node1)..."
sed "s|^FIRST_NODE=.*|FIRST_NODE=\"node1\"|" "${CERTS_DIR}/${KUBELET_RENEW_SCRIPT}.template" > "${CERTS_DIR}/${KUBELET_RENEW_SCRIPT}"
chmod 0755 "${CERTS_DIR}/${KUBELET_RENEW_SCRIPT}"

info "Rendering ${CERTS_DIR}/${CP_RENEW_HOST_SCRIPT} from its template (FIRST_NODE, OTHER_CP_NODES, WORKER_NODES)..."
sed \
    -e "s|^FIRST_NODE=.*|FIRST_NODE=\"node1\"|" \
    -e "s|^OTHER_CP_NODES=.*|OTHER_CP_NODES=\"${CP_NODES[*]:1}\"|" \
    -e "s|^WORKER_NODES=.*|WORKER_NODES=\"${WORKER_NODES[*]}\"|" \
    "${CERTS_DIR}/${CP_RENEW_HOST_SCRIPT}.template" > "${CERTS_DIR}/${CP_RENEW_HOST_SCRIPT}"
chmod 0755 "${CERTS_DIR}/${CP_RENEW_HOST_SCRIPT}"

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
# Step 21: Install cilium CLI, helm, kubectl, yq, chartmuseum, containerd (with nerdctl and CNI plugins), BuildKit, and a local registry on host
# ------------------------------------------------------------------------------
step_header "21" "Install cilium CLI, Helm, Kubectl, yq, chartmuseum, containerd (with nerdctl and CNI plugins), BuildKit, and a local registry on host"

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

# iv) yq (mikefarah/yq, latest release)
if command -v yq >/dev/null 2>&1; then
    info "yq is already installed ($(command -v yq)). Skipping."
else
    info "Installing yq (latest release) on host..."
    YQ_ARCH=amd64
    if [ "$(uname -m)" = "aarch64" ]; then YQ_ARCH=arm64; fi
    YQ_BASE_URL="https://github.com/mikefarah/yq/releases/latest/download"
    YQ_BIN="yq_linux_${YQ_ARCH}"

    info "Downloading ${YQ_BIN}..."
    TMP_YQ_DIR=$(mktemp -d)
    curl -L --fail --progress-bar "${YQ_BASE_URL}/${YQ_BIN}" -o "${TMP_YQ_DIR}/${YQ_BIN}"
    curl -L --fail -s "${YQ_BASE_URL}/checksums" -o "${TMP_YQ_DIR}/checksums"
    curl -L --fail -s "${YQ_BASE_URL}/checksums_hashes_order" -o "${TMP_YQ_DIR}/checksums_hashes_order"

    # The 'checksums' file has one column per hash type (filename first); find the SHA-256 column.
    info "Verifying SHA256 checksum..."
    YQ_SHA_LINE=$(grep -n -x 'SHA-256' "${TMP_YQ_DIR}/checksums_hashes_order" | head -n 1 | cut -d: -f1)
    YQ_EXPECTED_SHA=$(awk -v bin="$YQ_BIN" -v col="$((YQ_SHA_LINE + 1))" '$1 == bin {print $col}' "${TMP_YQ_DIR}/checksums")
    YQ_ACTUAL_SHA=$(sha256sum "${TMP_YQ_DIR}/${YQ_BIN}" | awk '{print $1}')
    if [ -z "$YQ_EXPECTED_SHA" ] || [ "$YQ_EXPECTED_SHA" != "$YQ_ACTUAL_SHA" ]; then
        error "yq checksum verification failed for ${YQ_BIN}"
        rm -rf "$TMP_YQ_DIR"
        exit 1
    fi

    sudo install -m 0755 "${TMP_YQ_DIR}/${YQ_BIN}" /usr/local/bin/yq
    rm -rf "$TMP_YQ_DIR"
    success "yq $(yq --version | awk '{print $NF}') installed successfully."
fi

# v) chartmuseum (helm/chartmuseum, latest release; the binary path is the one used by chartmuseum.service in step 30)
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

# vi) containerd (with nerdctl and the CNI plugins) on the host. It follows the golden node's runtime setup (step 12) without the
# Kubernetes-only parts (pause image, kubeadm image pre-pull, kubelet / kubeadm / cri-tools), so Kubernetes can be added to
# the host later. Every part is skipped if it is already in place; existing files are kept unchanged.
CONTAINERD_CHANGED=false

# a) Kernel modules and sysctl settings for containers (steps 4 and 5 only cover vhost_net and ip_forward)
if [ ! -f /etc/modules-load.d/k8s.conf ]; then
    info "Writing /etc/modules-load.d/k8s.conf (overlay, br_netfilter)..."
    printf 'overlay\nbr_netfilter\n' | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
fi
sudo modprobe overlay
sudo modprobe br_netfilter
if [ ! -f /etc/sysctl.d/99-k8s.conf ]; then
    info "Writing /etc/sysctl.d/99-k8s.conf (bridge-nf-call-iptables, bridge-nf-call-ip6tables, ip_forward)..."
    printf 'net.bridge.bridge-nf-call-iptables  = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward                 = 1\n' \
        | sudo tee /etc/sysctl.d/99-k8s.conf >/dev/null
fi
sudo sysctl --system >/dev/null

# b) containerd.io (Docker apt repository)
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

# c) containerd config (SystemdCgroup = true, disabled_plugins = []); the original config is kept once as config.toml.bak
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

# d) nerdctl (latest release, minimal build, SHA-256 verified; the tag comes from the redirect of .../releases/latest, so there is
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

# e) CNI plugins (kubernetes-cni from the Kubernetes apt repository; installs to /opt/cni/bin, where containerd and nerdctl look)
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

# f) Reload systemd and (re)start containerd: restart only if the config changed above
sudo systemctl daemon-reload
sudo systemctl enable containerd
if [ "$CONTAINERD_CHANGED" = true ]; then
    sudo systemctl restart containerd
else
    sudo systemctl start containerd
fi
success "containerd $(containerd --version | awk '{print $3}') is running on the host ($(nerdctl --version))."

# vii) BuildKit on the host (latest release from github.com/moby/buildkit, installed to /usr/local/bin). The tag comes from the
# redirect of .../releases/latest, so there is no GitHub API rate limit. The release publishes no checksum file, so the download
# is not checksum-verified (it is fetched over HTTPS from GitHub). Every part is skipped if it is already in place.
BUILDKIT_CHANGED=false

# a) buildkit binaries (buildkitd, buildctl, ...)
BUILDKITD_BIN="/usr/local/bin/buildkitd"
if [ -x "$BUILDKITD_BIN" ]; then
    info "buildkitd is already installed (${BUILDKITD_BIN}). Skipping."
else
    info "Installing BuildKit (latest release) on host..."
    BUILDKIT_ARCH=$(dpkg --print-architecture)
    BUILDKIT_TAG=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/moby/buildkit/releases/latest)
    BUILDKIT_TAG="${BUILDKIT_TAG##*/}"
    if [[ ! "$BUILDKIT_TAG" =~ ^v[0-9] ]]; then
        error "Could not determine the latest BuildKit release (got '${BUILDKIT_TAG}')."
        exit 1
    fi
    BUILDKIT_TGZ="buildkit-${BUILDKIT_TAG}.linux-${BUILDKIT_ARCH}.tar.gz"
    TMP_BUILDKIT_DIR=$(mktemp -d)
    info "Downloading ${BUILDKIT_TGZ}..."
    curl -L --fail --progress-bar "https://github.com/moby/buildkit/releases/download/${BUILDKIT_TAG}/${BUILDKIT_TGZ}" -o "${TMP_BUILDKIT_DIR}/${BUILDKIT_TGZ}"
    # The archive holds bin/buildkitd, bin/buildctl, ...; extracting into /usr/local puts them in /usr/local/bin
    sudo tar -xzf "${TMP_BUILDKIT_DIR}/${BUILDKIT_TGZ}" -C /usr/local
    rm -rf "$TMP_BUILDKIT_DIR"
    BUILDKIT_CHANGED=true
    success "BuildKit ${BUILDKIT_TAG} installed successfully."
fi

# b) systemd unit
BUILDKITD_UNIT="/etc/systemd/system/buildkitd.service"
if [ -f "$BUILDKITD_UNIT" ]; then
    info "${BUILDKITD_UNIT} already exists. Skipping."
else
    info "Writing ${BUILDKITD_UNIT}..."
    sudo tee "$BUILDKITD_UNIT" >/dev/null <<'BUILDKITD_UNIT_EOF'
[Unit]
Description=buildkitd
After=network-online.target firewalld.service containerd.service time-set.target
Wants=network-online.target containerd.service

[Service]
Type=notify
ExecStart=buildkitd
TimeoutStartSec=0
RestartSec=2
Restart=always

[Install]
WantedBy=multi-user.target
BUILDKITD_UNIT_EOF
    BUILDKIT_CHANGED=true
fi

# c) buildkitd config: the local registry on the host is plain HTTP
BUILDKITD_CONFIG="/etc/buildkit/buildkitd.toml"
if [ -f "$BUILDKITD_CONFIG" ]; then
    info "${BUILDKITD_CONFIG} already exists. Skipping."
else
    info "Writing ${BUILDKITD_CONFIG} (registry ${HOST_IP}:5000 over http)..."
    sudo mkdir -p /etc/buildkit
    sudo tee "$BUILDKITD_CONFIG" >/dev/null <<BUILDKITD_CONFIG_EOF
[registry."${HOST_IP}:5000"]
  http = true
BUILDKITD_CONFIG_EOF
    BUILDKIT_CHANGED=true
fi

# d) buildkitd shares the containerd systemd drop-ins through a symlink; the directory is created first so the link is never dangling
BUILDKITD_DROPIN_DIR="/etc/systemd/system/buildkitd.service.d"
if [ -e "$BUILDKITD_DROPIN_DIR" ] || [ -L "$BUILDKITD_DROPIN_DIR" ]; then
    info "${BUILDKITD_DROPIN_DIR} already exists. Skipping."
else
    sudo mkdir -p /etc/systemd/system/containerd.service.d
    sudo ln -s /etc/systemd/system/containerd.service.d "$BUILDKITD_DROPIN_DIR"
    BUILDKIT_CHANGED=true
fi

# e) Reload systemd and enable buildkitd; restart it if anything changed above, otherwise just start it
sudo systemctl daemon-reload
sudo systemctl enable buildkitd
if [ "$BUILDKIT_CHANGED" = true ]; then
    sudo systemctl restart buildkitd
else
    sudo systemctl start buildkitd
fi
success "buildkitd is running on the host ($(buildkitd --version | awk '{print $3}'))."

# vii) Local container registry on the host (registry:3 on port 5000, plain http; the nodes' containerd and buildkitd use it as ${HOST_IP}:5000).
# nerdctl uses the k8s.io namespace here (/etc/nerdctl/nerdctl.toml).
if sudo nerdctl ps -a --format '{{.Names}}' | grep -qx registry; then
    if sudo nerdctl ps --format '{{.Names}}' | grep -qx registry; then
        info "The container 'registry' is already running. Skipping."
    else
        info "The container 'registry' exists but is not running; starting it..."
        sudo nerdctl start registry
    fi
else
    info "Starting the local registry container (registry:3, port 5000)..."
    sudo nerdctl run -d -p 5000:5000 --restart=always --name registry registry:3
fi
success "Local registry is available on the host (${HOST_IP}:5000)."

success "Host tooling ready."

# ------------------------------------------------------------------------------
# Step 22: Remove control-plane taints from control plane nodes
# ------------------------------------------------------------------------------
step_header "22" "Remove control-plane taints from control plane nodes"
info "Removing control-plane taints from control plane nodes (${CP_NODES[*]})..."
for NODE in "${CP_NODES[@]}"; do
    info "Untainting control plane node $NODE..."
    kubectl taint nodes "$NODE" node-role.kubernetes.io/control-plane- 2>/dev/null || true
done
success "Control-plane taints removed from ${CP_NODES[*]}."

# ------------------------------------------------------------------------------
# Step 23: Download Cilium Helm chart
# ------------------------------------------------------------------------------
step_header "23" "Download Cilium ${CILIUM_VERSION} Helm chart"
if [ -f "${SCRIPT_DIR}/cilium-${CILIUM_VERSION}.tgz" ]; then
    info "Cilium Helm chart already exists. Skipping download."
else
    info "Pulling Cilium Helm chart from OCI registry..."
    helm pull oci://quay.io/cilium/charts/cilium --version "${CILIUM_VERSION}"
    success "Cilium Helm chart downloaded."
fi

# ------------------------------------------------------------------------------
# Step 24: Template Cilium Helm chart into cilium.yaml
# ------------------------------------------------------------------------------
step_header "24" "Template Cilium Helm chart"
info "Rendering cilium.yaml from values..."
helm template cilium "${SCRIPT_DIR}/cilium-${CILIUM_VERSION}.tgz" \
    --namespace kube-system \
    -f "${SCRIPT_DIR}/cilium-deploy.yaml" > "${SCRIPT_DIR}/cilium.yaml"
success "cilium.yaml templated successfully."

# ------------------------------------------------------------------------------
# Step 25: Apply Cilium manifest
# ------------------------------------------------------------------------------
step_header "25" "Apply Cilium CNI"
info "Applying cilium.yaml..."
kubectl apply -f "${SCRIPT_DIR}/cilium.yaml"
success "Cilium manifest applied."

# ------------------------------------------------------------------------------
# Step 26: Wait for Cilium deployment readiness
# ------------------------------------------------------------------------------
step_header "26" "Wait for Cilium readiness"
info "Waiting for Cilium daemonsets and deployments to become ready..."
until cilium status --wait; do
    warn "Cilium status check timed out or not ready yet. Retrying in 5 seconds..."
    sleep 5
done
success "Cilium CNI is fully operational."

# ------------------------------------------------------------------------------
# Step 27: Install Longhorn (LONGHORN_VERSION / LONGHORN_PORT from inventory.txt)
# ------------------------------------------------------------------------------
# The node prerequisites (nfs-common, multipath off, kernel modules, iscsid) are done on the golden node in step 12.
step_header "27" "Install Longhorn ${LONGHORN_VERSION}"
if [[ ! "$LONGHORN_PORT" =~ ^[0-9]+$ ]] || [ "$LONGHORN_PORT" -lt 1 ] || [ "$LONGHORN_PORT" -gt 65535 ]; then
    error "Invalid LONGHORN_PORT='${LONGHORN_PORT}' in inventory.txt! It must be a port number (1-65535)."
    exit 1
fi
# Saved under a versioned name so a longhorn.yaml kept in this directory is never overwritten.
LONGHORN_MANIFEST="${SCRIPT_DIR}/longhorn-${LONGHORN_VERSION}.yaml"
info "Downloading the Longhorn ${LONGHORN_VERSION} manifest to ${LONGHORN_MANIFEST}..."
curl -s -L --fail "https://raw.githubusercontent.com/longhorn/longhorn/${LONGHORN_VERSION}/deploy/longhorn.yaml" -o "$LONGHORN_MANIFEST"

info "Patching the manifest: longhorn-frontend externalIP ${VIP}, port ${LONGHORN_PORT}; guaranteed-instance-manager-cpu: 0..."
# 1) Service longhorn-frontend: externalIPs = [VIP] and port of the 'http' port (default 80) = LONGHORN_PORT.
# 2) ConfigMap longhorn-default-setting: append 'guaranteed-instance-manager-cpu: 0' to default-setting.yaml
#    (skipped if the manifest already has that setting, so the key can never be duplicated).
LONGHORN_VIP="$VIP" LONGHORN_PORT="$LONGHORN_PORT" yq -i '
    (select(.kind == "Service" and .metadata.name == "longhorn-frontend") | .spec.externalIPs) = [strenv(LONGHORN_VIP)] |
    (select(.kind == "Service" and .metadata.name == "longhorn-frontend") | .spec.ports[] | select(.name == "http") | .port) = (strenv(LONGHORN_PORT) | tonumber) |
    (select(.kind == "ConfigMap" and .metadata.name == "longhorn-default-setting" and ((.data["default-setting.yaml"] | contains("guaranteed-instance-manager-cpu")) | not)) | .data["default-setting.yaml"]) += "\nguaranteed-instance-manager-cpu: 0"
' "$LONGHORN_MANIFEST"
# Fail early if a patch did not take effect (e.g. the upstream manifest layout changed).
if [ "$(yq 'select(.kind == "Service" and .metadata.name == "longhorn-frontend") | .spec.externalIPs[0]' "$LONGHORN_MANIFEST")" != "$VIP" ] \
    || [ "$(yq 'select(.kind == "Service" and .metadata.name == "longhorn-frontend") | .spec.ports[] | select(.name == "http") | .port' "$LONGHORN_MANIFEST")" != "$LONGHORN_PORT" ] \
    || ! yq 'select(.kind == "ConfigMap" and .metadata.name == "longhorn-default-setting") | .data["default-setting.yaml"]' "$LONGHORN_MANIFEST" | grep -q '^guaranteed-instance-manager-cpu: 0$'; then
    error "Patching ${LONGHORN_MANIFEST} failed: longhorn-frontend service or longhorn-default-setting configmap not as expected."
    exit 1
fi

info "Applying ${LONGHORN_MANIFEST}..."
kubectl apply -f "$LONGHORN_MANIFEST"
success "Longhorn ${LONGHORN_VERSION} applied (UI at http://${VIP}:${LONGHORN_PORT}); its pods keep starting in the background."

# ------------------------------------------------------------------------------
# Step 28: Check all nodes are in Ready status
# ------------------------------------------------------------------------------
step_header "28" "Verify all cluster nodes are Ready"
info "Waiting for all nodes to report condition Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes -o wide

# ------------------------------------------------------------------------------
# Step 29: Apply dnsutils test pod
# ------------------------------------------------------------------------------
step_header "29" "Apply dnsutils test pod"
kubectl apply -f "${SCRIPT_DIR}/dnsutils.yaml"
info "Waiting for dnsutils pod to be created/ready..."
kubectl wait --for=condition=Ready pod/dnsutils --timeout=120s || true
kubectl get pods -A

# ------------------------------------------------------------------------------
# Step 30: Install chartmuseum.service (local Helm chart repository, HELM_REPO_SERVER_PORT / CHARTS_DIR from inventory.txt)
# ------------------------------------------------------------------------------
step_header "30" "Install chartmuseum.service (port ${HELM_REPO_SERVER_PORT}, charts in ${CHARTS_DIR})"
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
# Step 31: Set up the local Helm repo (served by chartmuseum, step 30)
# ------------------------------------------------------------------------------
step_header "31" "Set up the local Helm repo (http://${HOST_IP}:${HELM_REPO_SERVER_PORT})"
helm repo remove local || true
helm repo add local "http://${HOST_IP}:${HELM_REPO_SERVER_PORT}"
helm repo update
helm repo list

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${GREEN}==> Kubernetes HA Cluster on ${ENGINE_NAME} completed successfully!${NC}"
echo -e "${GREEN}======================================================================${NC}"
