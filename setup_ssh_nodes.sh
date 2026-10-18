#!/usr/bin/env bash
set -euo pipefail

# Determine container CLI command: use $CONTAINER_CMD if set, default to incus (fallback to lxc only if lxc is present and incus is not)
if [ -n "${CONTAINER_CMD:-}" ]; then
    CLI="$CONTAINER_CMD"
elif command -v lxc >/dev/null 2>&1 && ! command -v incus >/dev/null 2>&1; then
    CLI="lxc"
else
    CLI="incus"
fi

# Accept HOSTS_ENTRIES from command-line arguments, or fallback to default
if [ "$#" -gt 0 ]; then
    HOSTS_ENTRIES=("$@")
elif [ -n "${HOSTS_ENTRIES_ENV:-}" ]; then
    readarray -t HOSTS_ENTRIES <<< "$HOSTS_ENTRIES_ENV"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "${SCRIPT_DIR}/inventory.txt" ]; then
        # shellcheck source=/dev/null
        source "${SCRIPT_DIR}/inventory.txt"
    fi
    NUM_CP="${NUM_CP:-3}"
    NUM_WORKER="${NUM_WORKER:-0}"
    TOTAL_NODES=$((NUM_CP + NUM_WORKER))
    NODE_IPS_COUNT=0
    for var in ${!NODE*}; do
        if [[ "$var" =~ ^NODE[0-9]+_IP$ ]] && [ -n "${!var:-}" ]; then
            NODE_IPS_COUNT=$((NODE_IPS_COUNT + 1))
        fi
    done
    if [ "$NODE_IPS_COUNT" -lt "$TOTAL_NODES" ]; then
        echo "[ERROR] Insufficient node static IP addresses in inventory.txt! Expected at least ${TOTAL_NODES} NODEn_IP variable(s) (${NUM_CP} control plane + ${NUM_WORKER} worker), but found ${NODE_IPS_COUNT}." >&2
        exit 1
    fi
    MISSING_CP_NODES=()
    for ((i=1; i<=NUM_CP; i++)); do
        var="NODE${i}_IP"
        if [ -z "${!var:-}" ]; then
            MISSING_CP_NODES+=("$var")
        fi
    done
    if [ "${#MISSING_CP_NODES[@]}" -gt 0 ]; then
        echo "[ERROR] Missing control plane node static IP addresses in inventory.txt! The following required variable(s) are not set: ${MISSING_CP_NODES[*]}." >&2
        exit 1
    fi
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
            echo "[ERROR] Missing worker node static IP addresses in inventory.txt! Expected ${NUM_WORKER} sequential worker node(s) (NODE${START_WORKER}_IP to NODE${END_WORKER}_IP). The following required variable(s) are not set: ${MISSING_WORKER_NODES[*]}." >&2
            exit 1
        fi
    fi
    HOSTS_ENTRIES=()
    for ((i=1; i<=TOTAL_NODES; i++)); do
        var="NODE${i}_IP"
        HOSTS_ENTRIES+=("${!var} node${i}")
    done
fi

# Derive NODES list from TARGET_NODES if specified, else from existing containers in HOSTS_ENTRIES
if [ -n "${TARGET_NODES:-}" ]; then
    read -ra NODES <<< "$TARGET_NODES"
else
    NODES=()
    for ENTRY in "${HOSTS_ENTRIES[@]}"; do
        NODE_NAME=$(echo "$ENTRY" | awk '{print $2}')
        if "$CLI" info "$NODE_NAME" >/dev/null 2>&1; then
            NODES+=("$NODE_NAME")
        fi
    done
    if [ "${#NODES[@]}" -eq 0 ]; then
        for ENTRY in "${HOSTS_ENTRIES[@]}"; do
            NODE_NAME=$(echo "$ENTRY" | awk '{print $2}')
            NODES+=("$NODE_NAME")
        done
    fi
fi

# 1. Locate Host SSH Public Key
SSH_PUB_KEY=""
if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    SSH_PUB_KEY="$HOME/.ssh/id_ed25519.pub"
elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    SSH_PUB_KEY="$HOME/.ssh/id_rsa.pub"
else
    echo "No SSH public key found in ~/.ssh/ (id_ed25519.pub or id_rsa.pub)."
    echo "Running 'ssh-keygen -t ed25519'"
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
    SSH_PUB_KEY="$HOME/.ssh/id_ed25519.pub"
fi

echo "Using SSH public key: $SSH_PUB_KEY"
echo "----------------------------------------"

# Clean stale host keys from ~/.ssh/known_hosts for cluster nodes from previous runs
if [ -f "$HOME/.ssh/known_hosts" ]; then
    for ENTRY in "${HOSTS_ENTRIES[@]}"; do
        _IP=$(echo "$ENTRY" | awk '{print $1}')
        _NODE=$(echo "$ENTRY" | awk '{print $2}')
        ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$_NODE" >/dev/null 2>&1 || true
        ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$_IP" >/dev/null 2>&1 || true
    done
fi

# Check if passwordless SSH key authentication is already operational on all nodes
ALL_SSH_OK=true
for NODE in "${NODES[@]}"; do
    if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=2 "${USER}@${NODE}" "true" 2>/dev/null; then
        ALL_SSH_OK=false
        break
    fi
done

if [ "$ALL_SSH_OK" = true ]; then
    echo "[✓] Passwordless SSH access is already operational on all nodes: ${NODES[*]}"
    echo "Skipping container user creation and password prompt."
    exit 0
fi

# 2. Obtain ${USER}'s password for container creation
if [ -n "${CONTAINER_PASS:-}" ]; then
    USER_PASS="$CONTAINER_PASS"
else
    read -rsp "Enter password for user '${USER}' inside containers: " USER_PASS
    echo
    read -rsp "Confirm password: " USER_PASS_CONFIRM
    echo

    if [ "$USER_PASS" != "$USER_PASS_CONFIRM" ]; then
        echo "Error: Passwords do not match!"
        exit 1
    fi
fi
echo "----------------------------------------"

# 3. Process each container
for NODE in "${NODES[@]}"; do
    echo "[+] Configuring node: $NODE"

    # Check container existence
    if ! "$CLI" info "$NODE" >/dev/null 2>&1; then
        echo "  [!] Warning: Container '$NODE' does not exist. Skipping..."
        echo "----------------------------------------"
        continue
    fi

    # Ensure container is running
    STATE=$("$CLI" info "$NODE" | awk '/^Status:/ {print $2}')
    if [ "$STATE" != "RUNNING" ]; then
        echo "  -> Starting container $NODE..."
        "$CLI" start "$NODE"
    fi

    # Wait up to 30 seconds for DNS & network readiness
    MAX_WAIT=30
    COUNT=0
    echo "  -> Waiting for DNS & network readiness (timeout: ${MAX_WAIT}s)..."
    until "$CLI" exec "$NODE" -- getent hosts archive.ubuntu.com >/dev/null 2>&1; do
        COUNT=$((COUNT + 1))
        if [ "$COUNT" -ge "$MAX_WAIT" ]; then
            echo "  [!] Error: DNS/Network timeout on container '$NODE' after ${MAX_WAIT}s. Aborting." >&2
            exit 1
        fi
        sleep 1
    done

    # Create user '${USER}' if it doesn't exist
    if ! "$CLI" exec "$NODE" -- id -u "${USER}" >/dev/null 2>&1; then
        echo "  -> Creating user '${USER}'..."
        "$CLI" exec "$NODE" -- useradd -m -s /bin/bash "${USER}"
        "$CLI" exec "$NODE" -- usermod -aG sudo "${USER}"
    else
        echo "  -> User '${USER}' already exists."
    fi

    # Set password for '${USER}'
    echo "  -> Setting password..."
    echo "${USER}:$USER_PASS" | "$CLI" exec "$NODE" -- chpasswd

    # Configure passwordless sudo for '${USER}'
    echo "  -> Configuring passwordless sudo..."
    "$CLI" exec "$NODE" -- bash -c "mkdir -p /etc/sudoers.d && echo '${USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-${USER}"
    "$CLI" exec "$NODE" -- chmod 440 "/etc/sudoers.d/90-${USER}"

    # Set up SSH directory and authorized_keys
    echo "  -> Injecting SSH public key..."
    "$CLI" exec "$NODE" -- mkdir -p "/home/${USER}/.ssh"
    "$CLI" file push "$SSH_PUB_KEY" "$NODE/home/${USER}/.ssh/authorized_keys"

    # Set strict permissions
    "$CLI" exec "$NODE" -- chown -R "${USER}:${USER}" "/home/${USER}/.ssh"
    "$CLI" exec "$NODE" -- chmod 700 "/home/${USER}/.ssh"
    "$CLI" exec "$NODE" -- chmod 600 "/home/${USER}/.ssh/authorized_keys"

    # Ensure OpenSSH server is installed and running
    "$CLI" exec "$NODE" -- apt-get update -qq
    "$CLI" exec "$NODE" -- apt-get install -y -qq openssh-server
    "$CLI" exec "$NODE" -- systemctl enable --now ssh

    echo "  [✓] $NODE successfully configured!"
    echo "----------------------------------------"
done

echo "Configuration complete!"

# 4. Update /etc/hosts with static IP mappings
echo "----------------------------------------"
echo "[+] Updating /etc/hosts..."

# Update host's /etc/hosts (requires sudo)
echo "  -> Updating host /etc/hosts (sudo required)..."
for ENTRY in "${HOSTS_ENTRIES[@]}"; do
    IP=$(echo "$ENTRY" | awk '{print $1}')
    NODE=$(echo "$ENTRY" | awk '{print $2}')
    sudo sed -i -E "/[[:space:]]${NODE}([[:space:]]|$)/d" /etc/hosts
    echo -e "${IP}\t${NODE}" | sudo tee -a /etc/hosts >/dev/null
done

# Update /etc/hosts inside all containers for inter-node communication
echo "  -> Updating /etc/hosts inside containers..."
for TARGET_NODE in "${NODES[@]}"; do
    if "$CLI" info "$TARGET_NODE" >/dev/null 2>&1; then
        for ENTRY in "${HOSTS_ENTRIES[@]}"; do
            IP=$(echo "$ENTRY" | awk '{print $1}')
            NODE=$(echo "$ENTRY" | awk '{print $2}')
            "$CLI" exec "$TARGET_NODE" -- bash -c "sed -i -E '/[[:space:]]${NODE}([[:space:]]|$)/d' /etc/hosts && echo -e '${IP}\t${NODE}' >> /etc/hosts"
        done
    fi
done

echo "----------------------------------------"
echo "Setup complete! You can now test SSH by node name:"
for NODE in "${NODES[@]}"; do
    echo "  ssh ${USER}@${NODE}"
done
