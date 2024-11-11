#!/bin/bash

function update_secret {
    # read stdin
    echo "Reading certificate from stdin..."
    read -re new_cert

    # install depts
    echo "Installing curl sudo and jq..."

    if command -v apk 2>&1 >/dev/null
    then
        apk add --update curl jq sudo
    else
        apt-get update
        apt-get install curl jq -y
    end

    case `uname -m` in
        x86_64) ARCH=amd64; ;;
        armv7l) ARCH=arm; ;;
        aarch64) ARCH=arm64; ;;
        ppc64le) ARCH=ppc64le; ;;
        s390x) ARCH=s390x; ;;
        *) echo "un-supported arch, exit ..."; exit 1; ;;
    esac

    KUBECTL_VERSION=1.26.10

    curl -sLO https://storage.googleapis.com/kubernetes-release/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl
    mv kubectl /usr/local/bin/kubectl
    chmod +x /usr/local/bin/kubectl

    # get node tag
    echo "Getting node tag from HOSTNAME environmental:..."
    node_tag="$(env | grep HOSTNAME | cut -f 2 -d '-')"
    echo "Node tag: $node_tag"

    previous_content=$(cat /ravendb/certs/"$node_tag".pfx)
    # update secret
    echo "Updating sever certificate on node $node_tag by updating ravendb-certs secret"
    /usr/local/bin/kubectl get secret ravendb-certs -o json -n ravendb | jq ".data[\"$node_tag.pfx\"]=\"$new_cert\"" | /usr/local/bin/kubectl apply -f -

    content=$(cat "/ravendb/certs/$node_tag.pfx")

    if [[ $previous_content == "$content" ]]; then
        echo "ERROR: The updated certificate (mounted secret path) is identical to the previous one..."
        exit 111
    fi
}

update_secret >> /var/log/ravendb-cert-update-logs
