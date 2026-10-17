#!/bin/bash
set -euo pipefail

# source $HOME/proxy.sh
echo "Fetching latest Cilium CLI version..."
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi

echo "Downloading Cilium CLI ${CILIUM_CLI_VERSION} (${CLI_ARCH})..."
curl -L --fail --progress-bar --remote-name-all "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz"{,.sha256sum}

echo "Verifying SHA256 checksum..."
sha256sum --check "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"

echo "Extracting cilium binary to /usr/local/bin..."
sudo tar xzvfC "cilium-linux-${CLI_ARCH}.tar.gz" /usr/local/bin
rm "cilium-linux-${CLI_ARCH}.tar.gz"{,.sha256sum}
echo "Cilium CLI ${CILIUM_CLI_VERSION} installed successfully."
