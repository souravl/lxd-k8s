# Automated HA Kubernetes Deployment on Incus & LXD

Implement an end-to-end, idempotent master bash script (`deploy_k8s.sh`) to automate the 26-step deployment of a high-availability, multi-control-plane Kubernetes cluster with `kube-vip` virtual IP and `cilium` CNI on Incus (default) or LXD containers, along with hardening companion scripts.

## Architectural Highlights

> [!NOTE]
> All architectural decisions have been discussed and aligned:
> - **Unified Multi-Engine Master Script**: Single `deploy_k8s.sh` with `getopts -c incus|lxd` defaulting to Incus.
> - **Centralized Inventory (`inventory.txt`)**: Stores `NODE1_IP`, `NODE2_IP`, `NODE3_IP`, `UBUNTU_VERSION`, `KUBERNETES_VERSION`, and `CILIUM_VERSION`.
> - **Node Cloning Architecture**: Provisions `node1` with containerd, kubeadm, and pause image pre-pulling, then stops `node1` and clones `node2` and `node3` via `incus copy` or `lxc copy`, assigns static IPs, sets hostnames directly, regenerates machine IDs, and verifies SSH across all nodes.
> - **Unified Configurations**: Single `container-engine-init-config` and `k8s-container-profile-config` with parameterized bridge and storage pool directory, removing engine-specific descriptions.
> - **Unified Helpers**: `setup_ssh_nodes.sh` and `docker_iptables.sh`.

## Repository Components

### Core Deployment Script
#### [MODIFY] [deploy_k8s.sh](deploy_k8s.sh)
- Master orchestration script implementing all 26 steps sequentially with colorized logging, error handling (`set -euo pipefail`), and verification checks.
- Supports `-c incus` (default) and `-c lxd`.
- Sourced from `inventory.txt` for IPs, Ubuntu release, and software versions.

### Supporting Scripts & Configurations
#### [NEW] [inventory.txt](inventory.txt)
- Centralized cluster inventory for node IPs, container OS release, and Kubernetes / Cilium versions.

#### [NEW] [setup_ssh_nodes.sh](setup_ssh_nodes.sh)
- Unified SSH key and user configuration script for Incus and LXD nodes.

#### [NEW] [docker_iptables.sh](docker_iptables.sh)
- Unified bridge/Docker firewall coexistence script accepting bridge name as parameter.

#### [MODIFY] [steps.txt](steps.txt)
- Unified step-by-step manual guide presenting Incus and LXD commands side-by-side.

## Verification
- [x] Syntax check with `bash -n deploy_k8s.sh && bash -n setup_ssh_nodes.sh && bash -n docker_iptables.sh`.
- [x] Verified option parsing with `./deploy_k8s.sh -h`.
- [x] Full live end-to-end execution verified in test VM environment (`test-k8s`).
