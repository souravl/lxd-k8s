#!/usr/bin/env bash
# ==============================================================================
# deploy_k8s_incus.sh - High-Availability Kubernetes Cluster on Incus
# Implements all steps from steps_incus.txt
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

# Source software versions if configured
if [ -f "${SCRIPT_DIR}/software_install_version.txt" ]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/software_install_version.txt"
fi
export KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.37}"
export CILIUM_VERSION="${CILIUM_VERSION:-1.20.2}"

SSH_USER="${USER}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)

# Static IP to node mappings (passed to setup_ssh_incus_nodes.sh)
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

# Clean stale host keys from ~/.ssh/known_hosts for cluster nodes from previous runs
if [ -f "$HOME/.ssh/known_hosts" ]; then
    for ENTRY in "${HOSTS_ENTRIES[@]}"; do
        _IP=$(echo "$ENTRY" | awk '{print $1}')
        _NODE=$(echo "$ENTRY" | awk '{print $2}')
        ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$_NODE" >/dev/null 2>&1 || true
        ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$_IP" >/dev/null 2>&1 || true
    done
fi

# ------------------------------------------------------------------------------
# Step 1: Install Incus via APT
# ------------------------------------------------------------------------------
step_header "1" "Install Incus via APT"
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

# ------------------------------------------------------------------------------
# Step 2: Make current user member of incus-admin group; ensure incus does not need sudo
# ------------------------------------------------------------------------------
step_header "2" "Configure Incus group membership for $SSH_USER"
if ! id -nG "$SSH_USER" | grep -qw "incus-admin"; then
    info "Adding $SSH_USER to group 'incus-admin'..."
    sudo usermod -aG incus-admin "$SSH_USER"
fi

# If incus-admin is not in current shell's active groups, re-execute the script using sg incus-admin
if ! id -nG | grep -qw "incus-admin"; then
    info "Activating 'incus-admin' group for the current session without requiring logout..."
    exec sg incus-admin -c "$0 \"$@\""
fi
success "User $SSH_USER is in incus-admin group and incus commands can run without sudo."

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
# Step 6: do incus admin init with incus-init-config file
# ------------------------------------------------------------------------------
step_header "6" "Initialize Incus with incus-init-config"
if ! incus network show incusbr0 >/dev/null 2>&1; then
    info "Applying incus-init-config preseed..."
    cat "${SCRIPT_DIR}/incus-init-config" | incus admin init --preseed
else
    info "Incus bridge 'incusbr0' already exists. Skipping preseed."
fi

# ------------------------------------------------------------------------------
# Step 7: run incus_docker_iptables.sh
# ------------------------------------------------------------------------------
step_header "7" "Run incus_docker_iptables.sh"
if [ -f "${SCRIPT_DIR}/incus_docker_iptables.sh" ]; then
    bash "${SCRIPT_DIR}/incus_docker_iptables.sh"
else
    error "File ${SCRIPT_DIR}/incus_docker_iptables.sh not found!"
    exit 1
fi

# ------------------------------------------------------------------------------
# Step 8: create incus profile 'k8s' from k8s-profile-config-incus
# ------------------------------------------------------------------------------
step_header "8" "Create/Update Incus profile 'k8s'"
if ! incus profile list | grep -qw "k8s"; then
    info "Creating incus profile 'k8s'..."
    incus profile create k8s
fi
info "Applying k8s-profile-config-incus to profile 'k8s'..."
incus profile edit k8s < "${SCRIPT_DIR}/k8s-profile-config-incus"


# ------------------------------------------------------------------------------
# Step 9: launch incus container node1
# ------------------------------------------------------------------------------
step_header "9" "Launch and start Incus container: node1"
IP="${NODE_IPS[node1]}"
if ! incus info node1 >/dev/null 2>&1; then
    info "Launching node1 (IP: $IP) with profile 'k8s'..."
    incus launch images:ubuntu/24.04 node1 --profile k8s -d eth0,ipv4.address="$IP"
else
    info "Container node1 already exists."
fi

STATE=$(incus info node1 | awk '/^Status:/ {print $2}')
if [ "$STATE" != "RUNNING" ]; then
    info "Starting node1..."
    incus start node1
fi

# ------------------------------------------------------------------------------
# Step 10: Run setup_ssh_incus_nodes.sh for ssh setup
# ------------------------------------------------------------------------------
step_header "10" "Run setup_ssh_incus_nodes.sh on node1"
TARGET_NODES="node1" bash "${SCRIPT_DIR}/setup_ssh_incus_nodes.sh" "${HOSTS_ENTRIES[@]}"

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
# Step 12: Clone node2 and node3 from node1
# ------------------------------------------------------------------------------
step_header "12" "Clone node2 and node3 from node1"

# i) Stop node1 and wait for it to stop
info "Stopping node1 before cloning..."
if [ "$(incus info node1 | awk '/^Status:/ {print $2}')" = "RUNNING" ]; then
    incus stop node1
fi
until [ "$(incus info node1 | awk '/^Status:/ {print $2}')" = "STOPPED" ]; do
    info "Waiting for node1 to stop..."
    sleep 1
done
success "node1 is stopped."

# ii) Copy node2 and node3 from node1 and configure their static IPs
for TARGET_NODE in node2 node3; do
    IP="${NODE_IPS[$TARGET_NODE]}"
    if ! incus info "$TARGET_NODE" >/dev/null 2>&1; then
        info "Copying $TARGET_NODE from node1..."
        incus copy node1 "$TARGET_NODE"
        info "Setting static IP ($IP) on $TARGET_NODE..."
        incus config device set "$TARGET_NODE" eth0 ipv4.address "$IP"
    else
        info "Container $TARGET_NODE already exists."
    fi
done

# iii) Start node1, node2, and node3
for NODE in "${NODES[@]}"; do
    STATE=$(incus info "$NODE" | awk '/^Status:/ {print $2}')
    if [ "$STATE" != "RUNNING" ]; then
        info "Starting $NODE..."
        incus start "$NODE"
    fi
done

# iv) Wait for all nodes to be RUNNING
for NODE in "${NODES[@]}"; do
    until [ "$(incus info "$NODE" | awk '/^Status:/ {print $2}')" = "RUNNING" ]; do
        info "Waiting for $NODE to reach RUNNING status..."
        sleep 1
    done
done

# v) Set hostnames, regenerate machine-ids, and verify SSH
for TARGET_NODE in node2 node3; do
    info "Setting hostname and regenerating machine-id on $TARGET_NODE..."
    incus exec "$TARGET_NODE" -- bash -c "echo '$TARGET_NODE' > /etc/hostname && hostname '$TARGET_NODE'"
    incus exec "$TARGET_NODE" -- bash -c "rm -f /etc/machine-id /var/lib/dbus/machine-id && systemd-machine-id-setup" >/dev/null 2>&1
done

# Verify SSH connectivity to all nodes
for NODE in "${NODES[@]}"; do
    info "Verifying SSH connectivity to $NODE..."
    until ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "true" 2>/dev/null; do
        sleep 2
    done
    success "SSH to $NODE is operational."
done
success "All nodes (node1, node2, node3) are cloned, started, and reachable via SSH."

# ------------------------------------------------------------------------------
# Step 13: Bootstrap node1 with kube-vip and kubeadm init
# ------------------------------------------------------------------------------
step_header "13" "Bootstrap control plane on node1"

# i) scp kube-vip.sh and kubeadm-init-config.yaml
info "Copying kube-vip.sh and kubeadm-init-config.yaml to node1..."
scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/kube-vip.sh" "${SCRIPT_DIR}/kubeadm-init-config.yaml" "${SSH_USER}@node1:~/"

# ii), iii), iv) Bootstrap node1 if not already initialized
if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "[ -f /etc/kubernetes/admin.conf ]"; then
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
else
    info "Node1 control plane is already initialized. Skipping kubeadm init."
    KUBEADM_INIT_OUTPUT=""
fi

# v) Note the token, discovery-token-ca-cert-hash and certificate-key
info "Extracting join credentials from kubeadm init output..."
JOIN_TOKEN=$(echo "$KUBEADM_INIT_OUTPUT" | grep -oP -- '--token\s+\K\S+' | head -n 1 || true)
JOIN_CA_HASH=$(echo "$KUBEADM_INIT_OUTPUT" | grep -oP -- '--discovery-token-ca-cert-hash\s+\K\S+' | head -n 1 || true)
JOIN_CERT_KEY=$(echo "$KUBEADM_INIT_OUTPUT" | grep -oP -- '--certificate-key\s+\K\S+' | head -n 1 || true)

# Fallbacks if output parsing missed any field
if [ -z "$JOIN_TOKEN" ]; then
    info "Retrieving valid authentication token directly from node1..."
    JOIN_TOKEN=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@node1" "sudo kubeadm token list | awk '\$4 ~ /authentication/ {print \$1; exit}'")
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
update_join_config() {
    local target_file="$1"
    local tmp_file
    tmp_file=$(mktemp)
    sed -e "s|token: \".*\"|token: \"${JOIN_TOKEN}\"|g" \
        -e "s|caCertHashes: \[\".*\"\]|caCertHashes: [\"${JOIN_CA_HASH}\"]|g" \
        -e "s|certificateKey: \".*\"|certificateKey: \"${JOIN_CERT_KEY}\"|g" "$target_file" > "$tmp_file"
    cat "$tmp_file" > "$target_file"
    rm -f "$tmp_file"
}

update_join_config "${SCRIPT_DIR}/kubeadm-join-cp2-config.yaml"
update_join_config "${SCRIPT_DIR}/kubeadm-join-cp3-config.yaml"
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
# Step 21: Download Cilium helm chart
# ------------------------------------------------------------------------------
step_header "21" "Download Cilium ${CILIUM_VERSION} Helm chart"
if [ ! -f "${SCRIPT_DIR}/cilium-${CILIUM_VERSION}.tgz" ]; then
    info "Fetching cilium-${CILIUM_VERSION}.tgz..."
    helm pull oci://quay.io/cilium/charts/cilium --version ${CILIUM_VERSION}
else
    info "cilium-${CILIUM_VERSION}.tgz already exists."
fi

# ------------------------------------------------------------------------------
# Step 22: Generate cilium.yaml using helm template
# ------------------------------------------------------------------------------
step_header "22" "Template Cilium Helm chart into cilium.yaml"
helm template cilium "./cilium-${CILIUM_VERSION}.tgz" --namespace kube-system -f ./cilium-deploy.yaml > cilium.yaml
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
echo -e "${GREEN}==> Kubernetes HA Cluster on Incus completed successfully!${NC}"
echo -e "${GREEN}======================================================================${NC}"
