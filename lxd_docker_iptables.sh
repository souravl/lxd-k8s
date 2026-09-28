#!/bin/bash

# Check if Docker is actively running on the host system
if systemctl is-active --quiet docker; then
    echo "Docker detected. Configuring idempotent iptables rules for LXD..."

    # Define the LXD bridge and subnet
    LXD_BRIDGE="lxdbr0"
    LXD_SUBNET="10.67.38.0/24"

    # i. Allow LXD outbound traffic through Docker's chain
    if ! sudo iptables -C DOCKER-USER -i "$LXD_BRIDGE" -j ACCEPT 2>/dev/null; then
        sudo iptables -I DOCKER-USER -i "$LXD_BRIDGE" -j ACCEPT
    fi

    # ii. Allow return internet traffic back into LXD
    if ! sudo iptables -C DOCKER-USER -o "$LXD_BRIDGE" -j ACCEPT 2>/dev/null; then
        sudo iptables -I DOCKER-USER -o "$LXD_BRIDGE" -j ACCEPT
    fi

    # iii. Enable internet NAT translation for the LXD container subnet
    if ! sudo iptables -t nat -C POSTROUTING -s "$LXD_SUBNET" ! -d "$LXD_SUBNET" -j MASQUERADE 2>/dev/null; then
        sudo iptables -t nat -A POSTROUTING -s "$LXD_SUBNET" ! -d "$LXD_SUBNET" -j MASQUERADE
    fi

    # iv. Save the rules persistently without prompting the user
    echo "Saving firewall rules..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
    sudo netfilter-persistent save
else
    echo "Docker is not active. Skipping firewall adjustments."
fi

