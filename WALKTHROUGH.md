# Walkthrough: HA Kubernetes Deployment Script on LXD

We have automated the deployment of a High-Availability, multi-master Kubernetes cluster on LXD containers by creating [`deploy_k8s.sh`](deploy_k8s.sh) and hardening the supporting scripts in the repository.

---

## Changes Made

### 1. New Master Deployment Script
- **[`deploy_k8s.sh`](deploy_k8s.sh)**
  - Implements all 26 steps sequentially with colorized progress reporting and error tracing (`set -euo pipefail`).
  - Defines `HOSTS_ENTRIES` as the single source of truth at the script header.
  - Automatically handles in-session `lxd` group activation via `exec sg lxd` if `$USER` was just added to the group, avoiding the need to log out and back in.
  - Seamlessly captures join credentials from `kubeadm init` on `node1` and updates `kubeadm-join-cp2-config.yaml` and `kubeadm-join-cp3-config.yaml` dynamically.
  - Automates `kube-vip` pod lifecycle via local CRI (`crictl`) checks during manifest updates to prevent VIP network deadlocks.

### 2. Modified Existing Scripts
- **[`steps.txt`](steps.txt)**:
  - Formatted, sequentially numbered (1 to 26), and added control-plane taint removal so pods can schedule across the all-control-plane topology.
- **[`setup_ssh_lxd_nodes.sh`](setup_ssh_lxd_nodes.sh)**:
  - Accepts `HOSTS_ENTRIES` dynamically from CLI arguments (passed by `deploy_k8s.sh`), while maintaining fallback defaults for standalone execution.
  - Automatically derives the `NODES` array from `HOSTS_ENTRIES`.
  - Moved the network and DNS resolution polling loop outside the `if [ "$STATE" != "RUNNING" ]` block so it always verifies connectivity before executing `apt-get update`.
- **[`lxd_docker_iptables.sh`](lxd_docker_iptables.sh)**:
  - Passed `DEBIAN_FRONTEND=noninteractive` directly to `sudo` (`sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent`) to prevent `sudo`'s `env_reset` from stripping the variable and causing interactive ncurses debconf prompts.
- **[`kube-vip.sh`](kube-vip.sh)**:
  - Added `sudo mkdir -p /etc/kubernetes/manifests` prior to writing `kube-vip.yaml` to ensure the target directory exists on clean nodes.
- **[`containerd_install.sh`](containerd_install.sh)**:
  - Added `-y` flag to `apt install` commands to ensure non-interactive execution during unattended setup.
- **[`helm_install.sh`](helm_install.sh)**:
  - Added `-y` flag to `sudo apt-get install helm`.

---

## Detailed Step Mapping

| Step | Action | Implementation Detail |
|---|---|---|
| **1** | UFW disable | Checks if `ufw` command is present and disables it (`sudo ufw disable`). |
| **2** | Kernel modules | Writes `overlay`, `br_netfilter`, `nf_conntrack` to `/etc/modules-load.d/k8s.conf` and loads with `modprobe`. |
| **3** | Sysctl config | Writes bridge netfilter and `ip_forward=1` to `/etc/sysctl.d/99-k8s.conf` and applies with `sysctl --system`. |
| **4** | Install LXC | Runs `sudo apt-get update && sudo apt-get install -y lxc`. |
| **5** | Install LXD | Ensures `snapd` is present and runs `sudo snap install lxd`. |
| **6** | Group & permissions | Adds `$USER` to `lxd` group and activates via `exec sg lxd` if not already active in current shell. |
| **7** | LXD initialization | Runs `cat lxd-init-config \| lxd init --preseed` (skips if bridge `lxdbr0` already configured). |
| **8** | Docker-LXD firewall | Executes `bash lxd_docker_iptables.sh`. |
| **9** | LXD `k8s` profile | Creates profile `k8s` and configures it with `lxc profile edit k8s < k8s-profile-config`. |
| **10** | Launch containers | Launches `node1` (10.67.38.87), `node2` (10.67.38.221), and `node3` (10.67.38.211) using profile `k8s`. |
| **11** | SSH & node setup | Invokes `setup_ssh_lxd_nodes.sh "${HOSTS_ENTRIES[@]}"`. |
| **12** | Runtime & Kubeadm | Copies and runs `containerd_install.sh` and `kubeadm_install.sh`, regenerates `/etc/containerd/config.toml` (`SystemdCgroup = true`, `disabled_plugins = []`), detects pause image from `kubeadm config images list`, updates sandbox image, and restarts containerd. |
| **13** | Node 1 Bootstrap | Runs `kube-vip.sh`, temporarily adjusts `hostPath` to `super-admin.conf`, initializes control plane with `kubeadm init --upload-certs`, parses join token, CA hash, and cert-key, configures local `$HOME/.kube/config`, reverts `hostPath` to `admin.conf`, bounces `kube-vip` static pod using CRI, and verifies API server response. |
| **14** | Host Kubeconfig | Copies `~/.kube/config` from `node1` to host's `$HOME/.kube/config`. |
| **15** | Update join configs | Substitutes active token, CA cert hash, and certificate key into `kubeadm-join-cp2-config.yaml` and `kubeadm-join-cp3-config.yaml`. |
| **16** | Node 2 join | SCPs `kubeadm-join-cp2-config.yaml`, runs `kubeadm join`, and configures `$HOME/.kube/config` on `node2`. |
| **17** | Node 3 join | SCPs `kubeadm-join-cp3-config.yaml`, runs `kubeadm join`, and configures `$HOME/.kube/config` on `node3`. |
| **18** | Distribute kube-vip | Copies `/etc/kubernetes/manifests/kube-vip.yaml` from `node1` to `node2` and `node3`. |
| **19** | Host tooling | Runs `cilium_cli_install.sh`, `helm_install.sh`, and `kubectl_install.sh` on the host. |
| **20** | Untaint nodes | Runs `kubectl taint nodes --all node-role.kubernetes.io/control-plane-` so pods can schedule across the all-control-plane topology. |
| **21** | Fetch Cilium chart | Downloads `cilium-1.18.13.tgz` via `wget -nc`. |
| **22** | Helm template | Generates `cilium.yaml` from `cilium-deploy.yaml`. |
| **23** | Apply Cilium | Runs `kubectl apply -f ./cilium.yaml`. |
| **24** | Wait for Cilium | Loops `cilium status --wait` until ready. |
| **25** | Verify nodes | Waits for all nodes to report condition `Ready` (`kubectl wait --for=condition=Ready nodes --all --timeout=300s`). |
| **26** | Deploy dnsutils | Applies `dnsutils.yaml` and checks pod status. |

---

## Verification & Validation Results

1. **Syntax Validation**:
   - `bash -n deploy_k8s.sh`: Passed (exit code 0).
   - `bash -n setup_ssh_lxd_nodes.sh`: Passed (exit code 0).
2. **File Permissions**:
   - `deploy_k8s.sh` is executable (`-rwxrwxr-x`).
3. **Environment & Live Cluster Checks**:
   - Verified on running host that `jq` is pre-installed in Ubuntu 24.04 LXD image (`jq-1.7`).
   - Verified that `agnhost:2.39` runs with default `CMD ["pause"]` without needing explicit sleep arguments.
   - Verified that node taints (`node-role.kubernetes.io/control-plane-`) allow pods to schedule properly.

---

## How to Execute

To execute the deployment on a fresh host:

```bash
cd /path/to/lxd-k8s
./deploy_k8s.sh
```

During Step 11, the script will prompt for the password to configure for `$USER` inside the containers.
