# Walkthrough: HA Kubernetes Deployment on Incus, LXD & libvirt (KVM)

We have automated and verified the deployment of a High-Availability, multi-control-plane (`NUM_CP >= 3`) and optional dedicated worker (`NUM_WORKER`) Kubernetes cluster across **system containers (Incus or LXD)** and **hardware-accelerated virtual machines (libvirt / KVM)** with `kube-vip` virtual IP failover and Cilium eBPF CNI.

---

## Architecture & Capabilities

### 1. Unified Master Deployment Scripts
- **[`deploy_k8s.sh`](deploy_k8s.sh)** (System Containers):
  - Supports both **Incus** (default) and **LXD** via bash `getopts` (`./deploy_k8s.sh [-c incus|lxd]`).
  - Automatically handles in-session group activation (`incus-admin` / `lxd`) via `exec sg`, preserving all command-line arguments.
- **[`deploy_k8s_libvirt.sh`](deploy_k8s_libvirt.sh)** (KVM Virtual Machines):
  - Manages full hardware virtualization using QEMU/KVM, libvirt, and `virt-install`.
  - Downloads and caches official Ubuntu cloud images (`images/ubuntu-24.04-base.qcow2`), mounts cloud-init user-data, and provisions disks resized to `LIMITS_DISK`.
  - Automatically computes deterministic MAC addresses (`52:54:00:10:00:<hex of IP 4th octet>`) and registers live/persistent static DHCP host reservations in libvirt's `default` network (`virbr0`).
- **Dynamic Cluster Topology**:
  - Centralized in `inventory.txt` with `NUM_CP` (validated `>= 3`) and `NUM_WORKER` (validated non-negative).
  - Strictly validates that node static IP variables (`NODE1_IP` .. `NODE${NUM_CP}_IP`) for control planes and (`NODE${NUM_CP+1}_IP` .. `NODE${NUM_CP+NUM_WORKER}_IP`) for workers are defined sequentially without gaps.
- **Dynamic `certSANs` Generation**:
  - Automatically generates dynamic `certSANs` in `kubeadm-init-config.yaml` for `127.0.0.1`, `localhost`, `VIP`, and every control plane node's IP address and hostname.
- **Golden Node Cloning Architecture (Step 12)**:
  - Launches and fully provisions only `node1` with containerd, Kubernetes packages, and pre-pulled images.
  - Stops `node1` and clones all remaining nodes (`node2` .. `node${TOTAL_NODES}`) via container copy (`incus copy` / `lxc copy`) or domain cloning (`sudo virt-clone`).
  - Automatically assigns static IPs / MACs, sets hostnames directly, and regenerates unique systemd machine-ids.
  - **SSH Host Key Isolation**: Regenerates unique SSH host keys (`rm -f /etc/ssh/ssh_host_* && ssh-keygen -A && systemctl restart ssh`) on all cloned nodes and rescans host keys via `ssh-keyscan` into `$HOME/.ssh/known_hosts`, preventing remote host identification conflicts.
- **Scoped Control Plane & Worker Joining (Steps 16, 17, 18)**:
  - Loops through remaining control plane nodes (`node2` .. `node${NUM_CP}`) to stream parameterized `kubeadm-join-cp-config.yaml`, execute `kubeadm join`, and configure `$HOME/.kube/config`.
  - Distributes `kube-vip.yaml` static pod manifests exclusively to secondary control plane nodes.
  - Loops through dedicated worker nodes (`node${NUM_CP+1}` .. `node${TOTAL_NODES}`) to stream parameterized `kubeadm-join-worker-config.yaml` and execute worker `kubeadm join`.
- **Control Plane Untainting (Step 20)**:
  - Removes control-plane taints from all control plane nodes (`node1` .. `node${NUM_CP}`), enabling workload scheduling across control planes while preserving standard worker node semantics.
- **Zero Helper Scripts (Self-Contained Deployment)**:
  - All previously external scripts (`docker_iptables.sh`, `setup_ssh_nodes.sh`, `containerd_install.sh`, `kubeadm_install.sh`, `kube-vip.sh`, `cilium_cli_install.sh`, `helm_install.sh`, `kubectl_install.sh`) have been folded directly into the master deployment scripts. This eliminates intermediate `scp` file transfers, avoids leaving temporary scripts in node home directories, and ensures complete deployment reproducibility.

---

## Unified Configurations & Manifests

- **[`inventory.txt`](inventory.txt)**: Centralized cluster inventory declaring `NUM_CP`, `NUM_WORKER`, `VIP`, bridge network gateways, static node IPs, resource sizing (`LIMITS_CPU`, `LIMITS_MEMORY`, `LIMITS_DISK`), and software versions.
- **[`steps.txt`](steps.txt)**: Unified step-by-step manual reference for Incus and LXD system containers.
- **[`steps_libvirt.txt`](steps_libvirt.txt)**: Step-by-step manual reference for libvirt KVM virtual machines.
- **Unified Parameterized Configurations**:
  - `container-engine-init-config.yaml`: Preseed initialization config parameterizing bridge and storage pool directory.
  - `k8s-container-profile-config.yaml`: Profile configuration parameterizing bridge, CPU, and memory limits.
  - `kubeadm-init-config.yaml`: Parameterized bootstrap control plane init configuration with dynamic `certSANs` and VIP endpoints.
  - `kubeadm-join-cp-config.yaml`: Parameterized control-plane join configuration.
  - `kubeadm-join-worker-config.yaml`: Parameterized worker-node join configuration.
  - `cilium-deploy.yaml`: Helm values configuration for Cilium CNI installation.
  - `dnsutils.yaml`: DNS testing pod manifest for cluster verification.

---

## Usage & Execution

```bash
# 1. Deploy on Incus (default container engine)
CONTAINER_PASS="your_password" ./deploy_k8s.sh

# 2. Deploy on LXD (containers)
CONTAINER_PASS="your_password" ./deploy_k8s.sh -c lxd

# 3. Deploy on libvirt (KVM Virtual Machines)
./deploy_k8s_libvirt.sh
```

---

## Detailed Step Mapping

| Step | Action | Containers (Incus / LXD) | Virtual Machines (libvirt / KVM) |
|---|---|---|---|
| **1** | Install Engine / Hypervisor | Installs Incus via Zabbly APT repo or LXD via snap. | Installs QEMU/KVM, libvirt, virtinst, and cloud tools via APT. |
| **2** | Group & permissions | Adds `$USER` to `incus-admin` or `lxd` group; activates via `exec sg`. | Adds `$USER` to `libvirt` and `kvm` groups; exports `LIBVIRT_DEFAULT_URI`. |
| **3** | UFW disable | Disables `ufw` on host if installed. | Disables `ufw` on host if installed. |
| **4** | Kernel modules | Loads `overlay`, `br_netfilter`, `nf_conntrack` on host. | Loads host acceleration module `vhost_net` on host. |
| **5** | Sysctl config | Enables bridge netfilter and `ip_forward=1` on host. | Enables `ip_forward=1` on host. |
| **6** | Network initialization | Preseeds `container-engine-init-config.yaml` (`incusbr0` / `lxdbr0`). | Updates libvirt `default` network (`virbr0`) gateway and DHCP range. |
| **7** | Docker coexistence | Applies forward and masquerade rules to `DOCKER-USER` chain. | Applies forward and masquerade rules for `virbr0` to `DOCKER-USER`. |
| **8** | Profile / Base Image | Configures `k8s` profile with CPU and memory limits. | Downloads and caches Ubuntu Server cloud image (`.qcow2`). |
| **9** | Launch node1 | Launches container `node1` with static IP and profile `k8s`. | Provisions disk, cloud-init user-data, and runs `virt-install`. |
| **10** | Hosts & SSH setup | Sets up host SSH key, passwordless sudo, OpenSSH, and `/etc/hosts`. | Configures `/etc/hosts` mappings on host and inside `node1`. |
| **11** | Runtime & Kubeadm | Installs containerd, kubeadm, and pre-pulls pause image on `node1`. | Installs containerd, qemu-guest-agent, kubeadm, and generalizes netplan. |
| **12** | Clone remaining nodes | Clones `node2 .. node${TOTAL_NODES}`, sets static IPs, hostnames, regenerates machine-ids and **SSH host keys**. | Clones domains/disks via `virt-clone`, registers static DHCP MAC reservations, regenerates machine-ids and **SSH host keys**. |
| **13** | Bootstrap node1 | Generates `kube-vip.yaml`, temporarily sets `super-admin.conf`, runs `kubeadm init` with dynamic `certSANs`, parses join credentials, and cycles `kube-vip` static pod with CRI. | Generates `kube-vip.yaml` (`enp1s0`), sets `super-admin.conf`, runs `kubeadm init` with dynamic `certSANs`, parses join credentials, and cycles `kube-vip` static pod with CRI. |
| **14** | Host Kubeconfig | Copies `~/.kube/config` to host and sets `chmod 600`. | Copies `~/.kube/config` to host and sets `chmod 600`. |
| **15** | Validate join credentials | Validates active join token, CA cert hash, and certificate key. | Validates active join token, CA cert hash, and certificate key. |
| **16** | Join control planes | Loops over `node2 .. node${NUM_CP}`, parameterizes `kubeadm-join-cp-config.yaml`, and joins. | Loops over `node2 .. node${NUM_CP}`, parameterizes `kubeadm-join-cp-config.yaml`, and joins. |
| **17** | Distribute kube-vip | Copies `kube-vip.yaml` to remaining control planes (`node2 .. node${NUM_CP}`). | Copies `kube-vip.yaml` to remaining control planes (`node2 .. node${NUM_CP}`). |
| **18** | Join worker nodes | Loops over worker nodes (`node${NUM_CP+1} .. node${TOTAL_NODES}`) and joins. | Loops over worker nodes (`node${NUM_CP+1} .. node${TOTAL_NODES}`) and joins. |
| **19** | Host tooling | Installs Cilium CLI, Helm, and Kubectl via APT (held) on host. | Installs Cilium CLI, Helm, and Kubectl via APT (held) on host. |
| **20** | Untaint CP nodes | Removes control-plane taints from `node1 .. node${NUM_CP}`. | Removes control-plane taints from `node1 .. node${NUM_CP}`. |
| **21** | Fetch Cilium chart | Pulls `cilium-${CILIUM_VERSION}.tgz` via Helm from OCI registry. | Pulls `cilium-${CILIUM_VERSION}.tgz` via Helm from OCI registry. |
| **22** | Helm template | Renders `cilium.yaml` from `cilium-deploy.yaml`. | Renders `cilium.yaml` from `cilium-deploy.yaml`. |
| **23** | Apply Cilium | Applies `cilium.yaml` to cluster. | Applies `cilium.yaml` to cluster. |
| **24** | Wait for Cilium | Loops `cilium status --wait` until ready. | Loops `cilium status --wait` until ready. |
| **25** | Verify nodes | Waits for all nodes to report condition `Ready` (`kubectl wait --for=condition=Ready nodes --all --timeout=300s`). | Waits for all nodes to report condition `Ready` (`kubectl wait --for=condition=Ready nodes --all --timeout=300s`). |
| **26** | Deploy dnsutils | Applies `dnsutils.yaml` test pod and verifies readiness. | Applies `dnsutils.yaml` test pod and verifies readiness. |

---

## Live Verification Results

The automated deployment has been executed and validated end-to-end on a **5-node cluster topology (3 Control Planes + 2 Dedicated Workers)** across all supported targets:

| Deployment Target | Environment Type | Verification Log | Status |
|:---|:---|:---|:---:|
| **Incus** | System Containers | `deploy_k8s_incus.log` | **Verified** |
| **LXD** | System Containers | `deploy_k8s_lxd.log` | **Verified** |
| **libvirt** | KVM Virtual Machines | `deploy_k8s_libvirt.log.txt` | **Verified** |

### 1. Cluster Nodes Status (5-Node HA Topology)
```text
NAME    STATUS   ROLES           AGE     VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION              CONTAINER-RUNTIME
node1   Ready    control-plane   10m     v1.37.1   10.67.38.10   <none>        Ubuntu 24.04.5 LTS   6.8.0-generic (amd64)       containerd://2.4.2
node2   Ready    control-plane   8m17s   v1.37.1   10.67.38.20   <none>        Ubuntu 24.04.5 LTS   6.8.0-generic (amd64)       containerd://2.4.2
node3   Ready    control-plane   6m55s   v1.37.1   10.67.38.30   <none>        Ubuntu 24.04.5 LTS   6.8.0-generic (amd64)       containerd://2.4.2
node4   Ready    <none>          6m42s   v1.37.1   10.67.38.40   <none>        Ubuntu 24.04.5 LTS   6.8.0-generic (amd64)       containerd://2.4.2
node5   Ready    <none>          6m33s   v1.37.1   10.67.38.50   <none>        Ubuntu 24.04.5 LTS   6.8.0-generic (amd64)       containerd://2.4.2
```

### 2. Cluster Pods Status (All Components 100% Ready)
```text
NAMESPACE     NAME                              READY   STATUS    RESTARTS   AGE
default       dnsutils                          1/1     Running   0          16s
kube-system   cilium-24rxs                      1/1     Running   0          3m54s
kube-system   cilium-274xm                      1/1     Running   0          3m54s
kube-system   cilium-envoy-7cvwm                1/1     Running   0          3m54s
kube-system   cilium-envoy-8t5kg                1/1     Running   0          3m54s
kube-system   cilium-envoy-ccw7v                1/1     Running   0          3m54s
kube-system   cilium-envoy-m4852                1/1     Running   0          3m54s
kube-system   cilium-envoy-mnx8m                1/1     Running   0          3m54s
kube-system   cilium-kj2lm                      1/1     Running   0          3m54s
kube-system   cilium-kjs4q                      1/1     Running   0          3m54s
kube-system   cilium-operator-649867d84-jxnvt   1/1     Running   0          3m54s
kube-system   cilium-operator-649867d84-s8rbv   1/1     Running   0          3m54s
kube-system   cilium-z9prp                      1/1     Running   0          3m54s
kube-system   coredns-559f6c778d-fmx6f          1/1     Running   0          10m
kube-system   coredns-559f6c778d-j682d          1/1     Running   0          10m
kube-system   etcd-node1                        1/1     Running   0          10m
kube-system   etcd-node2                        1/1     Running   0          8m29s
kube-system   etcd-node3                        1/1     Running   0          7m10s
kube-system   hubble-relay-856fb9b979-4nrnl     1/1     Running   0          3m54s
kube-system   hubble-ui-6dcdfb579c-6zvh8        2/2     Running   0          3m54s
kube-system   kube-apiserver-node1              1/1     Running   0          10m
kube-system   kube-apiserver-node2              1/1     Running   0          8m29s
kube-system   kube-apiserver-node3              1/1     Running   0          7m10s
kube-system   kube-controller-manager-node1     1/1     Running   0          10m
kube-system   kube-controller-manager-node2     1/1     Running   0          8m29s
kube-system   kube-controller-manager-node3     1/1     Running   0          7m10s
kube-system   kube-proxy-bb2t4                  1/1     Running   0          6m49s
kube-system   kube-proxy-dtx4f                  1/1     Running   0          6m57s
kube-system   kube-proxy-fqgs2                  1/1     Running   0          10m
kube-system   kube-proxy-gh46d                  1/1     Running   0          8m33s
kube-system   kube-proxy-vr5xv                  1/1     Running   0          7m10s
kube-system   kube-scheduler-node1              1/1     Running   0          10m
kube-system   kube-scheduler-node2              1/1     Running   0          8m29s
kube-system   kube-scheduler-node3              1/1     Running   0          7m10s
kube-system   kube-vip-node1                    1/1     Running   0          9m55s
kube-system   kube-vip-node2                    1/1     Running   0          7m6s
kube-system   kube-vip-node3                    1/1     Running   0          7m3s
```

All control plane components, `kube-vip` virtual IP failover, Cilium eBPF CNI DaemonSets across all 5 nodes, CoreDNS, Hubble relay & UI, and the `dnsutils` test pod are 100% Ready and Running across Incus, LXD, and libvirt (KVM).
