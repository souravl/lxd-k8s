# lxd-k8s: High-Availability Kubernetes on LXD & Incus

Automated deployment of a High-Availability (3-node multi-master) Kubernetes cluster running inside system containers (**Incus** or **LXD**) with `kube-vip` (virtual IP) and Cilium eBPF CNI.

---

## Acknowledgments & Inspiration

Initial inspiration for this project came from [justmeandopensource/kubernetes (lxd-provisioning)](https://github.com/justmeandopensource/kubernetes/tree/master/lxd-provisioning).

---

## Features

- **Dual Container Engine Support**:
  - **Incus** (recommended): Native APT packages, Apache 2.0 license, community-governed (`deploy_k8s_incus.sh`).
  - **LXD**: Snap-based deployment (`deploy_k8s.sh`).
- **High Availability**: 3 control plane nodes with `kube-vip` virtual IP failover (`10.67.38.40`).
- **Modern Networking & CNI**: Cilium eBPF CNI with Hubble network observability.
- **Configurable Versions**: Centralized version definition in `software_install_version.txt` (Kubernetes, Cilium).
- **Firewall Coexistence**: Idempotent iptables rules allowing Docker and container bridges (`incusbr0` / `lxdbr0`) to coexist seamlessly.
- **Automated Provisioning**: End-to-end scripted workflow covering system container launch, SSH key injection, container runtime (`containerd`), `kubeadm` bootstrap, join automation, and verification.

---

## Quick Start

### 1. Version Configuration
Configure target versions in `software_install_version.txt`:
```bash
KUBERNETES_VERSION=v1.37
CILIUM_VERSION=1.18.13
```

### 2. Deploy with Incus (Recommended)
```bash
CONTAINER_PASS="your_password" ./deploy_k8s_incus.sh
```

### 3. Deploy with LXD
```bash
CONTAINER_PASS="your_password" ./deploy_k8s.sh
```

---

## Repository Structure

| File | Description |
| :--- | :--- |
| `software_install_version.txt` | Centralized Kubernetes and Cilium version definitions |
| `deploy_k8s_incus.sh` | End-to-end deployment script targeting Incus containers |
| `deploy_k8s.sh` | End-to-end deployment script targeting LXD containers |
| `setup_ssh_incus_nodes.sh` | Incus container user, passwordless sudo, and SSH key setup |
| `setup_ssh_lxd_nodes.sh` | LXD container user, passwordless sudo, and SSH key setup |
| `incus_docker_iptables.sh` | Firewall rules for Incus and Docker coexistence |
| `lxd_docker_iptables.sh` | Firewall rules for LXD and Docker coexistence |
| `incus-init-config` | Incus preseed configuration |
| `lxd-init-config` | LXD preseed configuration |
| `k8s-profile-config-incus` | Incus container profile |
| `k8s-profile-config` | LXD container profile |
| `containerd_install.sh` | Container runtime installation script |
| `kubeadm_install.sh` | Kubernetes node components installation script |
| `kubectl_install.sh` | Host `kubectl` installation script |
| `kube-vip.sh` | `kube-vip` static pod manifest generator |
| `steps_incus.txt` | Step-by-step documentation for Incus deployment |
| `steps.txt` | Step-by-step documentation for LXD deployment |
