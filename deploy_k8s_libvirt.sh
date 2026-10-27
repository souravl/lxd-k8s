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
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

VIP="${VIP:-10.67.38.250}"
BRIDGE_IPV4="${BRIDGE_IPV4:-10.67.38.1}"
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

# Static IP to node mappings
HOSTS_ENTRIES=()
for ((i=1; i<=TOTAL_NODES; i++)); do
    var="NODE${i}_IP"
    HOSTS_ENTRIES+=("${!var} node${i}")
done

NODES=()
declare -A NODE_IPS
declare -A NODE_MACS
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
    step_header "1" "Install QEMU/KVM, libvirt, and virtinst on host"
    MISSING_PKGS=()
    for pkg in qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst libguestfs-tools; do
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
until ssh "${SSH_OPTS[@]}" -o ConnectTimeout=2 "${SSH_USER}@${NODE1_IP}" "true" 2>/dev/null; do
    sleep 2
done
success "node1 is running and accessible via SSH."

# ------------------------------------------------------------------------------
# Step 10: Configure /etc/hosts on host and inside node1
# ------------------------------------------------------------------------------
step_header "10" "Configure /etc/hosts on host and inside node1"
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
# Step 11: Configure Golden Node (node1) with runtime & k8s packages
# ------------------------------------------------------------------------------
step_header "11" "Prepare Golden Node (node1) with OS updates, containerd, and Kubernetes packages"
NODE="node1"
info "--- Configuring runtime and Kubernetes binaries on $NODE ---"

ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "KUBERNETES_VERSION='${KUBERNETES_VERSION}' bash -s" <<'EOF'
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

    echo "==> 5. Installing containerd.io and qemu-guest-agent..."
    sudo apt-get install -y -qq ca-certificates curl gpg apt-transport-https jq qemu-guest-agent
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

    echo "==> 6. Configuring containerd (SystemdCgroup = true, disabled_plugins = [])..."
    sudo rm -rf /etc/containerd/config.toml
    sudo mkdir -p /etc/containerd
    containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    sudo sed -i 's/disabled_plugins = .*/disabled_plugins = []/g' /etc/containerd/config.toml
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

    echo "==> 9. Generalizing netplan configuration for cloned nodes..."
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
EOF
success "Golden Node (node1) configured with runtime, packages, and pre-cached images."

# ------------------------------------------------------------------------------
# Step 12: Clone remaining nodes from node1 (Golden Image)
# ------------------------------------------------------------------------------
if [ "${#CLONE_NODES[@]}" -gt 0 ]; then
    step_header "12" "Clone remaining nodes (${CLONE_NODES[*]}) from node1"

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
        until ssh "${SSH_OPTS[@]}" -o ConnectTimeout=2 "${SSH_USER}@${IP}" "true" 2>/dev/null; do
            sleep 1
        done

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
        until ssh "${SSH_OPTS[@]}" -o ConnectTimeout=2 "${SSH_USER}@${NODE}" "hostname" 2>/dev/null | grep -q "$NODE"; do
            sleep 1
        done
        success "Node $NODE is running, personalized, and reachable via SSH."
        ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$NODE" >/dev/null 2>&1 || true
        ssh-keygen -f "$HOME/.ssh/known_hosts" -R "${NODE_IPS[$NODE]}" >/dev/null 2>&1 || true
        ssh-keyscan -H "$NODE" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
        ssh-keyscan -H "${NODE_IPS[$NODE]}" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
    done
else
    step_header "12" "Single-node deployment (skipping cloning)"
    info "Only node1 is defined; skipping clone step."
fi
success "All nodes (${NODES[*]}) are cloned, started, and reachable via SSH."

# ------------------------------------------------------------------------------
# Step 13: Bootstrap node1 with kube-vip and kubeadm init
# ------------------------------------------------------------------------------
step_header "13" "Bootstrap control plane on node1"

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

# Copy parameterized kubeadm-init-config.yaml to node1
info "Copying parameterized kubeadm-init-config.yaml to node1..."
INIT_CONFIG=$(< "${SCRIPT_DIR}/kubeadm-init-config.yaml")
INIT_CONFIG="${INIT_CONFIG//\$\{NODE1_IP\}/$NODE1_IP}"
INIT_CONFIG="${INIT_CONFIG//\$\{VIP\}/$VIP}"
INIT_CONFIG="${INIT_CONFIG//\$\{CERT_SANS\}/$CERT_SANS_BLOCK}"
echo "$INIT_CONFIG" | ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "cat > ~/kubeadm-init-config.yaml"

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
# Step 25: Check all nodes are in Ready status
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
