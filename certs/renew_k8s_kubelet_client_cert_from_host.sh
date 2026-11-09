#!/bin/bash
# Renews the kubelet client certificate of ONE node. MANUAL use only: nothing runs this script automatically.
#
# Usage: renew_k8s_kubelet_client_cert_from_host.sh <node-name>
#
# Run it by hand on the libvirt host (the machine that ran deploy_k8s.sh/deploy_k8s_libvirt.sh), as the user that deployed the cluster
# (passwordless ssh and sudo on the nodes). Nothing runs on a node by hand.
#
# What runs where:
#   1. Host:         checks that the host kubeconfig (~/.kube/config) is valid.
#   2. First node:   (FIRST_NODE below) signs a new kubelet.conf for <node-name> with 'kubeadm kubeconfig user'.
#                    Only the first control-plane node has /etc/kubernetes/pki/ca.key and ~/kubeadm-init-config.yaml
#                    (rendered by the deploy script). The new kubelet.conf comes back to the host.
#   3. Host:         copies the new kubelet.conf to <node-name> with scp.
#   4. <node-name>:  backs up the old kubelet.conf and kubelet client certificates, installs the new kubelet.conf,
#                    restarts the kubelet, and points kubelet.conf at the rotated certificate file.
#   5. Host:         waits until 'kubectl get node <node-name>' shows Ready, then prints the new certificate expiry.
#
# Before you run it:
#   - FIRST_NODE below must be the name of the first control-plane node. The deploy script can fill it in.
#   - ~/kubeadm-init-config.yaml must exist on the first node. If it was deleted, recreate it under the same name.
#   - If the control-plane certificates are expired, renew them first and refresh ~/.kube/config on the host from
#     /etc/kubernetes/admin.conf on the first node, because the final 'Ready' check uses ~/.kube/config.
#     The script exits if the host kubeconfig is not valid.
set -e

FIRST_NODE="<node1-name>"
INIT_CONFIG="kubeadm-init-config.yaml"   # in the home directory of the ssh user on FIRST_NODE
SSH_USER="${USER}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes)

usage() {
    echo "Usage: $0 <node-name>" >&2
    exit 1
}

NODE="$1"
[ -n "$NODE" ] && [ "$#" -eq 1 ] || usage
if [ "$FIRST_NODE" = "<node1-name>" ]; then
    echo "ERROR: FIRST_NODE is not set. Edit FIRST_NODE at the top of $0 (the name of the first control-plane node)." >&2
    exit 1
fi

# Check the host kubeconfig first: the final Ready check needs it, so fail before anything is changed.
if ! KUBECTL_OUT="$(kubectl get nodes --request-timeout=10s 2>&1)"; then
    echo "ERROR: the host kubeconfig (~/.kube/config) is not valid or the cluster is not reachable:" >&2
    echo "${KUBECTL_OUT}" >&2
    echo "Refresh ~/.kube/config from /etc/kubernetes/admin.conf on the first node and run the script again." >&2
    exit 1
fi

# Run a command on a node over ssh. Stdin is passed through (used for the 'bash -s' scripts below).
ssh_node() {
    local host="$1"
    shift
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "$@"
}

# The new kubelet.conf holds a private key: keep it in a private temporary file and delete it on exit.
KUBELET_CONF="$(mktemp)"
trap 'rm -f "$KUBELET_CONF"' EXIT

echo "Renewing kubelet client certificate of node ${NODE} (signed on ${FIRST_NODE})..."

# Step 1: sign the new kubelet.conf on the first node. Its stdout (the kubeconfig) goes to the host file.
ssh_node "$FIRST_NODE" "NODE='${NODE}' INIT_CONFIG='${INIT_CONFIG}' bash -s" > "$KUBELET_CONF" <<'EOF'
set -e
if ! sudo test -f /etc/kubernetes/pki/ca.key; then
    echo "ERROR: /etc/kubernetes/pki/ca.key not found: this is not the first control-plane node." >&2
    exit 1
fi
if [ ! -f "$INIT_CONFIG" ]; then
    echo "ERROR: ~/$INIT_CONFIG not found on this node. Recreate it under this name." >&2
    exit 1
fi
if grep -q '\${' "$INIT_CONFIG"; then
    echo "ERROR: ~/$INIT_CONFIG still has \${...} placeholders: it is not a rendered config." >&2
    exit 1
fi
sudo kubeadm kubeconfig user --config "$INIT_CONFIG" --org system:nodes --client-name "system:node:${NODE}" --v=9
EOF
if ! grep -q '^kind: Config' "$KUBELET_CONF"; then
    echo "ERROR: ${FIRST_NODE} did not return a kubeconfig. Nothing was changed on ${NODE}." >&2
    exit 1
fi

# Step 2: copy it to the target node.
scp "${SSH_OPTS[@]}" "$KUBELET_CONF" "${SSH_USER}@${NODE}:/tmp/kubelet-${NODE}.conf"

# Step 3: on the target node, back up the old files, install the new kubelet.conf and restart the kubelet.
ssh_node "$NODE" "sudo bash -s" <<EOF
set -e
mv -f /etc/kubernetes/kubelet.conf /etc/kubernetes/_old_kubelet.conf
rm -rf /var/lib/kubelet/pki/_old_kubelet-client
mkdir -p /var/lib/kubelet/pki/_old_kubelet-client
mv -f /var/lib/kubelet/pki/kubelet-client* /var/lib/kubelet/pki/_old_kubelet-client/
install -m 600 /tmp/kubelet-${NODE}.conf /etc/kubernetes/kubelet.conf
rm -f /tmp/kubelet-${NODE}.conf
systemctl restart kubelet
until test -f "/var/lib/kubelet/pki/kubelet-client-current.pem";
do
    sleep 1
done
sed -i -e "/    client-certificate-data/s/.*/    client-certificate: \/var\/lib\/kubelet\/pki\/kubelet-client-current.pem/" /etc/kubernetes/kubelet.conf
sed -i -e "/    client-key-data/s/.*/    client-key: \/var\/lib\/kubelet\/pki\/kubelet-client-current.pem/" /etc/kubernetes/kubelet.conf
systemctl restart kubelet
EOF

# Step 4: wait on the host until the node is Ready again.
until kubectl get node "$NODE" 2>&1 | grep -q " Ready ";
do
    sleep 1
done
echo "Node ${NODE} is ready..."

echo ""
echo "+ openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -enddate   (on ${NODE})"
ssh_node "$NODE" "sudo bash -s" <<'EOF'
openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -enddate
EOF
echo ""
