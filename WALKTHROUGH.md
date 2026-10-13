# Walkthrough: HA Kubernetes Deployment Script on LXD

We have automated and fully verified the deployment of a High-Availability, 3-node multi-master Kubernetes cluster on LXD containers with `kube-vip` and Cilium CNI by creating [`deploy_k8s.sh`](deploy_k8s.sh) and hardening all supporting repository scripts.

---

## Changes Made & Hardening Applied

### 1. Master Deployment Script
- **[`deploy_k8s.sh`](deploy_k8s.sh)**
  - Implements all 25 steps sequentially with colorized progress reporting and error tracing (`set -euo pipefail`).
  - **LXD Device Syntax**: Uses `-d eth0,ipv4.address="$IP"` (instead of `--config`) for static IP assignments on container launch.
  - **Clean Networking**: Removed legacy `apt install lxc` to avoid spawning the unused `lxcbr0` bridge and extra `dnsmasq` service.
  - **Idempotent Node1 Bootstrap**: Checks if `/etc/kubernetes/admin.conf` already exists before attempting `kubeadm init`, preventing preflight conflicts on re-runs.
  - **Token Selection Filter**: Correctly filters `kubeadm token list` for tokens with `authentication,signing` usage (avoiding internal TTL proxy tokens created by `upload-certs`).
  - **SSHFS-Safe In-Place Edits**: Replaced `sed -i` on join config files with safe temp-file writing (`sed ... > tmp && cat tmp > file`), ensuring compatibility with SSHFS and FUSE mounts.
  - Automatically handles in-session `lxd` group activation via `exec sg lxd`.

### 2. Supporting Scripts Hardened
- **[`kubeadm_install.sh`](kubeadm_install.sh)**:
  - Added `cri-tools` to the package installation list so `crictl` is always present on every node to inspect runtime containers when the API VIP is cycling.
- **[`setup_ssh_lxd_nodes.sh`](setup_ssh_lxd_nodes.sh)**:
  - Added an initial check for existing passwordless SSH access across all nodes. If SSH is already working, it skips the container configuration and password prompt entirely.
  - Added support for `CONTAINER_PASS` environment variable.
- **[`steps.txt`](steps.txt)**:
  - Updated step 9 to reflect `-d eth0,ipv4.address=...`.
- **[`lxd_docker_iptables.sh`](lxd_docker_iptables.sh)**:
  - Added `DEBIAN_FRONTEND=noninteractive` to `sudo apt-get install -y iptables-persistent`.

---

## Detailed Step Mapping

| Step | Action | Implementation Detail |
|---|---|---|
| **1** | Install LXD | Ensures `snapd` is present and runs `sudo snap install lxd`. |
| **2** | Group & permissions | Adds `$USER` to `lxd` group and activates via `exec sg lxd` if not already active in current shell. |
| **3** | UFW disable | Checks if `ufw` command is present and disables it (`sudo ufw disable`). |
| **4** | Kernel modules | Writes `overlay`, `br_netfilter`, `nf_conntrack` to `/etc/modules-load.d/k8s.conf` and loads with `modprobe`. |
| **5** | Sysctl config | Writes bridge netfilter and `ip_forward=1` to `/etc/sysctl.d/99-k8s.conf` and applies with `sysctl --system`. |
| **6** | LXD initialization | Runs `cat lxd-init-config \| lxd init --preseed` (skips if bridge `lxdbr0` already configured). |
| **7** | Docker-LXD firewall | Executes `bash lxd_docker_iptables.sh`. |
| **8** | LXD `k8s` profile | Creates profile `k8s` and configures it with `lxc profile edit k8s < k8s-profile-config`. |
| **9** | Launch containers | Launches `node1` (10.67.38.87), `node2` (10.67.38.221), and `node3` (10.67.38.211) using profile `k8s` and `-d eth0,ipv4.address=...`. |
| **10** | SSH & node setup | Invokes `setup_ssh_lxd_nodes.sh "${HOSTS_ENTRIES[@]}"`. Skips prompt if SSH key auth is already functional. |
| **11** | Runtime & Kubeadm | Copies and runs `containerd_install.sh` and `kubeadm_install.sh`, regenerates `/etc/containerd/config.toml` (`SystemdCgroup = true`, `disabled_plugins = []`), updates pause sandbox image, and restarts containerd. |
| **12** | Node 1 Bootstrap | Runs `kube-vip.sh`, temporarily adjusts `hostPath` to `super-admin.conf`, initializes control plane with `kubeadm init --upload-certs`, parses join token, CA hash, and cert-key, configures local `$HOME/.kube/config`, reverts `hostPath` to `admin.conf`, bounces `kube-vip` static pod using CRI, and verifies API server response. |
| **13** | Host Kubeconfig | Copies `~/.kube/config` from `node1` to host's `$HOME/.kube/config`. |
| **14** | Update join configs | Substitutes active token, CA cert hash, and certificate key into `kubeadm-join-cp2-config.yaml` and `kubeadm-join-cp3-config.yaml` via safe temporary file write-back. |
| **15** | Node 2 join | SCPs `kubeadm-join-cp2-config.yaml`, runs `kubeadm join`, and configures `$HOME/.kube/config` on `node2`. |
| **16** | Node 3 join | SCPs `kubeadm-join-cp3-config.yaml`, runs `kubeadm join`, and configures `$HOME/.kube/config` on `node3`. |
| **17** | Distribute kube-vip | Copies `/etc/kubernetes/manifests/kube-vip.yaml` from `node1` to `node2` and `node3`. |
| **18** | Host tooling | Runs `cilium_cli_install.sh`, `helm_install.sh`, and `kubectl_install.sh` on the host. |
| **19** | Untaint nodes | Runs `kubectl taint nodes --all node-role.kubernetes.io/control-plane-` so pods can schedule across the all-control-plane topology. |
| **20** | Fetch Cilium chart | Downloads `cilium-1.20.2.tgz` via `helm pull oci://quay.io/cilium/charts/cilium`. |
| **21** | Helm template | Generates `cilium.yaml` from `cilium-deploy.yaml`. |
| **22** | Apply Cilium | Runs `kubectl apply -f ./cilium.yaml`. |
| **23** | Wait for Cilium | Loops `cilium status --wait` until ready. |
| **24** | Verify nodes | Waits for all nodes to report condition `Ready` (`kubectl wait --for=condition=Ready nodes --all --timeout=300s`). |
| **25** | Deploy dnsutils | Applies `dnsutils.yaml` and checks pod status. |
| **26** | Update host /etc/hosts | Updates or adds static IP mappings for `node1`, `node2`, and `node3` in `/etc/hosts` on the host machine. |

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
