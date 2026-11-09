#!/bin/bash
# Renews the control-plane certificates of ALL control-plane nodes and refreshes the kubeconfig everywhere.
# MANUAL use only: nothing runs this script automatically.
#
# Usage: renew_k8s_control_plane_certs_from_host.sh
#
# Run it by hand on the libvirt host (the machine that ran deploy_k8s.sh/deploy_k8s_libvirt.sh), as the user that deployed the cluster
# (passwordless ssh and sudo on the nodes). It does not need a valid kubeconfig on the host: the certificates may be expired.
# The renewal itself is done by /usr/local/bin/renew_k8s_control_plane_certs.sh, which the deploy script installed on every
# control-plane node.
#
# What runs where:
#   1. First node:    (FIRST_NODE below) runs 'sudo /usr/local/bin/renew_k8s_control_plane_certs.sh'.
#   2. Host:          copies /etc/kubernetes/admin.conf of the first node to ~/.kube/config.
#                     The old host kubeconfig is kept as ~/.kube/_old_kube_config.
#   3. Other CP nodes: (OTHER_CP_NODES below, one after the other) run 'sudo /usr/local/bin/renew_k8s_control_plane_certs.sh'.
#   4. Worker nodes:  (WORKER_NODES below) get the new host ~/.kube/config as ~/.kube/config of the ssh user and of root.
#   5. Host:          prints 'kubectl get nodes' with the new kubeconfig.
#
# Before you run it:
#   - FIRST_NODE, OTHER_CP_NODES and WORKER_NODES below must be set. The deploy script fills them in.
#     Both node lists are space separated and may be empty.
set -e

FIRST_NODE="<node1-name>"
OTHER_CP_NODES="<other-cp-nodes>"   # control-plane nodes except FIRST_NODE, space separated
WORKER_NODES="<worker-nodes>"       # worker nodes, space separated
RENEW_SCRIPT="/usr/local/bin/renew_k8s_control_plane_certs.sh"
SSH_USER="${USER}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)

[ "$#" -eq 0 ] || { echo "Usage: $0" >&2; exit 1; }
if [ "$FIRST_NODE" = "<node1-name>" ] || [ "$OTHER_CP_NODES" = "<other-cp-nodes>" ] || [ "$WORKER_NODES" = "<worker-nodes>" ]; then
    echo "ERROR: FIRST_NODE, OTHER_CP_NODES or WORKER_NODES is not set. Edit them at the top of $0." >&2
    exit 1
fi

# Run a command on a node over ssh.
ssh_node() {
    local host="$1"
    shift
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "$@"
}

# Step 1: renew the certificates on the first node.
echo "Renewing the control plane certificates on ${FIRST_NODE}..."
ssh_node "$FIRST_NODE" "sudo ${RENEW_SCRIPT}"

# Step 2: copy the renewed admin.conf to the host. It holds a private key: take it into a private temporary file first,
# so a failed copy never replaces the old host kubeconfig.
echo "Copying the kubeconfig of ${FIRST_NODE} to the host (~/.kube/config)..."
NEW_KUBECONFIG="$(mktemp)"
trap 'rm -f "$NEW_KUBECONFIG"' EXIT
ssh_node "$FIRST_NODE" "sudo cat /etc/kubernetes/admin.conf" > "$NEW_KUBECONFIG"
if ! grep -q '^kind: Config' "$NEW_KUBECONFIG"; then
    echo "ERROR: ${FIRST_NODE} did not return a kubeconfig. The host kubeconfig was not changed." >&2
    exit 1
fi
mkdir -p ~/.kube
chmod 700 ~/.kube
if [ -f ~/.kube/config ]; then
    mv -f ~/.kube/config ~/.kube/_old_kube_config
fi
install -m 600 "$NEW_KUBECONFIG" ~/.kube/config

# Step 3: renew the certificates on the other control-plane nodes, one at a time.
for NODE in $OTHER_CP_NODES; do
    echo "Renewing the control plane certificates on ${NODE}..."
    ssh_node "$NODE" "sudo ${RENEW_SCRIPT}"
done

# Step 4: give the ssh user and root on every worker node the new host kubeconfig.
for NODE in $WORKER_NODES; do
    echo "Copying the new kubeconfig to ${SSH_USER} and root on ${NODE}..."
    ssh_node "$NODE" "mkdir -p ~/.kube"
    scp "${SSH_OPTS[@]}" ~/.kube/config "${SSH_USER}@${NODE}:.kube/config"
    ssh_node "$NODE" "
        chmod 600 ~/.kube/config
        sudo install -d -m 700 -o root -g root /root/.kube
        sudo install -m 600 -o root -g root ~/.kube/config /root/.kube/config
    "
done

# Step 5: show the cluster state with the new host kubeconfig.
echo ""
echo "+ kubectl get nodes"
kubectl get nodes
echo ""
