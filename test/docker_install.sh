#!/bin/bash
set -euo pipefail

# Make APT and daemon restarts completely non-interactive
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Add Docker's official GPG key:
sudo -E apt-get update
sudo -E apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo -E apt-get update
sudo -E apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Create docker group if it doesn't already exist and add user
sudo groupadd -f docker
sudo usermod -aG docker "${USER:-ubuntu}"
