# lxd-k8s: High-Availability Kubernetes on Incus, LXD & libvirt (KVM)

Automated deployment of a High-Availability, multi-control-plane (`NUM_CP >= 3`) and optional dedicated worker (`NUM_WORKER`) Kubernetes cluster running inside system containers (**Incus** or **LXD**) or hardware-accelerated virtual machines (**libvirt / KVM**) with `kube-vip` (virtual IP) and Cilium eBPF CNI.

---

## Acknowledgments & Inspiration

Initial inspiration for this project came from [justmeandopensource/kubernetes (lxd-provisioning)](https://github.com/justmeandopensource/kubernetes/tree/master/lxd-provisioning).

---

## Features

- **Unified Multi-Engine & Hypervisor Architecture**:
  - **Incus** (default container engine): Native APT packages, Apache 2.0 license, system containers via `./deploy_k8s.sh -c incus`.
  - **LXD**: Canonical snap-based container deployment via `./deploy_k8s.sh -c lxd`.
  - **libvirt (KVM Virtual Machines)**: Full hardware virtualization with cloud images, cloud-init, and deterministic DHCP MAC reservations via `./deploy_k8s_libvirt.sh`.
- **High Availability & Scalable Topology**: Configurable multi-control-plane (`NUM_CP >= 3`) and optional dedicated worker (`NUM_WORKER`) topology with `kube-vip` virtual IP failover (`10.67.38.250`).
- **Dynamic SANs & Host Key Isolation**:
  - Automatically generates dynamic `certSANs` in `kubeadm-init-config.yaml` for all control plane nodes.
  - Automatically regenerates unique SSH host keys (`ssh-keygen -A`) on all cloned nodes to prevent host key collisions.
- **Modern Networking & CNI**: Cilium eBPF CNI with Hubble network observability.
- **Configurable Inventory**: Centralized configuration in `inventory.txt` (Node static IPs, resource sizing for CPU/RAM/Disk, Ubuntu release, Kubernetes, Cilium).
- **Firewall Coexistence**: Idempotent iptables rules allowing Docker and container/VM bridges (`incusbr0`, `lxdbr0`, or `virbr0`) to coexist seamlessly.
- **Self-Contained Deployment**: Master deployment scripts (`deploy_k8s.sh` and `deploy_k8s_libvirt.sh`) contain all orchestration, node provisioning, runtime installation, node cloning, host tooling, and firewall configuration inline with zero external script dependencies.

---

## Quick Start

### 1. Cluster Inventory Configuration
Configure node static IP addresses, hardware resource limits, Ubuntu OS version, and software versions in `inventory.txt`:
```bash
# Number of Control Plane & Worker Nodes
NUM_CP=3
NUM_WORKER=2

# Virtual IP (kube-vip control plane endpoint)
VIP="10.67.38.250"

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

# Node Resource Limits
LIMITS_CPU="2"
LIMITS_MEMORY="3GB"
LIMITS_DISK="15GB"

# Container/VM OS & Software Versions
UBUNTU_VERSION="24.04"
KUBERNETES_VERSION="v1.37"
CILIUM_VERSION="1.20.2"
```

### 2. Deploy with Incus (Default Containers)
```bash
CONTAINER_PASS="your_password" ./deploy_k8s.sh
# or explicitly:
CONTAINER_PASS="your_password" ./deploy_k8s.sh -c incus
```

### 3. Deploy with LXD (Containers)
```bash
CONTAINER_PASS="your_password" ./deploy_k8s.sh -c lxd
```

### 4. Deploy with libvirt (KVM Virtual Machines)
```bash
./deploy_k8s_libvirt.sh
```

---

## Repository Structure

| File | Description |
| :--- | :--- |
| `inventory.txt` | Cluster inventory: Node static IPs, resource sizing, OS version, and Kubernetes / Cilium versions |
| `deploy_k8s.sh` | Master deployment script for Incus and LXD system containers (`-c incus\|lxd`) |
| `deploy_k8s_libvirt.sh` | Master deployment script for libvirt (KVM Virtual Machines) |
| `steps.txt` | Unified step-by-step manual guide for Incus and LXD |
| `steps_libvirt.txt` | Step-by-step manual guide for libvirt (KVM Virtual Machines) |
| `container-engine-init-config.yaml` | Parameterized container engine preseed configuration (Incus/LXD) |
| `k8s-container-profile-config.yaml` | Parameterized container profile for Kubernetes (Incus/LXD) |
| `kubeadm-init-config.yaml` | Parameterized kubeadm init configuration with dynamic `certSANs` for bootstrap control plane |
| `kubeadm-join-cp-config.yaml` | Parameterized kubeadm join configuration for secondary control planes |
| `kubeadm-join-worker-config.yaml` | Parameterized kubeadm join configuration for worker nodes |
| `cilium-deploy.yaml` | Helm values configuration for Cilium CNI installation |
| `dnsutils.yaml` | DNS verification testing pod manifest |
| `WALKTHROUGH.md` | Detailed architectural overview and live verification report |
