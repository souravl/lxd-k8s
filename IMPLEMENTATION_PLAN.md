# Automated HA Kubernetes Deployment on LXD from Scratch

Implement an end-to-end, idempotent master bash script (`deploy_k8s.sh`) to automate the 27-step deployment of a high-availability, multi-control-plane Kubernetes cluster with `kube-vip` virtual IP and `cilium` CNI on Ubuntu 24.04 LXD containers, along with hardening companion scripts.

## User Review Required

> [!NOTE]
> All architectural decisions have been discussed and aligned:
> - **LXD via Snap & LXC via APT**: Step 1 installs `lxd` via `snap` and Step 2 configures/activates `lxd` group membership with `sg lxd` so subsequent steps run in the group without logout. Step 3 installs `lxc` via `apt` (with a `dpkg -s` guard to avoid redundant installs), followed by Steps 4–6 configuring UFW, kernel modules, and sysctl.
> - **Single Source of Truth for Node IPs**: `HOSTS_ENTRIES` is defined at the top of `deploy_k8s.sh` and passed directly as arguments to `setup_ssh_lxd_nodes.sh`.
> - **Control Plane Taint Removal**: Added Step 21 (`kubectl taint nodes --all node-role.kubernetes.io/control-plane-`) before Cilium deployment so pods can schedule across all control-plane nodes.
> - **Non-Interactive Execution**: Added `-y` to `apt` commands in `containerd_install.sh` and `helm_install.sh`, and passed `DEBIAN_FRONTEND=noninteractive` directly to `sudo` in `lxd_docker_iptables.sh`.
> - **Robust Networking & Directories**: `setup_ssh_lxd_nodes.sh` waits unconditionally for DNS resolution, and `kube-vip.sh` ensures `/etc/kubernetes/manifests` exists prior to writing manifests.

## Proposed Changes

### Core Deployment Script

#### [NEW] [deploy_k8s.sh](deploy_k8s.sh)
- Master orchestration script implementing all 27 steps sequentially with colorized logging, error handling (`set -euo pipefail`), and verification checks.
- Manages host prerequisites (UFW, kernel modules, sysctl).
- Installs LXC (`apt`) and LXD (`snap`), handles `lxd` group activation without requiring user logout.
- Preseeds LXD with `lxd-init-config`, runs Docker-LXD firewall script, and configures `k8s` profile.
- Launches and boots `node1`, `node2`, and `node3` with static IPs.
- Invokes `setup_ssh_lxd_nodes.sh` with `HOSTS_ENTRIES`.
- Deploys containerd runtime, extracts pause image version dynamically, updates `config.toml`, and configures kubeadm on all nodes.
- Orchestrates `kube-vip` bootstrap on `node1`, runs `kubeadm init --upload-certs`, and captures join credentials.
- Configures host `$HOME/.kube/config`, updates join configs for `node2` and `node3`, joins them to the control plane, and distributes `kube-vip.yaml`.
- Installs host utilities (`cilium-cli`, `helm`, `kubectl`), untaints nodes, templates and applies Cilium CNI, polls `cilium status --wait`, and verifies `dnsutils` test pod.

---

### Companion Scripts & Configurations

#### [MODIFY] [steps.txt](steps.txt)
- Added step 21: `kubectl taint nodes --all node-role.kubernetes.io/control-plane-` before Cilium installation and renumbered following steps.

#### [MODIFY] [setup_ssh_lxd_nodes.sh](setup_ssh_lxd_nodes.sh)
- Configured script to accept `HOSTS_ENTRIES` via command-line arguments (passed by `deploy_k8s.sh`), while maintaining fallback defaults for standalone execution.
- Automatically derives `NODES` array from `HOSTS_ENTRIES`.
- Decoupled container start check from DNS/network readiness polling so it always verifies resolution before running `apt-get update`.

#### [MODIFY] [lxd_docker_iptables.sh](lxd_docker_iptables.sh)
- Passed `DEBIAN_FRONTEND=noninteractive` directly to `sudo` when installing `iptables-persistent` to prevent interactive ncurses prompts.

#### [MODIFY] [kube-vip.sh](kube-vip.sh)
- Added `sudo mkdir -p /etc/kubernetes/manifests` before writing `kube-vip.yaml` to ensure manifest directory exists on clean nodes.

#### [MODIFY] [containerd_install.sh](containerd_install.sh)
- Added `-y` to `apt install` commands for non-interactive installation.

#### [MODIFY] [helm_install.sh](helm_install.sh)
- Added `-y` to `sudo apt-get install helm` for non-interactive execution.

---

## Verification Plan

### Automated / Syntax Verification
- [x] Syntax check with `bash -n deploy_k8s.sh`.
- [x] Syntax check with `bash -n setup_ssh_lxd_nodes.sh`.
- [x] Verified file permissions (`chmod +x deploy_k8s.sh`).

### Manual & Structural Verification
- [x] Validated step-by-step parity between `steps.txt` and `deploy_k8s.sh`.
- [x] Verified parameter passing from `deploy_k8s.sh` to `setup_ssh_lxd_nodes.sh`.
- [x] Checked container status, network interface assignment, and DNS resolution behaviors on existing running nodes (`kmaster`, `kworker1`, `kworker2`).
