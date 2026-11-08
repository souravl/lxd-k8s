#!/bin/bash
set -e

configfiles=(
    /etc/kubernetes/admin.conf
    /etc/kubernetes/scheduler.conf
    /etc/kubernetes/controller-manager.conf
    /etc/kubernetes/super-admin.conf
)

certfiles=(
    /etc/kubernetes/pki/apiserver.crt
    /etc/kubernetes/pki/apiserver-etcd-client.crt
    /etc/kubernetes/pki/apiserver-kubelet-client.crt
    /etc/kubernetes/pki/front-proxy-client.crt
    /etc/kubernetes/pki/etcd/healthcheck-client.crt
    /etc/kubernetes/pki/etcd/peer.crt
    /etc/kubernetes/pki/etcd/server.crt
)

get_expire_time() {
    local date=$(echo "$1" | openssl x509 -enddate -noout | sed "s/.*=\(.*\)/\1/")
    local date_s=$(date -d "${date}" +%s)
    local date_diff=$(( (date_s - now_s) / 86400 ))
    local expires=""
    if [ $date_diff -eq 0 ]; then
        expires="$(( (date_s - now_s) / 3600 )) hours"
    else
        expires="$date_diff days"
    fi

    echo "certificate expires in $expires"

    if [[ $date_diff -le $warning_period ]]
    then
        renew="true"
    fi
}

now_s=$(date -d now +%s)

renew="false"
warning_period=60

for configfile in ${configfiles[@]}; do
    if [ ! -f $configfile ]; then
        continue
    fi

    echo -n "Config file $configfile: "

    CERT_DATA=$(cat $configfile | grep client-certificate-data | sed 's/    client-certificate-data: //')
    CERT_FILE=$(cat $configfile | grep client-certificate | sed 's/    client-certificate: //')
    if [ "$CERT_DATA" ]; then
        get_expire_time "$(echo $CERT_DATA | base64 -d)"
    elif [ "$CERT_FILE" ]; then
        get_expire_time "$(cat $CERT_FILE)"
    else
        echo "no client certificate found"
    fi
done

for certfile in ${certfiles[@]}; do
    if [ ! -f $certfile ]; then
        continue
    fi
    echo -n "Certificate $certfile: "
    get_expire_time "$(cat $certfile)"
done

if [[ $renew == "true" ]]; then
    echo "One of the kubernetes control plane certificates is expiring in $warning_period days or less, so renewing all kubernetes control plane certificates..."
    /usr/local/bin/renew_k8s_control_plane_certs.sh
fi
