#!/usr/bin/env sh

function update_secret {
    # read stdin
    echo "Reading certificate from stdin..."
    read -re new_cert

    # install depts
    echo "Installing curl sudo jq and kubectl..."
    apk add --update curl jq sudo kubectl

    # get node tag
    echo "Getting node tag from HOSTNAME environmental:..."
    node_tag="$(env | grep HOSTNAME | cut -f 2 -d '-')"
    echo "Node tag: $node_tag"

    previous_content=$(cat /ravendb/certs/"$node_tag".pfx)
    # update secret
    echo "Updating sever certificate on node $node_tag by updating ravendb-certs secret"
    kubectl get secret ravendb-certs -o json -n ravendb | jq ".data[\"$node_tag.pfx\"]=\"$new_cert\"" | kubectl apply -f -

    content=$(cat "/ravendb/certs/$node_tag.pfx")

    if [[ $previous_content == "$content" ]]; then
        echo "ERROR: The updated certificate (mounted secret path) is identical to the previous one..."
        exit 111
    fi
}

update_secret >> /var/log/ravendb-cert-update-logs
