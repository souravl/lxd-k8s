#!/bin/bash
set -euo pipefail

BRIDGE="${1:-incusbr0}"
SUBNET="${2:-10.67.38.0/24}"

# Check if Docker is actively running on the host system
if systemctl is-active --quiet docker; then
    echo "Docker detected. Configuring idempotent iptables rules for bridge '${BRIDGE}'..."

    # i. Allow container outbound traffic through Docker's chain
    if ! sudo iptables -C DOCKER-USER -i "$BRIDGE" -j ACCEPT 2>/dev/null; then
        sudo iptables -I DOCKER-USER -i "$BRIDGE" -j ACCEPT
    fi

    # ii. Allow return internet traffic back into container bridge
    if ! sudo iptables -C DOCKER-USER -o "$BRIDGE" -j ACCEPT 2>/dev/null; then
        sudo iptables -I DOCKER-USER -o "$BRIDGE" -j ACCEPT
    fi

    # iii. Enable internet NAT translation for the container subnet
    if ! sudo iptables -t nat -C POSTROUTING -s "$SUBNET" ! -d "$SUBNET" -j MASQUERADE 2>/dev/null; then
        sudo iptables -t nat -A POSTROUTING -s "$SUBNET" ! -d "$SUBNET" -j MASQUERADE
    fi

    # iv. Save the rules persistently without prompting the user
    echo "Saving firewall rules..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
    sudo netfilter-persistent save
    echo "Firewall rules for '${BRIDGE}' configured and saved."
else
    echo "Docker is not active. Skipping firewall adjustments."
fi
