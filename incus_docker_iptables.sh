#!/bin/bash

# Check if Docker is actively running on the host system
if systemctl is-active --quiet docker; then
    echo "Docker detected. Configuring idempotent iptables rules for Incus..."

    # Define the Incus bridge and subnet
    INCUS_BRIDGE="incusbr0"
    INCUS_SUBNET="10.67.38.0/24"

    # i. Allow Incus outbound traffic through Docker's chain
    if ! sudo iptables -C DOCKER-USER -i "$INCUS_BRIDGE" -j ACCEPT 2>/dev/null; then
        sudo iptables -I DOCKER-USER -i "$INCUS_BRIDGE" -j ACCEPT
    fi

    # ii. Allow return internet traffic back into Incus
    if ! sudo iptables -C DOCKER-USER -o "$INCUS_BRIDGE" -j ACCEPT 2>/dev/null; then
        sudo iptables -I DOCKER-USER -o "$INCUS_BRIDGE" -j ACCEPT
    fi

    # iii. Enable internet NAT translation for the Incus container subnet
    if ! sudo iptables -t nat -C POSTROUTING -s "$INCUS_SUBNET" ! -d "$INCUS_SUBNET" -j MASQUERADE 2>/dev/null; then
        sudo iptables -t nat -A POSTROUTING -s "$INCUS_SUBNET" ! -d "$INCUS_SUBNET" -j MASQUERADE
    fi

    # iv. Save the rules persistently without prompting the user
    echo "Saving firewall rules..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
    sudo netfilter-persistent save
else
    echo "Docker is not active. Skipping firewall adjustments."
fi
