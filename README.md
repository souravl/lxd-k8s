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
  - Automatically generates dynamic `certSANs` in the kubeadm init configuration (embedded in the deployment script) for all control plane nodes.
  - Automatically regenerates unique SSH host keys (`ssh-keygen -A`) on all cloned nodes to prevent host key collisions.
  - Sets `kubernetesVersion` in the embedded kubeadm init configuration (step 13; step 14 in `deploy_k8s_libvirt.sh`) to the full version of the kubeadm installed on node1 (`kubeadm version -o short`, for example `v1.37.2`), so kubeadm does not look up the latest version on `dl.k8s.io` (it times out without internet).
- **Certificate Check & Renewal**: Step 19 (step 20 in `deploy_k8s_libvirt.sh`) installs `check_k8s_certs.sh` and `renew_k8s_control_plane_certs.sh` to `/usr/local/bin` and a systemd service and timer (check every 12 hours, renew when a control plane certificate expires within 60 days) on every control plane node.
- **Modern Networking & CNI**: Cilium eBPF CNI with Hubble network observability.
- **Time sync (chrony, libvirt only)**: `deploy_k8s_libvirt.sh` installs `chrony` on the host (step 1) and configures it as a time server for the bridge subnet that uses the host's own clock (step 10). It is also installed on the golden node, where it is configured to sync from `BRIDGE_IPV4` (the host address on `virbr0`; step 12, inherited by every clone). `deploy_k8s.sh` does not set up chrony: containers use the host clock.
- **Persistent Storage (Longhorn, libvirt only)**: Step 27 of `deploy_k8s_libvirt.sh` installs Longhorn `${LONGHORN_VERSION}` from its upstream manifest (saved as `longhorn-<version>.yaml`) after patching it: the `longhorn-frontend` service gets `${VIP}` as externalIP and port `${LONGHORN_PORT}` (UI at `http://${VIP}:${LONGHORN_PORT}`), and `guaranteed-instance-manager-cpu: 0` is added to the default settings. The node prerequisites (`nfs-common`, multipath off, `dm_crypt` / `iscsi_tcp` / `nfs` modules, `iscsid`) are installed on the golden node in step 12. `deploy_k8s.sh` does not install Longhorn.
- **Configurable Inventory**: Centralized configuration in `inventory.txt` (Node static IPs, resource sizing for CPU/RAM/Disk, Ubuntu release, Kubernetes, Cilium, for libvirt the Longhorn version and UI port: `LONGHORN_VERSION` / `LONGHORN_PORT`, and the local Helm repo: `HOST_IP`, `HELM_REPO_SERVER_PORT`, `CHARTS_DIR`).
- **Firewall Coexistence**: Idempotent iptables rules allowing Docker and container/VM bridges (`incusbr0`, `lxdbr0`, or `virbr0`) to coexist seamlessly.
- **Self-Contained Deployment**: Master deployment scripts (`deploy_k8s.sh` and `deploy_k8s_libvirt.sh`) contain all orchestration, node provisioning, runtime installation, node cloning, host tooling (Cilium CLI, Helm, kubectl, `chartmuseum`, `containerd` with `nerdctl` and the CNI plugins, `buildkitd`; `deploy_k8s_libvirt.sh` also installs `yq` and `chrony`), and firewall configuration inline. The only files they read besides `inventory.txt` are the YAML manifests and the `certs/` scripts listed below.

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
# (libvirt: BRIDGE_IPV4 is also the chrony time server address of the VMs, see deploy_k8s_libvirt.sh steps 10 and 12)
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

# Longhorn (deploy_k8s_libvirt.sh step 27 only; deploy_k8s.sh does not use these): the manifest for this Git tag is
# downloaded (saved as longhorn-${LONGHORN_VERSION}.yaml), patched and applied.
# LONGHORN_PORT is the port of the longhorn-frontend (UI) service (upstream default 80); the service gets ${VIP} as externalIP,
# so the UI is reachable at http://${VIP}:${LONGHORN_PORT}.
LONGHORN_VERSION="v1.13.0"
LONGHORN_PORT="9080"

# Local Helm chart repository (host; deploy_k8s.sh steps 28 and 29, deploy_k8s_libvirt.sh steps 30 and 31): chartmuseum.service
# serves the charts in CHARTS_DIR on HELM_REPO_SERVER_PORT, and the Helm repo 'local' is added at
# http://${HOST_IP}:${HELM_REPO_SERVER_PORT}.
# HOST_IP: address of this host; empty = BRIDGE_IPV4 (the host address on the bridge). It is also the address of the plain-http registry
# ${HOST_IP}:5000 (a container on the host; containerd on the golden node, and so every node, and buildkitd on the host use it).
# CHARTS_DIR: absolute path that must end with '/'; created if missing; empty = <directory of the script>/charts/.
HOST_IP=""
HELM_REPO_SERVER_PORT="9000"
CHARTS_DIR=""
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
| `inventory.txt` | Cluster inventory: Node static IPs, resource sizing, OS version, Kubernetes / Cilium versions, (libvirt only) the Longhorn version and UI port (`LONGHORN_VERSION` / `LONGHORN_PORT`), and the local Helm repo (`HOST_IP`, `HELM_REPO_SERVER_PORT`, `CHARTS_DIR`) |
| `deploy_k8s.sh` | Master deployment script for Incus and LXD system containers (`-c incus\|lxd`); it also installs `chartmuseum` and `containerd` (with `nerdctl` and the CNI plugins from `kubernetes-cni`) and BuildKit (latest release, `buildkitd.service` with `/etc/buildkit/buildkitd.toml`) and a local container registry (`registry:3`, port 5000, started with `nerdctl run`) on the host in step 20, installs `python-is-python3` on the host in step 1, runs chartmuseum as a systemd service in step 28 and adds the Helm repo `local` in step 29 |
| `deploy_k8s_libvirt.sh` | Master deployment script for libvirt (KVM Virtual Machines); it also installs `yq`, `chartmuseum`, `containerd` (with `nerdctl` and the CNI plugins from `kubernetes-cni`), BuildKit (latest release, `buildkitd.service` with `/etc/buildkit/buildkitd.toml`), a local container registry (`registry:3`, port 5000, started with `nerdctl run`), `python-is-python3` and `chrony` on the host, runs chartmuseum as a systemd service in step 30 and adds the Helm repo `local` in step 31 (the host is configured as a time server for the bridge subnet in step 10), prepares the golden node for Longhorn (`nfs-common`, multipath services disabled, kernel modules `dm_crypt` / `iscsi_tcp` / `nfs` loaded at boot, `iscsid` enabled) and for chrony (syncs from `BRIDGE_IPV4`) in step 12 and installs Longhorn in step 27 |
| `steps.txt` | Unified step-by-step manual guide for Incus and LXD |
| `steps_libvirt.txt` | Step-by-step manual guide for libvirt (KVM Virtual Machines) |
| `backup/container-engine-init-config.yaml` | Reference copy of the parameterized container engine preseed configuration (Incus/LXD); not read by `deploy_k8s.sh`, which embeds the same content (`CONTAINER_ENGINE_INIT_CONFIG`), so change it in both places |
| `backup/k8s-container-profile-config.yaml` | Reference copy of the parameterized container profile for Kubernetes (Incus/LXD); not read by `deploy_k8s.sh`, which embeds the same content (`K8S_CONTAINER_PROFILE_CONFIG`), so change it in both places |
| `backup/kubeadm-init-config.yaml` | Reference copy of the parameterized kubeadm init configuration with dynamic `certSANs` and `kubernetesVersion` (`${KUBERNETES_FULL_VERSION}`, the kubeadm version installed on node1) for bootstrap control plane; not read by the deployment scripts, which embed the same content (`KUBEADM_INIT_CONFIG`), so change it in both places |
| `backup/kubeadm-join-cp-config.yaml` | Reference copy of the parameterized kubeadm join configuration for secondary control planes; not read by the deployment scripts, which embed the same content (`KUBEADM_JOIN_CP_CONFIG`), so change it in both places |
| `backup/kubeadm-join-worker-config.yaml` | Reference copy of the parameterized kubeadm join configuration for worker nodes; not read by the deployment scripts, which embed the same content (`KUBEADM_JOIN_WORKER_CONFIG`), so change it in both places |
| `cilium-deploy.yaml` | Helm values configuration for Cilium CNI installation |
| `dnsutils.yaml` | DNS verification testing pod manifest |
| `certs/check_k8s_certs.sh`, `certs/renew_k8s_control_plane_certs.sh` | Control plane certificate check and renewal scripts; step 19 (step 20 in `deploy_k8s_libvirt.sh`) installs them to `/usr/local/bin` on every control plane node (not on workers) and sets `DEPLOY_USER` in the renewal script to the login user. The check script skips the renewal unless a control plane certificate expires within 60 days; the renewal script exits on a node without `/etc/kubernetes/manifests/kube-apiserver.yaml` |
| `certs/check_k8s_certs.service`, `certs/check_k8s_certs.timer` | systemd one-shot service (runs the check script as root) and its timer (2 hours after boot, then every 12 hours); step 19 (step 20 in `deploy_k8s_libvirt.sh`) installs them to `/etc/systemd/system` and enables the timer |
| `certs/renew_k8s_kubelet_client_cert_from_host.sh` | Not installed on the nodes. Run by hand on the host to renew the kubelet client certificate of one node: `./certs/renew_k8s_kubelet_client_cert_from_host.sh <node-name>` (step 19 (step 20 in `deploy_k8s_libvirt.sh`) sets `FIRST_NODE` at the top of this repo copy to `node1`, so it changes the file on every deploy run) |
| `certs/renew_k8s_control_plane_certs_from_host.sh` | Not installed on the nodes. Run by hand on the host to renew the control plane certificates of all control plane nodes: `./certs/renew_k8s_control_plane_certs_from_host.sh`. It runs `/usr/local/bin/renew_k8s_control_plane_certs.sh` on node1, copies node1's `admin.conf` to `~/.kube/config` on the host (old one kept as `~/.kube/_old_kube_config`), runs the renewal on the other control plane nodes, then copies the new host kubeconfig to the ssh user and root on every worker node (step 19 (step 20 in `deploy_k8s_libvirt.sh`) sets `FIRST_NODE`, `OTHER_CP_NODES` and `WORKER_NODES` at the top of this repo copy, so it changes the file on every deploy run) |
| `WALKTHROUGH.md` | Detailed architectural overview and live verification report |
