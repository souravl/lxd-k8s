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
  - **Zero Helper Scripts (Fully Self-Contained Deployment)**:
    - All previously external scripts (`docker_iptables.sh`, `setup_ssh_nodes.sh`, `containerd_install.sh`, `kubeadm_install.sh`, `kube-vip.sh`, `cilium_cli_install.sh`, `helm_install.sh`, `kubectl_install.sh`) have been folded directly into `deploy_k8s.sh`. This eliminates intermediate `scp` file transfers, avoids leaving temporary scripts in container home directories, and ensures complete deployment reproducibility from a single master script.
  - Automatically handles in-session group activation via `exec sg incus-admin` or `exec sg lxd`, preserving all command-line arguments.

### 2. Unified Configurations & Manifests
- **[`inventory.txt`](inventory.txt)**:
  - Centralized cluster inventory declaring `NUM_CP`, `NUM_WORKER`, `VIP`, bridge network gateways, static node IPs, container resource limits, and software versions (`UBUNTU_VERSION="24.04"`, `KUBERNETES_VERSION="v1.37"`, `CILIUM_VERSION="1.20.2"`).
- **Unified Parameterized Configurations**:
  - `container-engine-init-config.yaml`: Preseed initialization config parameterizing bridge and storage pool directory.
  - `k8s-container-profile-config.yaml`: Profile configuration parameterizing bridge, CPU, and memory limits.
  - `kubeadm-init-config.yaml`: Parameterized bootstrap control plane init configuration with `certSANs` and VIP endpoints.
  - `kubeadm-join-cp-config.yaml`: Parameterized control-plane join configuration.
  - `kubeadm-join-worker-config.yaml`: Parameterized worker-node join configuration.
  - `cilium-deploy.yaml`: Helm values configuration for Cilium CNI installation.
  - `dnsutils.yaml`: DNS testing pod manifest for cluster verification.
- **[`steps.txt`](steps.txt)**:
  - Step-by-step manual reference documenting both Incus and LXD operations side-by-side.

### 3. Usage & CLI Flags
```bash
# Deploy on Incus (default)
./deploy_k8s.sh -c incus

# Deploy on LXD
./deploy_k8s.sh -c lxd

# Non-interactive execution with pre-set container password
CONTAINER_PASS="your_password" ./deploy_k8s.sh -c incus
```

---

## Detailed Step Mapping

| Step | Action | Implementation Detail |
|---|---|---|
| **1** | Install Container Engine | Configures Zabbly repo and installs Incus via APT (default) or installs LXD via snap. |
| **2** | Group & permissions | Adds `$USER` to `incus-admin` (or `lxd`) group and activates via `exec sg` if not already active in current shell. |
| **3** | UFW disable | Checks if `ufw` command is present and disables it (`sudo ufw disable`). |
| **4** | Kernel modules | Writes `overlay`, `br_netfilter`, `nf_conntrack` to `/etc/modules-load.d/k8s.conf` and loads with `modprobe`. |
| **5** | Sysctl config | Writes bridge netfilter and `ip_forward=1` to `/etc/sysctl.d/99-k8s.conf` and applies with `sysctl --system`. |
| **6** | Engine initialization | Runs preseed initialization with parameterized `container-engine-init-config.yaml`. |
| **7** | Docker firewall coexistence | Inlined check for active Docker daemon; applies idempotent bridge forward and MASQUERADE rules to `DOCKER-USER` and `POSTROUTING` chains and saves with `netfilter-persistent`. |
| **8** | Container `k8s` profile | Creates profile `k8s` and configures it with parameterized `k8s-container-profile-config.yaml`. |
| **9** | Launch node1 | Launches only `node1` using profile `k8s` and static IP `NODE1_IP`. |
| **10** | SSH & node setup | Inlined setup of host SSH public key, passwordless sudo, OpenSSH server, and `/etc/hosts` resolution on `node1`. |
| **11** | Runtime & Kubeadm | Directly installs containerd and Kubernetes packages on `node1` over SSH, configures `config.toml`, and pre-pulls pause image. |
| **12** | Clone remaining nodes | Stops `node1`, clones all remaining nodes (`node2` .. `node${TOTAL_NODES}`) via `incus copy` / `lxc copy`, sets static IPs, starts nodes, sets hostnames, regenerates `/etc/machine-id`, and verifies SSH. |
| **13** | Node 1 Bootstrap | Directly generates `kube-vip.yaml` manifest on `node1`, temporarily adjusts `hostPath` to `super-admin.conf`, initializes control plane with `kubeadm init --upload-certs`, parses join token, CA hash, and cert-key, configures local `$HOME/.kube/config`, reverts `hostPath` to `admin.conf`, bounces `kube-vip` static pod using CRI, and verifies API server response. |
| **14** | Host Kubeconfig | Copies `~/.kube/config` from `node1` to host's `$HOME/.kube/config`. |
| **15** | Validate join credentials | Validates active join token, CA cert hash, and certificate key for control plane and worker nodes. |
| **16** | Join control planes | Loops over remaining control plane nodes (`node2` .. `node${NUM_CP}`), streams parameterized `kubeadm-join-cp-config.yaml`, runs `kubeadm join`, and configures `$HOME/.kube/config`. |
| **17** | Distribute kube-vip | Copies `/etc/kubernetes/manifests/kube-vip.yaml` from `node1` to remaining control plane nodes (`node2` .. `node${NUM_CP}`). |
| **18** | Join worker nodes | Loops over worker nodes (`node${NUM_CP+1}` .. `node${TOTAL_NODES}`), streams parameterized `kubeadm-join-worker-config.yaml`, and runs `kubeadm join`. |
| **19** | Host tooling | Installs Cilium CLI (with SHA256 verification), Helm (with Buildkite APT key ID verification), and Kubectl via APT (held) with idempotency checks to skip on repeat runs. |
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

### 1. Nodes Status (5-Node Cluster: 3 Control Planes + 2 Dedicated Workers)
```text
NAME    STATUS   ROLES           AGE     VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION              CONTAINER-RUNTIME
node1   Ready    control-plane   5m42s   v1.37.1   10.67.38.10   <none>        Ubuntu 24.04.5 LTS   6.8.0-142-generic (amd64)   containerd://2.4.2
node2   Ready    control-plane   5m6s    v1.37.1   10.67.38.20   <none>        Ubuntu 24.04.5 LTS   6.8.0-142-generic (amd64)   containerd://2.4.2
node3   Ready    control-plane   4m51s   v1.37.1   10.67.38.30   <none>        Ubuntu 24.04.5 LTS   6.8.0-142-generic (amd64)   containerd://2.4.2
node4   Ready    <none>          4m48s   v1.37.1   10.67.38.40   <none>        Ubuntu 24.04.5 LTS   6.8.0-142-generic (amd64)   containerd://2.4.2
node5   Ready    <none>          4m47s   v1.37.1   10.67.38.50   <none>        Ubuntu 24.04.5 LTS   6.8.0-142-generic (amd64)   containerd://2.4.2
```

### 2. Pods Status
```text
NAMESPACE     NAME                              READY   STATUS    RESTARTS   AGE
default       dnsutils                          1/1     Running   0          7s
kube-system   cilium-228lq                      1/1     Running   0          4m15s
kube-system   cilium-7mzvj                      1/1     Running   0          4m15s
kube-system   cilium-envoy-4jqbm                1/1     Running   0          4m15s
kube-system   cilium-envoy-4pnm6                1/1     Running   0          4m15s
kube-system   cilium-envoy-bw2xw                1/1     Running   0          4m15s
kube-system   cilium-envoy-cxh26                1/1     Running   0          4m15s
kube-system   cilium-envoy-zg8bn                1/1     Running   0          4m15s
kube-system   cilium-n45l2                      1/1     Running   0          4m15s
kube-system   cilium-operator-649867d84-4chvc   1/1     Running   0          4m15s
kube-system   cilium-operator-649867d84-hn5rp   1/1     Running   0          4m15s
kube-system   cilium-qp9nc                      1/1     Running   0          4m15s
kube-system   cilium-vwph4                      1/1     Running   0          4m15s
kube-system   coredns-559f6c778d-9vmkl          1/1     Running   0          5m29s
kube-system   coredns-559f6c778d-xbss9          1/1     Running   0          5m29s
kube-system   etcd-node1                        1/1     Running   0          5m47s
kube-system   etcd-node2                        1/1     Running   0          5m10s
kube-system   etcd-node3                        1/1     Running   0          4m56s
kube-system   hubble-relay-856fb9b979-52gd6     1/1     Running   0          4m15s
kube-system   hubble-ui-6dcdfb579c-rmm7w        2/2     Running   0          4m15s
kube-system   kube-apiserver-node1              1/1     Running   0          5m47s
kube-system   kube-apiserver-node2              1/1     Running   0          5m10s
kube-system   kube-apiserver-node3              1/1     Running   0          4m56s
kube-system   kube-controller-manager-node1     1/1     Running   0          5m47s
kube-system   kube-controller-manager-node2     1/1     Running   0          5m10s
kube-system   kube-controller-manager-node3     1/1     Running   0          4m56s
kube-system   kube-proxy-4sfxl                  1/1     Running   0          4m55s
kube-system   kube-proxy-6c2qg                  1/1     Running   0          4m54s
kube-system   kube-proxy-hbf5b                  1/1     Running   0          4m58s
kube-system   kube-proxy-nw2xj                  1/1     Running   0          5m29s
kube-system   kube-proxy-xdckl                  1/1     Running   0          5m13s
kube-system   kube-scheduler-node1              1/1     Running   0          5m47s
kube-system   kube-scheduler-node2              1/1     Running   0          5m10s
kube-system   kube-scheduler-node3              1/1     Running   0          4m56s
kube-system   kube-vip-node1                    1/1     Running   2          5m47s
kube-system   kube-vip-node2                    1/1     Running   0          4m57s
kube-system   kube-vip-node3                    1/1     Running   0          4m56s
```
All static control plane pods, `kube-vip` Virtual IP failover pods, Cilium CNI DaemonSets across all 5 nodes, CoreDNS, Hubble relay & UI, and test workload `dnsutils` are 100% Ready and Running across both Incus and LXD deployments.
