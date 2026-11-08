#!/bin/bash
set -e

# Only control-plane nodes have the kube-apiserver static pod manifest. Exit early on a worker node.
if [ ! -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
    echo "ERROR: /etc/kubernetes/manifests/kube-apiserver.yaml not found. This is not a control-plane node, nothing to renew." >&2
    exit 1
fi

# The deploy user: the non-root user whose ~/.kube/config is also replaced with the renewed admin.conf.
# This script runs as root (from the systemd service), so it cannot find this user by itself.
DEPLOY_USER="<deploy-user>"

# If DEPLOY_USER is not set, or the user or its home directory does not exist on this node, only warn:
# the certificates are still renewed and root's kubeconfig is still replaced, but the deploy user's kubeconfig is skipped.
INSTALL_DEPLOY_KUBECONFIG=false
if [ "$DEPLOY_USER" = "<deploy-user>" ]; then
    echo "WARNING: DEPLOY_USER is not set. Edit DEPLOY_USER at the top of $0 (the user that deployed the cluster). Skipping the kubeconfig installation for the deploy user." >&2
else
    DEPLOY_HOME="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
    if [ -z "$DEPLOY_HOME" ] || [ ! -d "$DEPLOY_HOME" ]; then
        echo "WARNING: user '$DEPLOY_USER' or its home directory does not exist on this node. Skipping the kubeconfig installation for the deploy user." >&2
    else
        DEPLOY_GROUP="$(id -gn "$DEPLOY_USER")"
        INSTALL_DEPLOY_KUBECONFIG=true
    fi
fi

echo "Renewing all kubernetes control plane certificates..."
kubeadm certs renew all

# Back up and replace the kubeconfig of root and of the deploy user.
install -d -m 700 -o root -g root /root/.kube
if [ -f /root/.kube/config ]; then
    mv -f /root/.kube/config /root/.kube/_old_kube_config
fi
install -m 600 -o root -g root /etc/kubernetes/admin.conf /root/.kube/config

if [ "$INSTALL_DEPLOY_KUBECONFIG" = true ]; then
    install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_GROUP" "$DEPLOY_HOME/.kube"
    if [ -f "$DEPLOY_HOME/.kube/config" ]; then
        mv -f "$DEPLOY_HOME/.kube/config" "$DEPLOY_HOME/.kube/_old_kube_config"
    fi
    install -m 600 -o "$DEPLOY_USER" -g "$DEPLOY_GROUP" /etc/kubernetes/admin.conf "$DEPLOY_HOME/.kube/config"
fi

echo "Waiting for kubernetes pods to be deleted..."
rm -rf /tmp/k8s_manifests
mkdir -p /tmp/k8s_manifests
mv -f /etc/kubernetes/manifests/*.yaml /tmp/k8s_manifests/
sleep 30
until ! kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf > /dev/null 2>&1;
do
    sleep 1
done

echo "Waiting for kubernetes pods to restart..."
mv -f /tmp/k8s_manifests/*.yaml /etc/kubernetes/manifests/
sleep 30
until kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf 2>&1 | grep -q " Ready ";
do
    sleep 1
done
rm -rf /tmp/k8s_manifests
echo "Node is ready..."

echo ""
echo "+ kubeadm certs check-expiration"
kubeadm certs check-expiration
echo ""
