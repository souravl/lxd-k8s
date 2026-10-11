#!/bin/bash

#source $HOME/proxy.sh
KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.37}"

sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubectl
sudo apt-mark hold kubectl
