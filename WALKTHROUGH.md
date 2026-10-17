# Walkthrough: HA Kubernetes Deployment Script on Incus & LXD

We have automated and fully verified the deployment of a High-Availability, 3-node multi-master Kubernetes cluster on Incus and LXD containers with `kube-vip` and Cilium CNI by creating a unified master script [`deploy_k8s.sh`](deploy_k8s.sh) and hardening all companion scripts.

---

## Changes Made & Hardening Applied

### 1. Unified Multi-Engine Master Script
- **[`deploy_k8s.sh`](deploy_k8s.sh)**
  - Supports both **Incus** (default) and **LXD** via bash `getopts` (`./deploy_k8s.sh [-c incus|lxd]`).
  - Implements all 26 steps sequentially with colorized progress reporting and error tracing (`set -euo pipefail`).
  - **Node Cloning Architecture (Steps 9-12)**: Launches and provisions only `node1` with containerd, kubeadm, and pause image pre-pulling, then stops `node1` and clones `node2` and `node3` via `incus copy` or `lxc copy`, assigns static IPs, sets hostnames directly (`echo ... > /etc/hostname && hostname ...`), regenerates machine IDs, and verifies SSH across all nodes.
  - **SSH Host Key Resilience**: Prunes stale keys from `$HOME/.ssh/known_hosts` on startup and sets `SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)` so re-running after deleting and recreating containers never encounters `Host key verification failed`.
  - **Idempotent Node1 Bootstrap**: Checks if `/etc/kubernetes/admin.conf` already exists before attempting `kubeadm init`, preventing preflight conflicts on re-runs.
  - **Token Selection Filter**: Correctly filters `kubeadm token list` for tokens with `authentication,signing` usage (avoiding internal TTL proxy tokens created by `upload-certs`).
  - **SSHFS-Safe In-Place Edits**: Replaced `sed -i` on join config files with safe temp-file writing (`sed ... > tmp && cat tmp > file`), ensuring compatibility with SSHFS and FUSE mounts.
  - Automatically handles in-session group activation via `exec sg incus-admin` or `exec sg lxd`, preserving all command-line arguments.

### 2. Unified Supporting Scripts & Symmetric Profiles
- **[`setup_ssh_nodes.sh`](setup_ssh_nodes.sh)**:
  - Unified script replacing engine-specific variants; uses `$CONTAINER_CMD` (`incus` or `lxc`).
  - Automatically prunes stale cluster host keys from `$HOME/.ssh/known_hosts`.
  - Added an initial check for existing passwordless SSH access across all nodes. If SSH is already working, it skips the container configuration and password prompt entirely.
  - Added support for `CONTAINER_PASS` environment variable.
- **[`docker_iptables.sh`](docker_iptables.sh)**:
  - Unified firewall coexistence script accepting bridge name (`incusbr0` or `lxdbr0`).
- **[`inventory.txt`](inventory.txt)**:
  - Centralized cluster inventory replacing `software_install_version.txt`.
  - Defines the virtual IP (`VIP`), bridge gateway IPs (`BRIDGE_IPV4`, `BRIDGE_IPV6`), static node IP addresses (`NODE1_IP`, `NODE2_IP`, `NODE3_IP`), container resource limits (`LIMITS_CPU="4"`, `LIMITS_MEMORY="4GB"`), the container OS release (`UBUNTU_VERSION="24.04"`), and software versions (`KUBERNETES_VERSION`, `CILIUM_VERSION`).
  - Automatically sourced by both `deploy_k8s.sh` and `setup_ssh_nodes.sh`.
- **Unified Parameterized Configurations**:
  - `container-engine-init-config`: Unified preseed configuration parameterizing `${BRIDGE}`, `${STORAGE_POOL_DIR}`, `${BRIDGE_IPV4}`, and `${BRIDGE_IPV6}`.
  - `k8s-container-profile-config`: Unified profile configuration parameterizing `${BRIDGE}`, `${LIMITS_CPU}`, and `${LIMITS_MEMORY}`.
  - Removed engine-specific references from descriptions (`description: Profile for Kubernetes`, `description: Default profile`, `description: Default project`).
- **[`steps.txt`](steps.txt)**:
  - Unified step-by-step manual guide presenting Incus and LXD commands side-by-side for steps 1–12 and shared instructions for steps 13–26.

---

## Detailed Step Mapping

| Step | Action | Implementation Detail |
|---|---|---|
| **1** | Install Container Engine | Configures Zabbly repo and installs Incus via APT (default) or installs LXD via snap. |
| **2** | Group & permissions | Adds `$USER` to `incus-admin` (or `lxd`) group and activates via `exec sg` if not already active in current shell. |
| **3** | UFW disable | Checks if `ufw` command is present and disables it (`sudo ufw disable`). |
| **4** | Kernel modules | Writes `overlay`, `br_netfilter`, `nf_conntrack` to `/etc/modules-load.d/k8s.conf` and loads with `modprobe`. |
| **5** | Sysctl config | Writes bridge netfilter and `ip_forward=1` to `/etc/sysctl.d/99-k8s.conf` and applies with `sysctl --system`. |
| **6** | Engine initialization | Runs preseed initialization with parameterized `container-engine-init-config`. |
| **7** | Docker firewall coexistence | Executes `docker_iptables.sh <bridge>`. |
| **8** | Container `k8s` profile | Creates profile `k8s` and configures it with parameterized `k8s-container-profile-config`. |
| **9** | Launch node1 | Launches only `node1` (10.67.38.87) using profile `k8s` and `-d eth0,ipv4.address=10.67.38.87`. |
| **10** | SSH & node setup | Invokes `setup_ssh_nodes.sh` to configure user, sudoers, and authorized keys on `node1`. |
| **11** | Runtime & Kubeadm | Copies and runs `containerd_install.sh` and `kubeadm_install.sh` on `node1` only, configures `config.toml`, and pulls pause image. |
| **12** | Clone node2 & node3 | Stops `node1`, clones `node2` and `node3` (`incus copy` / `lxc copy`), assigns their static IPs, starts all nodes, sets hostnames, regenerates `/etc/machine-id`, and verifies SSH. |
| **13** | Node 1 Bootstrap | Runs `kube-vip.sh`, temporarily adjusts `hostPath` to `super-admin.conf`, initializes control plane with `kubeadm init --upload-certs`, parses join token, CA hash, and cert-key, configures local `$HOME/.kube/config`, reverts `hostPath` to `admin.conf`, bounces `kube-vip` static pod using CRI, and verifies API server response. |
| **14** | Host Kubeconfig | Copies `~/.kube/config` from `node1` to host's `$HOME/.kube/config`. |
| **15** | Update join configs | Substitutes active token, CA cert hash, and certificate key into `kubeadm-join-cp2-config.yaml` and `kubeadm-join-cp3-config.yaml` via safe temporary file write-back. |
| **16** | Node 2 join | SCPs `kubeadm-join-cp2-config.yaml`, runs `kubeadm join`, and configures `$HOME/.kube/config` on `node2`. |
| **17** | Node 3 join | SCPs `kubeadm-join-cp3-config.yaml`, runs `kubeadm join`, and configures `$HOME/.kube/config` on `node3`. |
| **18** | Distribute kube-vip | Copies `/etc/kubernetes/manifests/kube-vip.yaml` from `node1` to `node2` and `node3`. |
| **19** | Host tooling | Installs `cilium` CLI (with curl progress bar), Helm, and Kubectl with existence checks to skip on repeat runs. |
| **20** | Untaint nodes | Runs `kubectl taint nodes --all node-role.kubernetes.io/control-plane-` so pods can schedule across the all-control-plane topology. |
| **21** | Fetch Cilium chart | Downloads `cilium-1.20.2.tgz` via `helm pull oci://quay.io/cilium/charts/cilium`. |
| **22** | Helm template | Generates `cilium.yaml` from `cilium-deploy.yaml`. |
| **23** | Apply Cilium | Runs `kubectl apply -f ./cilium.yaml`. |
| **24** | Wait for Cilium | Loops `cilium status --wait` until ready. |
| **25** | Verify nodes | Waits for all nodes to report condition `Ready` (`kubectl wait --for=condition=Ready nodes --all --timeout=300s`). |
| **26** | Deploy dnsutils | Applies `dnsutils.yaml` and checks pod status. |

---

## Live Verification Results

The script was executed and validated inside an isolated Ubuntu 24.04 KVM VM (`test-k8s`):

### 1. Nodes Status
```text
NAME    STATUS   ROLES           AGE     VERSION   INTERNAL-IP    EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION              CONTAINER-RUNTIME
node1   Ready    control-plane   35m     v1.37.1   10.67.38.87    <none>        Ubuntu 24.04.5 LTS   6.8.0-142-generic (amd64)   containerd://2.4.1
node2   Ready    control-plane   5m47s   v1.37.1   10.67.38.221   <none>        Ubuntu 24.04.5 LTS   6.8.0-142-generic (amd64)   containerd://2.4.1
node3   Ready    control-plane   5m35s   v1.37.1   10.67.38.211   <none>        Ubuntu 24.04.5 LTS   6.8.0-142-generic (amd64)   containerd://2.4.1
```

### 2. Pods Status
```text
NAMESPACE     NAME                               READY   STATUS    RESTARTS   AGE
default       dnsutils                           1/1     Running   0          2m24s
kube-system   cilium-27j65                       1/1     Running   0          6m31s
kube-system   cilium-4dxcr                       1/1     Running   0          6m31s
kube-system   cilium-4qc6t                       1/1     Running   0          6m31s
kube-system   cilium-envoy-9cxrh                 1/1     Running   0          6m31s
kube-system   cilium-envoy-lbxls                 1/1     Running   0          6m31s
kube-system   cilium-envoy-t7z2t                 1/1     Running   0          6m31s
kube-system   cilium-operator-7f69674786-fmw8x   1/1     Running   0          6m31s
kube-system   cilium-operator-7f69674786-qw7cx   1/1     Running   0          6m31s
kube-system   coredns-559f6c778d-gkkpf           1/1     Running   0          36m
kube-system   coredns-559f6c778d-trnvn           1/1     Running   0          36m
kube-system   etcd-node1                         1/1     Running   0          36m
kube-system   etcd-node2                         1/1     Running   0          7m22s
kube-system   etcd-node3                         1/1     Running   0          7m11s
kube-system   hubble-relay-7989949c9c-z47d7      1/1     Running   0          6m31s
kube-system   hubble-ui-85fcdb8cd4-pk577         2/2     Running   0          6m31s
kube-system   kube-apiserver-node1               1/1     Running   0          36m
kube-system   kube-apiserver-node2               1/1     Running   0          7m22s
kube-system   kube-apiserver-node3               1/1     Running   0          7m11s
kube-system   kube-controller-manager-node1      1/1     Running   0          36m
kube-system   kube-controller-manager-node2      1/1     Running   0          7m22s
kube-system   kube-controller-manager-node3      1/1     Running   0          7m11s
kube-system   kube-proxy-2w7qd                   1/1     Running   0          7m23s
kube-system   kube-proxy-dt4d2                   1/1     Running   0          7m11s
kube-system   kube-proxy-l849c                   1/1     Running   0          36m
kube-system   kube-scheduler-node1               1/1     Running   0          36m
kube-system   kube-scheduler-node2               1/1     Running   0          7m22s
kube-system   kube-scheduler-node3               1/1     Running   0          7m11s
kube-system   kube-vip-node1                     1/1     Running   0          7m30s
kube-system   kube-vip-node2                     1/1     Running   0          7m10s
kube-system   kube-vip-node3                     1/1     Running   0          7m9s
```
All static control plane pods, `kube-vip`, Cilium CNI, CoreDNS, and test workload `dnsutils` are 100% Ready and Running.
