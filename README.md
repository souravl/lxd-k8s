# lxd-k8s: High-Availability Kubernetes on Incus & LXD

Automated deployment of a High-Availability (3-node multi-master) Kubernetes cluster running inside system containers (**Incus** or **LXD**) with `kube-vip` (virtual IP) and Cilium eBPF CNI.

---

## Acknowledgments & Inspiration

Initial inspiration for this project came from [justmeandopensource/kubernetes (lxd-provisioning)](https://github.com/justmeandopensource/kubernetes/tree/master/lxd-provisioning).

---

## Features

- **Unified Multi-Engine Master Script**:
  - **Incus** (default): Native APT packages, Apache 2.0 license, community-governed.
  - **LXD**: Canonical snap-based deployment via `-c lxd`.
- **High Availability**: 3 control plane nodes with `kube-vip` virtual IP failover (`10.67.38.40`).
- **Modern Networking & CNI**: Cilium eBPF CNI with Hubble network observability.
- **Configurable Inventory**: Centralized configuration in `inventory.txt` (Node static IPs, Ubuntu release, Kubernetes, Cilium).
- **Firewall Coexistence**: Idempotent iptables rules allowing Docker and container bridges (`incusbr0` / `lxdbr0`) to coexist seamlessly.
- **Automated Provisioning**: End-to-end scripted workflow covering system container launch, SSH key injection, container runtime (`containerd`), `kubeadm` bootstrap, join automation, and verification.

---

## Quick Start

### 1. Cluster Inventory Configuration
Configure node static IP addresses, Ubuntu OS version, and software versions in `inventory.txt`:
```bash
# Number of Control Plane & Worker Nodes
NUM_CP=3
NUM_WORKER=2

# Virtual IP (kube-vip control plane endpoint)
VIP="10.67.38.40"

# Bridge Network Gateway IPs
BRIDGE_IPV4="10.67.38.1"
BRIDGE_IPV6="fd42:51e5:ef75:abeb::1"

# Node Static IP Addresses
# Control Plane Nodes (1 .. NUM_CP)
NODE1_IP="10.67.38.10"
NODE2_IP="10.67.38.20"
NODE3_IP="10.67.38.30"

# Worker Nodes ((NUM_CP + 1) .. (NUM_CP + NUM_WORKER))
NODE4_IP="10.67.38.40"
NODE5_IP="10.67.38.50"

# Container Resource Limits
LIMITS_CPU="4"
LIMITS_MEMORY="4GB"

# Container OS & Software Versions
UBUNTU_VERSION="24.04"
KUBERNETES_VERSION="v1.37"
CILIUM_VERSION="1.20.2"
```

### 2. Deploy with Incus (Default)
```bash
CONTAINER_PASS="your_password" ./deploy_k8s.sh
# or explicitly:
CONTAINER_PASS="your_password" ./deploy_k8s.sh -c incus
```

### 3. Deploy with LXD
```bash
CONTAINER_PASS="your_password" ./deploy_k8s.sh -c lxd
```

---

## Repository Structure

| File | Description |
| :--- | :--- |
| `inventory.txt` | Cluster inventory: Node static IPs, Ubuntu OS version, and Kubernetes / Cilium versions |
| `deploy_k8s.sh` | Master deployment script with `-c incus\|lxd` option support |
| `setup_ssh_nodes.sh` | Container user, passwordless sudo, and SSH key setup for Incus and LXD |
| `docker_iptables.sh` | Firewall rules for container bridge and Docker coexistence |
| `container-engine-init-config` | Parameterized container engine preseed configuration |
| `k8s-container-profile-config` | Parameterized container profile for Kubernetes |
| `containerd_install.sh` | Container runtime installation script |
| `kubeadm_install.sh` | Kubernetes node components installation script |
| `kubectl_install.sh` | Host `kubectl` installation script |
| `kube-vip.sh` | `kube-vip` static pod manifest generator |
| `steps.txt` | Unified step-by-step manual guide for Incus and LXD |
