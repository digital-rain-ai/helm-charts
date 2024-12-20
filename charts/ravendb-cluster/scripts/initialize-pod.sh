#!/usr/bin/env sh
set -e

apk add --update curl unzip jq sudo

case `uname -m` in
    x86_64) ARCH=amd64; ;;
    armv7l) ARCH=arm; ;;
    aarch64) ARCH=arm64; ;;
    ppc64le) ARCH=ppc64le; ;;
    s390x) ARCH=s390x; ;;
    *) echo "un-supported arch, exit ..."; exit 1; ;;
esac

curl -sLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl"
mv kubectl /usr/local/bin/kubectl
chmod +x /usr/local/bin/kubectl

echo "Copying RavenDB setup package to /ravendb"
cp "$(find /usr/ravendb/*.zip)" /ravendb/pack.zip
cd /ravendb

echo "Extracting files from the pack..."
mkdir /ravendb/ravendb-setup-package
unzip -qq pack.zip -d ./ravendb-setup-package/ > /dev/null
cd ravendb-setup-package

echo "Reading node tag from the HOSTNAME environmental..."
node_tag="$(env | grep HOSTNAME | cut -f 2 -d '-')"
cd "$(echo $node_tag | tr '[:lower:]' '[:upper:]')"

echo "Updating secret using kubectl get and kubectl apply..."
/usr/local/bin/kubectl get secret ravendb-certs -o json -n ravendb | jq ".data[\"$node_tag.pfx\"]=\"$(cat ./*certificate* | base64)\"" | /usr/local/bin/kubectl apply -f -
