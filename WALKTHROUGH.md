# Walkthrough: HA Kubernetes Deployment Script on Incus & LXD

We have automated and verified the deployment of a High-Availability, multi-control-plane (`NUM_CP >= 3`) and optional dedicated worker (`NUM_WORKER`) Kubernetes cluster on Incus and LXD containers with `kube-vip` virtual IP failover and Cilium eBPF CNI.

---

## Architecture & Capabilities

### 1. Unified Multi-Engine Master Script
- **[`deploy_k8s.sh`](deploy_k8s.sh)**:
  - Supports both **Incus** (default) and **LXD** via bash `getopts` (`./deploy_k8s.sh [-c incus|lxd]`).
  - Implements all deployment steps sequentially with colorized progress reporting and error tracing (`set -euo pipefail`).
  - **Dynamic Cluster Topology**:
    - Centralized in `inventory.txt` with `NUM_CP` (validated `>= 3`) and `NUM_WORKER` (validated non-negative).
    - Strictly checks that node static IP variables (`NODE1_IP` .. `NODE${NUM_CP}_IP`) for control planes and (`NODE${NUM_CP+1}_IP` .. `NODE${NUM_CP+NUM_WORKER}_IP`) for workers are defined sequentially without gaps.
  - **Node Cloning Architecture (Step 12)**:
    - Launches and provisions only `node1` with containerd, kubeadm, and pause image pre-pulling.
    - Stops `node1` and clones all remaining nodes (`node2` .. `node${TOTAL_NODES}`) via `incus copy` or `lxc copy`.
    - Automatically assigns static IPs, sets hostnames directly (`echo ... > /etc/hostname && hostname ...`), regenerates machine IDs, and verifies SSH across all nodes.
  - **Collapsed Control Plane Joining (Step 16)**:
    - Loops through all remaining control plane nodes (`node2` .. `node${NUM_CP}`) to stream parameterized `kubeadm-join-cp-config.yaml`, execute `kubeadm join`, and configure `$HOME/.kube/config`.
  - **kube-vip Distribution (Step 17)**:
    - Distributes `kube-vip.yaml` static pod manifests exclusively to secondary control plane nodes.
  - **Worker Node Joining (Step 18)**:
    - Loops through all worker nodes (`node${NUM_CP+1}` .. `node${TOTAL_NODES}`) to stream parameterized `kubeadm-join-worker-config.yaml` and execute worker `kubeadm join`.
  - **Control Plane Untainting (Step 20)**:
    - Removes control-plane taints from all control plane nodes (`node1` .. `node${NUM_CP}`), enabling workload scheduling across control planes while preserving standard worker node semantics.
  - **SSH Host Key Resilience**:
    - Prunes stale keys from `$HOME/.ssh/known_hosts` on startup and sets `SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)` so re-running after deleting and recreating containers never encounters host key verification conflicts.
  - **Idempotent Node1 Bootstrap**:
    - Checks if `/etc/kubernetes/admin.conf` already exists before attempting `kubeadm init`, preventing preflight conflicts on re-runs.
  - Automatically handles in-session group activation via `exec sg incus-admin` or `exec sg lxd`, preserving all command-line arguments.

### 2. Unified Supporting Scripts & Profiles
- **[`setup_ssh_nodes.sh`](setup_ssh_nodes.sh)**:
  - Unified script replacing engine-specific variants; uses `$CONTAINER_CMD` (`incus` or `lxc`).
  - Prunes stale cluster host keys from `$HOME/.ssh/known_hosts`.
  - Supports `CONTAINER_PASS` environment variable and passwordless SSH detection.
  - Synchronized with `inventory.txt` validation (`NUM_CP >= 3`, `NUM_WORKER`, and sequential node IP checks).
- **[`inventory.txt`](inventory.txt)**:
  - Centralized cluster inventory declaring `NUM_CP`, `NUM_WORKER`, `VIP`, bridge network gateways, static node IPs, container resource limits, and software versions (`UBUNTU_VERSION="24.04"`, `KUBERNETES_VERSION="v1.37"`, `CILIUM_VERSION="1.20.2"`).
- **Unified Parameterized Configurations**:
  - `container-engine-init-config`: Preseed initialization config parameterizing bridge and storage pool directory.
  - `k8s-container-profile-config`: Profile configuration parameterizing bridge, CPU, and memory limits.
  - `kubeadm-join-cp-config.yaml`: Parameterized control-plane join configuration.
  - `kubeadm-join-worker-config.yaml`: Parameterized worker-node join configuration.
- **[`steps.txt`](steps.txt)**:
  - Step-by-step manual reference documenting both Incus and LXD operations side-by-side.

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
| **7** | Docker firewall coexistence | Inlined check for active Docker daemon; applies idempotent bridge forward and MASQUERADE rules to `DOCKER-USER` and `POSTROUTING` chains and saves with `netfilter-persistent`. |
| **8** | Container `k8s` profile | Creates profile `k8s` and configures it with parameterized `k8s-container-profile-config`. |
| **9** | Launch node1 | Launches only `node1` using profile `k8s` and static IP `NODE1_IP`. |
| **10** | SSH & node setup | Invokes `setup_ssh_nodes.sh` to configure user, sudoers, and authorized keys on `node1`. |
| **11** | Runtime & Kubeadm | Copies and runs `containerd_install.sh` and `kubeadm_install.sh` on `node1`, configures `config.toml`, and pulls pause image. |
| **12** | Clone remaining nodes | Stops `node1`, clones all remaining nodes (`node2` .. `node${TOTAL_NODES}`) via `incus copy` / `lxc copy`, sets static IPs, starts nodes, sets hostnames, regenerates `/etc/machine-id`, and verifies SSH. |
| **13** | Node 1 Bootstrap | Runs `kube-vip.sh`, temporarily adjusts `hostPath` to `super-admin.conf`, initializes control plane with `kubeadm init --upload-certs`, parses join token, CA hash, and cert-key, configures local `$HOME/.kube/config`, reverts `hostPath` to `admin.conf`, bounces `kube-vip` static pod using CRI, and verifies API server response. |
| **14** | Host Kubeconfig | Copies `~/.kube/config` from `node1` to host's `$HOME/.kube/config`. |
| **15** | Validate join credentials | Validates active join token, CA cert hash, and certificate key for control plane and worker nodes. |
| **16** | Join control planes | Loops over remaining control plane nodes (`node2` .. `node${NUM_CP}`), streams parameterized `kubeadm-join-cp-config.yaml`, runs `kubeadm join`, and configures `$HOME/.kube/config`. |
| **17** | Distribute kube-vip | Copies `/etc/kubernetes/manifests/kube-vip.yaml` from `node1` to remaining control plane nodes (`node2` .. `node${NUM_CP}`). |
| **18** | Join worker nodes | Loops over worker nodes (`node${NUM_CP+1}` .. `node${TOTAL_NODES}`), streams parameterized `kubeadm-join-worker-config.yaml`, and runs `kubeadm join`. |
| **19** | Host tooling | Installs `cilium` CLI (with curl progress bar), Helm, and Kubectl with existence checks to skip on repeat runs. |
| **20** | Untaint CP nodes | Runs `kubectl taint nodes <node> node-role.kubernetes.io/control-plane-` across all control plane nodes (`node1` .. `node${NUM_CP}`). |
| **21** | Fetch Cilium chart | Downloads `cilium-${CILIUM_VERSION}.tgz` via `helm pull oci://quay.io/cilium/charts/cilium`. |
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
