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
  - **Time sync (chrony)**: step 1 installs `chrony` on the host and step 10 makes the host a time server for the bridge subnet (`allow ${BRIDGE_SUBNET}`, `local stratum 8`). The golden node (step 12) gets `chrony` too, configured with `server ${BRIDGE_IPV4} iburst` (the host address on `virbr0`) and `makestep 1 3`; the clones inherit it. `deploy_k8s.sh` has no chrony step: containers use the host clock.
  - Host tooling (Step 21) additionally installs **`yq`** (latest [mikefarah/yq](https://github.com/mikefarah/yq) release) to `/usr/local/bin/yq`, after verifying its SHA-256 checksum, and **`chartmuseum`** (latest [helm/chartmuseum](https://github.com/helm/chartmuseum) release, SHA-256 verified) to `/usr/local/bin/chartmuseum` if that file is not there yet, and **`containerd`** with **`nerdctl`** and the CNI plugins, and **BuildKit** (`buildkitd.service`) and a local container registry (`registry:3` on port 5000, see the Step 21 row below). The last two steps (Steps 30 and 31) then run chartmuseum as a systemd service on the host (port `HELM_REPO_SERVER_PORT`, charts in `CHARTS_DIR`, both from `inventory.txt`) and register it as the Helm repo `local`. `deploy_k8s.sh` does the same in its Steps 28 and 29.
  - Prepares the golden node for **Longhorn** (Step 12; cloned nodes inherit it) and installs Longhorn `${LONGHORN_VERSION}` in Step 27. `deploy_k8s.sh` has no Longhorn step.
- **Dynamic Cluster Topology**:
  - Centralized in `inventory.txt` with `NUM_CP` (validated `>= 3`) and `NUM_WORKER` (validated non-negative).
  - Strictly validates that node static IP variables (`NODE1_IP` .. `NODE${NUM_CP}_IP`) for control planes and (`NODE${NUM_CP+1}_IP` .. `NODE${NUM_CP+NUM_WORKER}_IP`) for workers are defined sequentially without gaps.
- **Dynamic `certSANs` Generation**:
  - Automatically generates dynamic `certSANs` in the embedded kubeadm init configuration for `127.0.0.1`, `localhost`, `VIP`, and every control plane node's IP address and hostname.
- **Pinned Kubernetes Version (Step 13; step 14 in `deploy_k8s_libvirt.sh`)**:
  - Sets `kubernetesVersion` in the embedded kubeadm init configuration (placeholder `${KUBERNETES_FULL_VERSION}`) to the full version of the kubeadm installed on `node1` (`kubeadm version -o short`, for example `v1.37.2`; the script stops if it cannot read a version). kubeadm then does not look up the latest version on `dl.k8s.io`, which times out without internet.
- **Golden Node Cloning Architecture (Step 12; step 13 in `deploy_k8s_libvirt.sh`)**:
  - Launches and fully provisions only `node1` with containerd, Kubernetes packages, and pre-pulled images (libvirt: also `chrony`, syncing from the host).
  - Stops `node1` and clones all remaining nodes (`node2` .. `node${TOTAL_NODES}`) via container copy (`incus copy` / `lxc copy`) or domain cloning (`sudo virt-clone`).
  - Automatically assigns static IPs / MACs, sets hostnames directly, and regenerates unique systemd machine-ids.
  - **SSH Host Key Isolation**: Regenerates unique SSH host keys (`rm -f /etc/ssh/ssh_host_* && ssh-keygen -A && systemctl restart ssh`) on all cloned nodes and rescans host keys via `ssh-keyscan` into `$HOME/.ssh/known_hosts`, preventing remote host identification conflicts.
  - **Reboot detection (libvirt)**: Before a clone is rebooted, its boot ID (`/proc/sys/kernel/random/boot_id`) is noted; the script then waits (up to 600 seconds) until the node reports a different boot ID before it checks the hostname, so an SSH answer from the still-running old boot is not taken as "rebooted". The polling `ssh` calls use `ServerAliveInterval=2` / `ServerAliveCountMax=3`, so a connection left hanging by a reboot fails after ~6 seconds and is retried (`deploy_k8s.sh` uses these options for its "is passwordless SSH already working" check).
- **Scoped Control Plane & Worker Joining (Steps 16, 17, 18; steps 17, 18, 19 in `deploy_k8s_libvirt.sh`)**:
  - Loops through remaining control plane nodes (`node2` .. `node${NUM_CP}`) to stream the embedded, parameterized control-plane join configuration, execute `kubeadm join`, and configure `$HOME/.kube/config`.
  - Distributes `kube-vip.yaml` static pod manifests exclusively to secondary control plane nodes.
  - Loops through dedicated worker nodes (`node${NUM_CP+1}` .. `node${TOTAL_NODES}`) to stream the embedded, parameterized worker join configuration and execute worker `kubeadm join`.
- **Certificate Check & Renewal (Step 19; step 20 in `deploy_k8s_libvirt.sh`)**:
  - On every control plane node (`node1` .. `node${NUM_CP}`; not on workers) installs `check_k8s_certs.sh` and `renew_k8s_control_plane_certs.sh` to `/usr/local/bin` and `check_k8s_certs.service` / `check_k8s_certs.timer` to `/etc/systemd/system`, sets `DEPLOY_USER` in the renewal script to `$USER`, and enables the timer. The timer runs the check 2 hours after boot and then every 12 hours; the check runs the renewal when a control plane certificate expires within 60 days.
  - `certs/renew_k8s_kubelet_client_cert_from_host.sh.template` (kubelet client certificate of one node) is not installed on the nodes. The step renders `certs/renew_k8s_kubelet_client_cert_from_host.sh` from it with `FIRST_NODE` set to `node1` (mode 0755, not tracked by git, overwritten on every run); the rendered script is run by hand on the host.
  - `certs/renew_k8s_control_plane_certs_from_host.sh.template` (renews the control plane certificates of all control plane nodes from the host) is not installed on the nodes either. The step renders `certs/renew_k8s_control_plane_certs_from_host.sh` from it with `FIRST_NODE`, `OTHER_CP_NODES` and `WORKER_NODES` set (mode 0755, not tracked by git, overwritten on every run). The rendered script is run by hand on the host; it renews node1, copies node1's `admin.conf` to the host `~/.kube/config`, renews the other control plane nodes, then copies the new kubeconfig to the ssh user and root on every worker.
- **Control Plane Untainting (Step 21; step 22 in `deploy_k8s_libvirt.sh`)**:
  - Removes control-plane taints from all control plane nodes (`node1` .. `node${NUM_CP}`), enabling workload scheduling across control planes while preserving standard worker node semantics.
- **Zero Helper Scripts (Self-Contained Deployment)**:
  - All previously external scripts (`docker_iptables.sh`, `setup_ssh_nodes.sh`, `containerd_install.sh`, `kubeadm_install.sh`, `kube-vip.sh`, `cilium_cli_install.sh`, `helm_install.sh`, `kubectl_install.sh`) have been folded directly into the master deployment scripts. This eliminates intermediate `scp` file transfers, avoids leaving temporary scripts in node home directories, and ensures complete deployment reproducibility.

---

## Unified Configurations & Manifests

- **[`inventory.txt`](inventory.txt)**: Centralized cluster inventory declaring `NUM_CP`, `NUM_WORKER`, `VIP`, bridge network gateways, static node IPs, resource sizing (`LIMITS_CPU`, `LIMITS_MEMORY`, `LIMITS_DISK`), and software versions (for libvirt also `LONGHORN_VERSION` and the Longhorn UI port `LONGHORN_PORT`; `deploy_k8s.sh` ignores them).
- **[`steps.txt`](steps.txt)**: Unified step-by-step manual reference for Incus and LXD system containers.
- **[`steps_libvirt.txt`](steps_libvirt.txt)**: Step-by-step manual reference for libvirt KVM virtual machines.
- **Unified Parameterized Configurations**:
  - `backup/container-engine-init-config.yaml`: Reference copy of the preseed initialization config parameterizing bridge and storage pool directory.
  - `backup/k8s-container-profile-config.yaml`: Reference copy of the profile configuration parameterizing bridge, CPU, and memory limits.
  - `backup/kubeadm-init-config.yaml`: Reference copy of the parameterized bootstrap control plane init configuration with dynamic `certSANs`, `kubernetesVersion` (`${KUBERNETES_FULL_VERSION}`, the kubeadm version installed on node1) and VIP endpoints.
  - `backup/kubeadm-join-cp-config.yaml`: Reference copy of the parameterized control-plane join configuration.
  - `backup/kubeadm-join-worker-config.yaml`: Reference copy of the parameterized worker-node join configuration.
  - The deployment scripts do not read the `backup/` files: they embed the same content as quoted heredocs (`KUBEADM_INIT_CONFIG`, `KUBEADM_JOIN_CP_CONFIG`, `KUBEADM_JOIN_WORKER_CONFIG`; `deploy_k8s.sh` also `CONTAINER_ENGINE_INIT_CONFIG`, `K8S_CONTAINER_PROFILE_CONFIG`), so a change must be made in both places.
  - `cilium-deploy.yaml`: Helm values configuration for Cilium CNI installation.
  - `dnsutils.yaml`: DNS testing pod manifest for cluster verification.
  - `certs/`: `check_k8s_certs.sh`, `renew_k8s_control_plane_certs.sh`, `check_k8s_certs.service` and `check_k8s_certs.timer` (installed on the control plane nodes in step 19; step 20 in `deploy_k8s_libvirt.sh`), `renew_k8s_kubelet_client_cert_from_host.sh.template` and `renew_k8s_control_plane_certs_from_host.sh.template` (rendered by the deploy script into `renew_k8s_kubelet_client_cert_from_host.sh` and `renew_k8s_control_plane_certs_from_host.sh`, which are run by hand on the host).

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
| **1** | Install Engine / Hypervisor | Installs Incus via Zabbly APT repo or LXD via snap, and `python-is-python3` (so `python` runs Python 3). | Installs QEMU/KVM, libvirt, virtinst, cloud tools, `chrony`, and `python-is-python3` (so `python` runs Python 3) via APT. |
| **2** | Group & permissions | Adds `$USER` to `incus-admin` or `lxd` group; activates via `exec sg`. | Adds `$USER` to `libvirt` and `kvm` groups; exports `LIBVIRT_DEFAULT_URI`. |
| **3** | UFW disable | Disables `ufw` on host if installed. | Disables `ufw` on host if installed. |
| **4** | Kernel modules | Loads `overlay`, `br_netfilter`, `nf_conntrack` on host. | Loads host acceleration module `vhost_net` on host. |
| **5** | Sysctl config | Enables bridge netfilter and `ip_forward=1` on host. | Enables `ip_forward=1` on host. |
| **6** | Network initialization | Preseeds the embedded container engine init configuration (`incusbr0` / `lxdbr0`). | Updates libvirt `default` network (`virbr0`) gateway and DHCP range. |
| **7** | Docker coexistence | Applies forward and masquerade rules to `DOCKER-USER` chain. | Applies forward and masquerade rules for `virbr0` to `DOCKER-USER`. |
| **8** | Profile / Base Image | Configures `k8s` profile with CPU and memory limits. | Downloads and caches Ubuntu Server cloud image (`.qcow2`). |
| **9** | Launch node1 | Launches container `node1` with static IP and profile `k8s`. | Provisions disk, cloud-init user-data (user `$USER` with passwordless sudo and the host's SSH public key; `~/.ssh/id_ed25519.pub` or `id_rsa.pub`; the script generates `~/.ssh/id_ed25519` if no key pair exists, and stops with the `ssh-keygen -y` command to run if a private key exists without its `.pub` file), and runs `virt-install`. |
| **- / 10** | Host chrony | No such step: containers use the host clock. | Backs up `/etc/chrony/chrony.conf` once to `chrony.conf.bak`, then writes a new one that uses the host's own clock as the time reference (`local stratum 8`, `manual`, `driftfile /var/lib/chrony/drift`) and allows the bridge subnet to sync (`allow ${BRIDGE_SUBNET}`). Restarts `chrony` and prints `chronyc -n sources` and `chronyc -n tracking`. |
| **10 / 11** | Hosts & SSH setup | Sets up host SSH key (stops with the `ssh-keygen -y` command to run if a private key exists without its `.pub` file), passwordless sudo, OpenSSH, and `/etc/hosts`. | Configures `/etc/hosts` mappings on host and inside `node1`. |
| **11 / 12** | Runtime & Kubeadm | Installs containerd (plus plain-http access to the registry on the host: `config_path = '/etc/containerd/certs.d'` in the `[plugins.'io.containerd.cri.v1.images'.registry]` section and `/etc/containerd/certs.d/${HOST_IP}:5000/hosts.toml` with `server = "http://${HOST_IP}:5000"`, `capabilities = ["pull", "resolve", "push"]` and `skip_verify = true`; cloned nodes inherit both), kubeadm, and pre-pulls pause image on `node1`. | Installs containerd (plus plain-http access to the registry on the host: `config_path = '/etc/containerd/certs.d'` in the `[plugins.'io.containerd.cri.v1.images'.registry]` section and `/etc/containerd/certs.d/${HOST_IP}:5000/hosts.toml` with `server = "http://${HOST_IP}:5000"`, `capabilities = ["pull", "resolve", "push"]` and `skip_verify = true`; cloned nodes inherit both), qemu-guest-agent, `chrony`, kubeadm, and pre-pulls the pause image on `node1`; prepares the node for Longhorn (before the netplan generalization; cloned nodes inherit it): installs `nfs-common`, stops and disables the multipath units (`multipathd.service`, `multipathd.socket`, `multipath-tools.service`, `multipath-tools-boot.service`; units that do not exist are ignored), loads `dm_crypt`, `iscsi_tcp` and `nfs` now and at boot (`/etc/modules-load.d/longhorn.conf`) and starts and enables `iscsid`; then generalizes netplan and configures `chrony` to sync from the host (`/etc/chrony/chrony.conf`: `server ${BRIDGE_IPV4} iburst`, `driftfile /var/lib/chrony/chrony.drift`, `makestep 1 3`; the original is kept once as `chrony.conf.bak`; cloned nodes inherit it). |
| **12 / 13** | Clone remaining nodes | Clones `node2 .. node${TOTAL_NODES}`, sets static IPs, hostnames, regenerates machine-ids and **SSH host keys**. | Clones domains/disks via `virt-clone`, registers static DHCP MAC reservations, regenerates machine-ids and **SSH host keys**. Notes each clone's boot ID before its reboot and waits (up to 600 s) for a changed boot ID before the hostname check. The polling `ssh` calls use `ServerAliveInterval=2`/`ServerAliveCountMax=3`, so a connection left hanging by a reboot fails after ~6 s and is retried. |
| **13 / 14** | Bootstrap node1 | Generates `kube-vip.yaml`, temporarily sets `super-admin.conf`, renders the embedded kubeadm init configuration with the full kubeadm version installed on node1 (`kubeadm version -o short`, e.g. `v1.37.2`) as `kubernetesVersion` (so kubeadm does not look up the latest version on `dl.k8s.io`), runs `kubeadm init` with dynamic `certSANs`, parses join credentials, and cycles `kube-vip` static pod with CRI. | Generates `kube-vip.yaml` (on node1's default-route interface; `enp1s0` if none is found), sets `super-admin.conf`, renders the embedded kubeadm init configuration with the full kubeadm version installed on node1 (`kubeadm version -o short`, e.g. `v1.37.2`) as `kubernetesVersion` (so kubeadm does not look up the latest version on `dl.k8s.io`), runs `kubeadm init` with dynamic `certSANs`, parses join credentials, and cycles `kube-vip` static pod with CRI. |
| **14 / 15** | Host Kubeconfig | Copies `~/.kube/config` to host and sets `chmod 600`. | Copies `~/.kube/config` to host and sets `chmod 600`. |
| **15 / 16** | Validate join credentials | Validates active join token, CA cert hash, and certificate key. | Validates active join token, CA cert hash, and certificate key. |
| **16 / 17** | Join control planes | Loops over `node2 .. node${NUM_CP}`, parameterizes the embedded control-plane join configuration, and joins. | Loops over `node2 .. node${NUM_CP}`, parameterizes the embedded control-plane join configuration, and joins. |
| **17 / 18** | Distribute kube-vip | Copies `kube-vip.yaml` to remaining control planes (`node2 .. node${NUM_CP}`). | Copies `kube-vip.yaml` to remaining control planes (`node2 .. node${NUM_CP}`). |
| **18 / 19** | Join worker nodes | Loops over worker nodes (`node${NUM_CP+1} .. node${TOTAL_NODES}`) and joins. | Loops over worker nodes (`node${NUM_CP+1} .. node${TOTAL_NODES}`) and joins. |
| **19 / 20** | Certificate scripts | On each control plane node (`node1 .. node${NUM_CP}`; not on workers) installs `check_k8s_certs.sh` and `renew_k8s_control_plane_certs.sh` to `/usr/local/bin` and `check_k8s_certs.service` / `check_k8s_certs.timer` to `/etc/systemd/system`, sets `DEPLOY_USER` in the renewal script to `$USER`, and enables the timer (`systemctl enable --now check_k8s_certs.timer`). It also renders the host-side `certs/renew_k8s_kubelet_client_cert_from_host.sh` from `certs/renew_k8s_kubelet_client_cert_from_host.sh.template` with `FIRST_NODE` set to `node1` (run by hand, not installed). It likewise renders `certs/renew_k8s_control_plane_certs_from_host.sh` from its `.template` with `FIRST_NODE`, `OTHER_CP_NODES` and `WORKER_NODES` set (run by hand, not installed): it renews the certificates on node1, copies node1's `admin.conf` to the host `~/.kube/config`, renews the other control planes, then copies the new kubeconfig to the ssh user and root on every worker. | Same as containers. |
| **20 / 21** | Host tooling | Installs Cilium CLI, Helm, and Kubectl via APT (held) on host, and `chartmuseum` (latest helm/chartmuseum release from `get.helm.sh`, SHA-256 verified, to `/usr/local/bin/chartmuseum`); skips any tool already installed. Also sets up containerd on the host like node1 (the golden node on libvirt) but without the Kubernetes-only parts (pause image, kubeadm image pre-pull, kubelet / kubeadm / cri-tools), so Kubernetes can be added later: `containerd.io` (Docker apt repository), `/etc/containerd/config.toml` (default config with `SystemdCgroup = true` and `disabled_plugins = []`; an existing file is kept once as `config.toml.bak`), `nerdctl` (latest release, SHA-256 verified, `/usr/local/bin/nerdctl`) with `/etc/nerdctl/nerdctl.toml` (`namespace = "k8s.io"`), and the CNI plugins (`kubernetes-cni` from the Kubernetes apt repository, installed to `/opt/cni/bin`); then `daemon-reload`, `enable`, and a restart of containerd if the config changed. Last, it installs **BuildKit** on the host: the latest release from `github.com/moby/buildkit` (the release has no checksum file, so the download is not checksum-verified; the tarball's `bin/` content goes to `/usr/local/bin`), the unit `/etc/systemd/system/buildkitd.service` (`Type=notify`, `ExecStart=buildkitd`, `Restart=always`, started after `containerd.service`), `/etc/buildkit/buildkitd.toml` (the registry `${HOST_IP}:5000` over plain `http`) and a symlink `/etc/systemd/system/buildkitd.service.d` -> `containerd.service.d` (so buildkitd gets the same systemd drop-ins as containerd); then `daemon-reload`, `enable`, and a restart of buildkitd if anything was installed or written (otherwise just a start). Last, it starts the local container registry: `sudo nerdctl run -d -p 5000:5000 --restart=always --name registry registry:3` (plain http, reachable as `${HOST_IP}:5000`; skipped if a container named `registry` is already running, a stopped one is started). Each part is skipped if already in place. | Installs Cilium CLI (SHA-256 verified GitHub release), Helm and Kubectl via APT (held), `yq` (latest mikefarah/yq release, SHA-256 verified), and `chartmuseum` (latest helm/chartmuseum release from `get.helm.sh`, SHA-256 verified, to `/usr/local/bin/chartmuseum`) on host; skips any tool already installed. Also sets up containerd on the host like node1 (the golden node on libvirt) but without the Kubernetes-only parts (pause image, kubeadm image pre-pull, kubelet / kubeadm / cri-tools), so Kubernetes can be added later: `overlay` / `br_netfilter` and the bridge / `ip_forward` sysctls (`/etc/modules-load.d/k8s.conf`, `/etc/sysctl.d/99-k8s.conf`, written only if missing), `containerd.io` (Docker apt repository), `/etc/containerd/config.toml` (default config with `SystemdCgroup = true` and `disabled_plugins = []`; an existing file is kept once as `config.toml.bak`), `nerdctl` (latest release, SHA-256 verified, `/usr/local/bin/nerdctl`) with `/etc/nerdctl/nerdctl.toml` (`namespace = "k8s.io"`), and the CNI plugins (`kubernetes-cni` from the Kubernetes apt repository, installed to `/opt/cni/bin`); then `daemon-reload`, `enable`, and a restart of containerd if the config changed. Last, it installs **BuildKit** on the host: the latest release from `github.com/moby/buildkit` (the release has no checksum file, so the download is not checksum-verified; the tarball's `bin/` content goes to `/usr/local/bin`), the unit `/etc/systemd/system/buildkitd.service` (`Type=notify`, `ExecStart=buildkitd`, `Restart=always`, started after `containerd.service`), `/etc/buildkit/buildkitd.toml` (the registry `${HOST_IP}:5000` over plain `http`) and a symlink `/etc/systemd/system/buildkitd.service.d` -> `containerd.service.d` (so buildkitd gets the same systemd drop-ins as containerd); then `daemon-reload`, `enable`, and a restart of buildkitd if anything was installed or written (otherwise just a start). Last, it starts the local container registry: `sudo nerdctl run -d -p 5000:5000 --restart=always --name registry registry:3` (plain http, reachable as `${HOST_IP}:5000`; skipped if a container named `registry` is already running, a stopped one is started). Each part is skipped if already in place. |
| **21 / 22** | Untaint CP nodes | Removes control-plane taints from `node1 .. node${NUM_CP}`. | Removes control-plane taints from `node1 .. node${NUM_CP}`. |
| **22 / 23** | Fetch Cilium chart | Pulls `cilium-${CILIUM_VERSION}.tgz` via Helm from OCI registry. | Pulls `cilium-${CILIUM_VERSION}.tgz` via Helm from OCI registry. |
| **23 / 24** | Helm template | Renders `cilium.yaml` from `cilium-deploy.yaml`. | Renders `cilium.yaml` from `cilium-deploy.yaml`. |
| **24 / 25** | Apply Cilium | Applies `cilium.yaml` to cluster. | Applies `cilium.yaml` to cluster. |
| **25 / 26** | Wait for Cilium | Loops `cilium status --wait` until ready. | Loops `cilium status --wait` until ready. |
| **- / 27** | Install Longhorn | No such step: `deploy_k8s.sh` does not install Longhorn. | Downloads `https://raw.githubusercontent.com/longhorn/longhorn/${LONGHORN_VERSION}/deploy/longhorn.yaml` to `longhorn-${LONGHORN_VERSION}.yaml` (a `longhorn.yaml` kept in the directory is not overwritten) and patches it with one `yq` command: in the service `longhorn-frontend` it adds `${VIP}` as `externalIPs` and changes the port named `http` from 80 to `${LONGHORN_PORT}`; in the configmap `longhorn-default-setting` it appends `guaranteed-instance-manager-cpu: 0` to `default-setting.yaml` (skipped if already present). It checks the three values, then runs `kubectl apply -f` on the manifest. The Longhorn UI is then at `http://${VIP}:${LONGHORN_PORT}`; its pods keep starting in the background. `LONGHORN_PORT` must be 1-65535. The node prerequisites are done on the golden node in step 12. |
| **26 / 28** | Verify nodes | Waits for all nodes to report condition `Ready` (`kubectl wait --for=condition=Ready nodes --all --timeout=300s`). | Waits for all nodes to report condition `Ready` (`kubectl wait --for=condition=Ready nodes --all --timeout=300s`). |
| **27 / 29** | Deploy dnsutils | Applies `dnsutils.yaml` test pod and verifies readiness. | Applies `dnsutils.yaml` test pod and verifies readiness. |
| **28 / 30** | chartmuseum service | Creates `CHARTS_DIR` (as the login user), overwrites `/etc/systemd/system/chartmuseum.service` (`/usr/local/bin/chartmuseum --debug --port=${HELM_REPO_SERVER_PORT} --storage=local --storage-local-rootdir=${CHARTS_DIR}`, `After=kubelet.service`, `LogLevelMax=notice`), runs `daemon-reload`, `enable` and `restart` (so a changed port or directory takes effect on a re-run), then waits up to 30 s for `/health` and stops with an error if it never answers. `HELM_REPO_SERVER_PORT` (1-65535) and `CHARTS_DIR` (absolute, ends with `/`) are checked at the start of the script; `HOST_IP` defaults to `BRIDGE_IPV4`, `CHARTS_DIR` to `<script directory>/charts/`. | Same. |
| **29 / 31** | local Helm repo | Runs `helm repo remove local \|\| true`, `helm repo add local http://${HOST_IP}:${HELM_REPO_SERVER_PORT}`, `helm repo update` and `helm repo list`. | Same. |

Where two numbers are given, the numbers differ: the first number is the step number in `deploy_k8s.sh` (containers), the second the one in `deploy_k8s_libvirt.sh`. From step 10 on the libvirt script is one step ahead because only it has the host chrony step (10), and from its Longhorn step (27) on it is two steps ahead because only it also has that step.

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
