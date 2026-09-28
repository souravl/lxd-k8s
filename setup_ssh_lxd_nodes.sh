#!/usr/bin/env bash
set -euo pipefail

# NODES=("kmaster" "kworker1" "kworker2")
NODES=("node1" "node2" "node3")

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

# 2. Prompt for ${USER}'s password
read -rsp "Enter password for user '${USER}' inside containers: " USER_PASS
echo
read -rsp "Confirm password: " USER_PASS_CONFIRM
echo

if [ "$USER_PASS" != "$USER_PASS_CONFIRM" ]; then
    echo "Error: Passwords do not match!"
    exit 1
fi

echo "----------------------------------------"

# 3. Process each LXD container
for NODE in "${NODES[@]}"; do
    echo "[+] Configuring node: $NODE"

    # Check container existence
    if ! lxc info "$NODE" >/dev/null 2>&1; then
        echo "  [!] Warning: Container '$NODE' does not exist. Skipping..."
        echo "----------------------------------------"
        continue
    fi

    # Ensure container is running
    STATE=$(lxc info "$NODE" | awk '/^Status:/ {print $2}')
    if [ "$STATE" != "RUNNING" ]; then
        echo "  -> Starting container $NODE..."
        lxc start "$NODE"

        # Wait up to 30 seconds for DNS & network readiness
        MAX_WAIT=30
        COUNT=0
        echo "  -> Waiting for DNS & network readiness (timeout: ${MAX_WAIT}s)..."
        until lxc exec "$NODE" -- getent hosts archive.ubuntu.com >/dev/null 2>&1; do
            COUNT=$((COUNT + 1))
            if [ "$COUNT" -ge "$MAX_WAIT" ]; then
                echo "  [!] Error: DNS/Network timeout on container '$NODE' after ${MAX_WAIT}s. Aborting." >&2
                exit 1
            fi
            sleep 1
        done
    fi

    # Create user '${USER}' if it doesn't exist
    if ! lxc exec "$NODE" -- id -u "${USER}" >/dev/null 2>&1; then
        echo "  -> Creating user '${USER}'..."
        lxc exec "$NODE" -- useradd -m -s /bin/bash "${USER}"
        lxc exec "$NODE" -- usermod -aG sudo "${USER}"
    else
        echo "  -> User '${USER}' already exists."
    fi

    # Set password for '${USER}'
    echo "  -> Setting password..."
    echo "${USER}:$USER_PASS" | lxc exec "$NODE" -- chpasswd

    # Configure passwordless sudo for '${USER}'
    echo "  -> Configuring passwordless sudo..."
    lxc exec "$NODE" -- bash -c "mkdir -p /etc/sudoers.d && echo '${USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-${USER}"
    lxc exec "$NODE" -- chmod 440 "/etc/sudoers.d/90-${USER}"

    # Set up SSH directory and authorized_keys
    echo "  -> Injecting SSH public key..."
    lxc exec "$NODE" -- mkdir -p "/home/${USER}/.ssh"
    lxc file push "$SSH_PUB_KEY" "$NODE/home/${USER}/.ssh/authorized_keys"

    # Set strict permissions
    lxc exec "$NODE" -- chown -R "${USER}:${USER}" "/home/${USER}/.ssh"
    lxc exec "$NODE" -- chmod 700 "/home/${USER}/.ssh"
    lxc exec "$NODE" -- chmod 600 "/home/${USER}/.ssh/authorized_keys"

    # Ensure OpenSSH server is installed and running
    lxc exec "$NODE" -- apt-get update -qq
    lxc exec "$NODE" -- apt-get install -y -qq openssh-server
    lxc exec "$NODE" -- systemctl enable --now ssh

    echo "  [✓] $NODE successfully configured!"
    echo "----------------------------------------"
done

echo "Configuration complete!"

# 4. Update /etc/hosts with static IP mappings
echo "----------------------------------------"
echo "[+] Updating /etc/hosts..."

HOSTS_ENTRIES=(
    "10.67.38.87 node1"
    "10.67.38.221 node2"
    "10.67.38.211 node3"
)

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
    if lxc info "$TARGET_NODE" >/dev/null 2>&1; then
        for ENTRY in "${HOSTS_ENTRIES[@]}"; do
            IP=$(echo "$ENTRY" | awk '{print $1}')
            NODE=$(echo "$ENTRY" | awk '{print $2}')
            lxc exec "$TARGET_NODE" -- bash -c "sed -i -E '/[[:space:]]${NODE}([[:space:]]|$)/d' /etc/hosts && echo -e '${IP}\t${NODE}' >> /etc/hosts"
        done
    fi
done

echo "----------------------------------------"
echo "Setup complete! You can now test SSH by node name:"
for NODE in "${NODES[@]}"; do
    echo "  ssh ${USER}@${NODE}"
done
