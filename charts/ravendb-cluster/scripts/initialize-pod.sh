#!/usr/bin/env sh
set -e

apk add --update curl unzip jq sudo kubectl

echo "Copying RavenDB setup package to /ravendb"
cp "$(find /usr/ravendb/*.zip)" /ravendb/pack.zip
cd /ravendb

echo "Extracting files from the pack..."
mkdir /ravendb/ravendb-setup-package
unzip -qq pack.zip -d ./ravendb-setup-package/ > /dev/null
cd ravendb-setup-package

echo "Reading node tag from the HOSTNAME environmental..."
node_tag="$(env | grep HOSTNAME | cut -f 2 -d '-')"
cd "${node_tag^^}"

echo "Updating secret using kubectl get and kubectl apply..."
kubectl get secret ravendb-certs -o json -n ravendb | jq ".data[\"$node_tag.pfx\"]=\"$(cat ./*certificate* | base64)\"" | kubectl apply -f -
