#!/usr/bin/env bash
# ==============================================================================
# remove_host_tools.sh - Remove the host tooling installed by deploy_k8s_libvirt.sh and deploy_k8s.sh
# (deploy_k8s_libvirt.sh step 21 / deploy_k8s.sh step 20: Cilium CLI, Helm, kubectl, yq (libvirt script only), chartmuseum, containerd,
#  nerdctl, CNI plugins, BuildKit, the local registry; step 30 / 28: chartmuseum.service; step 31 / 29: the "local" Helm repo).
# Usage: ./remove_host_tools.sh [-y] [-n] [-d]
# Every part is skipped if it is not present, so the script can be run again. It reads no inventory and downloads nothing.
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

step_header() {
    echo -e "\n${CYAN}======================================================================${NC}"
    echo -e "${CYAN}==> Step $1: $2${NC}"
    echo -e "${CYAN}======================================================================${NC}"
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Removes, on this host, what the host tooling step (deploy_k8s_libvirt.sh step 21, deploy_k8s.sh step 20), the chartmuseum.service
step (30 / 28) and the Helm repo step (31 / 29) installed: Cilium CLI, Helm (+ apt repo, + the "local" Helm repo), kubectl
(+ apt repo), yq (installed by deploy_k8s_libvirt.sh only), chartmuseum (+ service), the registry container and image, BuildKit
(+ service, config, drop-ins), nerdctl (+ nerdctl.toml), containerd (+ config.toml, drop-ins, Docker apt repo) and the CNI plugins.
Parts that are not present are skipped.

Not touched: the Kubernetes cluster and its containers / VMs, the charts directory of chartmuseum (CHARTS_DIR), and
/etc/modules-load.d/k8s.conf and /etc/sysctl.d/99-k8s.conf (overlay, br_netfilter, bridge sysctls, ip_forward).

Options:
  -y             Do not ask for confirmation
  -n             Dry run: print what would be removed or changed, change nothing
  -d             Also delete the data directories /var/lib/containerd, /var/lib/nerdctl and /var/lib/buildkit
                 (all images and build cache of containerd and BuildKit, not only the registry image). Default: kept.
  -h             Show this help message
EOF
    exit 0
}

ASSUME_YES=false
DRY_RUN=false
DELETE_DATA=false
while getopts "ynhd" opt; do
    case "$opt" in
        y) ASSUME_YES=true ;;
        n) DRY_RUN=true ;;
        d) DELETE_DATA=true ;;
        *) usage ;;
    esac
done

# run <command...>: runs the command, or only prints it in a dry run. Every command that changes the host goes through it.
run() {
    if $DRY_RUN; then
        echo -e "    ${YELLOW}[dry-run]${NC} $*"
    else
        "$@"
    fi
}

# pkg_present <package>: true if dpkg has the package installed (or removed with its config files left)
pkg_present() {
    case "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" in
        installed|config-files) return 0 ;;
        *) return 1 ;;
    esac
}

# remove_path <path>: delete a file, directory or symlink (a symlink is removed itself, not what it points to)
remove_path() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        info "Removing $1"
        run sudo rm -rf -- "$1"
    fi
}

# remove_dir_if_empty <dir>
remove_dir_if_empty() {
    if [ -d "$1" ] && [ -z "$(ls -A "$1" 2>/dev/null)" ]; then
        info "Removing the empty directory $1"
        run sudo rmdir -- "$1"
    fi
}

# stop_unit <unit>: stop and disable a systemd unit if it exists
stop_unit() {
    if systemctl cat "$1" >/dev/null 2>&1; then
        info "Stopping and disabling $1"
        run sudo systemctl disable --now "$1" || warn "Could not stop/disable $1 (continuing)."
    fi
}

# purge_pkgs <package...>: apt purge the ones that are present
purge_pkgs() {
    local present=() p
    for p in "$@"; do
        if pkg_present "$p"; then present+=("$p"); fi
    done
    if [ "${#present[@]}" -gt 0 ]; then
        info "Purging package(s): ${present[*]}"
        run sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y "${present[@]}"
    fi
}

BIN_DIR="/usr/local/bin"
APT_REPOS_REMOVED=false

if ! $ASSUME_YES && ! $DRY_RUN; then
    echo "This removes the host tooling listed in '$0 -h' (Cilium CLI, Helm, kubectl, yq, chartmuseum, the registry container and image,"
    echo "BuildKit, nerdctl, containerd, the CNI plugins) together with their apt repos, configs, drop-ins and services."
    if $DELETE_DATA; then
        echo "It also DELETES /var/lib/containerd, /var/lib/nerdctl and /var/lib/buildkit (all container images and build cache)."
    fi
    if [ ! -t 0 ]; then
        error "No terminal to ask for confirmation. Use -y to proceed without asking, or -n for a dry run."
        exit 1
    fi
    read -r -p "Proceed? [y/N] " REPLY
    case "$REPLY" in
        y|Y|yes|YES) ;;
        *) info "Aborted. Nothing was changed."; exit 0 ;;
    esac
fi
if $DRY_RUN; then warn "Dry run: nothing is changed; the commands that would run are printed with [dry-run]."; fi

# ------------------------------------------------------------------------------
# Step 1: "local" Helm repo (needs helm, so it goes before Helm is removed)
# ------------------------------------------------------------------------------
step_header "1" "Remove the \"local\" Helm repo"
if command -v helm >/dev/null 2>&1; then
    if helm repo list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -qx local; then
        info "Removing the Helm repo local"
        run helm repo remove local
    else
        info "The Helm repo local is not configured. Skipping."
    fi
else
    info "helm is not installed. Skipping."
fi

# ------------------------------------------------------------------------------
# Step 2: chartmuseum and its service (the charts directory is kept)
# ------------------------------------------------------------------------------
step_header "2" "Remove chartmuseum and chartmuseum.service"
CM_UNIT="/etc/systemd/system/chartmuseum.service"
if [ -f "$CM_UNIT" ]; then
    CM_CHARTS_DIR=$(sed -n -E 's/.*--storage-local-rootdir=([^ ]+).*/\1/p' "$CM_UNIT" | head -n 1)
    if [ -n "$CM_CHARTS_DIR" ]; then
        warn "The charts directory ${CM_CHARTS_DIR} is kept; delete it yourself if you do not need the charts."
    fi
fi
stop_unit chartmuseum.service
remove_path "$CM_UNIT"
remove_path "${BIN_DIR}/chartmuseum"

# ------------------------------------------------------------------------------
# Step 3: registry container and image (needs nerdctl and a running containerd, so it goes before both are removed)
# ------------------------------------------------------------------------------
step_header "3" "Remove the local registry container and the registry:3 image"
if command -v nerdctl >/dev/null 2>&1 && systemctl is-active --quiet containerd; then
    if sudo nerdctl ps -a --format '{{.Names}}' | grep -qx registry; then
        info "Removing the container 'registry' (and its anonymous volumes)"
        run sudo nerdctl rm -f -v registry
    else
        info "The container 'registry' does not exist. Skipping."
    fi
    if $DRY_RUN; then
        info "Would remove the image registry:3 (if present)"
    elif sudo nerdctl rmi -f registry:3 >/dev/null 2>&1; then
        info "Removed the image registry:3"
    else
        info "The image registry:3 is not present. Skipping."
    fi
else
    warn "nerdctl is missing or containerd is not running; the registry container and image cannot be removed with nerdctl."
    if $DELETE_DATA; then
        warn "-d is set, so the image store is deleted with /var/lib/containerd in step 6."
    else
        warn "The registry image stays in /var/lib/containerd (use -d to delete the whole store)."
    fi
fi

# ------------------------------------------------------------------------------
# Step 4: BuildKit, its service, config and drop-ins (it depends on containerd, so it goes before containerd)
# ------------------------------------------------------------------------------
step_header "4" "Remove BuildKit (buildkitd.service, buildkitd.toml, drop-ins, binaries)"
stop_unit buildkitd.service
remove_path /etc/systemd/system/buildkitd.service
# buildkitd.service.d is a symlink to containerd.service.d; the link itself is removed here, never its target
remove_path /etc/systemd/system/buildkitd.service.d
remove_path /etc/buildkit
for f in "${BIN_DIR}"/buildkitd "${BIN_DIR}"/buildctl "${BIN_DIR}"/buildkit-*; do
    remove_path "$f"
done
if $DELETE_DATA; then remove_path /var/lib/buildkit; fi

# ------------------------------------------------------------------------------
# Step 5: nerdctl and nerdctl.toml
# ------------------------------------------------------------------------------
step_header "5" "Remove nerdctl and /etc/nerdctl/nerdctl.toml"
remove_path "${BIN_DIR}/nerdctl"
remove_path /etc/nerdctl
# bridge network config that nerdctl creates for its default network
for f in /etc/cni/net.d/nerdctl*.conflist; do
    remove_path "$f"
done
remove_dir_if_empty /etc/cni/net.d
remove_dir_if_empty /etc/cni
if $DELETE_DATA; then remove_path /var/lib/nerdctl; fi

# ------------------------------------------------------------------------------
# Step 6: containerd (package, config.toml, drop-ins, Docker apt repo)
# ------------------------------------------------------------------------------
step_header "6" "Remove containerd (containerd.io, /etc/containerd, drop-ins, Docker apt repo)"
if pkg_present docker-ce; then
    # containerd.io is a dependency of docker-ce: purging it would remove Docker as well
    warn "docker-ce is installed and needs containerd.io; containerd, its config and the Docker apt repo are left in place."
else
    stop_unit containerd.service
    purge_pkgs containerd.io
    remove_path /etc/containerd
    remove_path /etc/systemd/system/containerd.service.d
    for f in /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc; do
        if [ -e "$f" ]; then APT_REPOS_REMOVED=true; fi
        remove_path "$f"
    done
    if $DELETE_DATA; then remove_path /var/lib/containerd; fi
fi

# ------------------------------------------------------------------------------
# Step 7: CNI plugins (kubernetes-cni) and kubectl, with the Kubernetes apt repo
# ------------------------------------------------------------------------------
step_header "7" "Remove kubectl, the CNI plugins and the Kubernetes apt repo"
if pkg_present kubectl; then
    info "Releasing the apt hold on kubectl"
    run sudo apt-mark unhold kubectl
    purge_pkgs kubectl
fi
if pkg_present kubelet || pkg_present kubeadm; then
    # kubelet depends on kubernetes-cni: purging it would remove kubelet as well
    warn "kubelet/kubeadm is installed on this host; kubernetes-cni and the Kubernetes apt repo are left in place."
else
    purge_pkgs kubernetes-cni
    # the plugins' directory is removed only if nothing else is in it
    remove_dir_if_empty /opt/cni/bin
    remove_dir_if_empty /opt/cni
    for f in /etc/apt/sources.list.d/kubernetes.list /etc/apt/keyrings/kubernetes-apt-keyring.gpg; do
        if [ -e "$f" ]; then APT_REPOS_REMOVED=true; fi
        remove_path "$f"
    done
fi

# ------------------------------------------------------------------------------
# Step 8: Helm and its apt repo
# ------------------------------------------------------------------------------
step_header "8" "Remove Helm and its apt repo"
if pkg_present helm; then
    purge_pkgs helm
elif command -v helm >/dev/null 2>&1; then
    warn "helm ($(command -v helm)) was not installed by apt; leaving it."
fi
for f in /etc/apt/sources.list.d/helm-stable-debian.list /usr/share/keyrings/helm.gpg; do
    if [ -e "$f" ]; then APT_REPOS_REMOVED=true; fi
    remove_path "$f"
done

# ------------------------------------------------------------------------------
# Step 9: yq (deploy_k8s_libvirt.sh only) and Cilium CLI
# ------------------------------------------------------------------------------
step_header "9" "Remove yq (installed by deploy_k8s_libvirt.sh only) and the Cilium CLI"
remove_path "${BIN_DIR}/yq"
remove_path "${BIN_DIR}/cilium"

# ------------------------------------------------------------------------------
# Step 10: refresh systemd and the apt lists
# ------------------------------------------------------------------------------
step_header "10" "Reload systemd and refresh the apt package lists"
run sudo systemctl daemon-reload
run sudo systemctl reset-failed
if $APT_REPOS_REMOVED; then
    info "Refreshing the apt package lists (apt repos were removed)"
    run sudo apt-get update -qq
fi

if $DRY_RUN; then
    success "Dry run finished: nothing was changed."
else
    success "Host tooling removed."
fi
