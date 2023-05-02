#!/bin/bash

set -e

KUBECTL_VERSION=1.26.3

echo "Installing prerequisites..."
apk add --update curl unzip jq openssl findutils

case `uname -m` in
    x86_64) ARCH=amd64; ;;
    armv7l) ARCH=arm; ;;
    aarch64) ARCH=arm64; ;;
    ppc64le) ARCH=ppc64le; ;;
    s390x) ARCH=s390x; ;;
    *) echo "un-supported arch, exit ..."; exit 1; ;;
esac

curl -sLO https://storage.googleapis.com/kubernetes-release/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl
mv kubectl /usr/local/bin/kubectl
chmod +x /usr/local/bin/kubectl

echo "Copying /ravendb/ravendb-setup-package-readonly/pack.zip to the /ravendb folder..."
cp -v /ravendb/ravendb-setup-package/*.zip /ravendb/pack.zip


echo "Extracting files from the package..."
mkdir /ravendb/ravendb-setup-package-copy
cd /ravendb
unzip -qq pack.zip -d ./ravendb-setup-package-copy/ > /dev/null


first_node_tag_caps="$(find ravendb-setup-package-copy -maxdepth 1 -type d -printf '%P\n' | head -2 | tail -1)"
cd "ravendb-setup-package-copy/${first_node_tag_caps}"

urls=()
tags=()
domain_name="$(cat /ravendb/scripts/domain)"


echo "Converting server certificate .pfx file to .pem..."
openssl pkcs12 -in "$(find ./*certificate*)" -passin pass: -out cert.pem -nodes

echo "Discovering tags..."
for i in ../* ; do
  if [ -d "$i" ]; then
    tag="$(basename "$i" | tr '[:upper:]' '[:lower:]')"
    tags+=("$tag")
  fi
done


echo "Waiting for nodes to stand-up..."
for tag in "${tags[@]}"
do
while ! curl "https://$tag.$domain_name/setup/alive"
do
    echo -n "$tag... "
    sleep 3
done
done


echo "Figuring out which tags should be called..."
for tag in "${tags[@]}" ; do
  tag_index="$(curl https://"${tags[0]}"."$domain_name"/cluster/topology -Ss --cert cert.pem |  jq ".Topology.AllNodes | keys | index( \"$tag\" )" )"
  echo "$tag index is: $tag_index"
  if [ "$tag" != "${tags[0]}" ] && [ "$tag_index" == "null" ]; then
      urls+=("https://${tags[0]}.$domain_name/admin/cluster/node?url=https%3A%2F%2F$tag.$domain_name&tag=$(echo "$tag" | tr '[:lower:]' '[:upper:]')")
  fi
done


echo "Building cluster..."
echo "${urls[@]}"
for url in "${urls[@]}"
do
    curl -L -X PUT "$url" --cert cert.pem
done


cluster_size="1"
while [ "$cluster_size" != "${#tags[@]}" ]
do
sleep 1
cluster_size=$(curl "https://${tags[0]}.$domain_name/cluster/topology" -Ss --cert cert.pem | jq ".Topology.AllNodes | keys | length")
echo "Waiting for cluster build-up..."
echo "Current cluster size is $cluster_size. Expected cluster size: ${#tags[@]}"
done


echo "Registering admin client certificate..."
node_tag_upper="$(echo "${tags[0]}" | tr '[:lower:]' '[:upper:]')"
/app/Server/rvn put-client-certificate \
    "https://${tags[0]}.$domain_name" /ravendb/ravendb-setup-package-copy/"$node_tag_upper"/*.pfx /ravendb/ravendb-setup-package-copy/admin.client.certificate.*.pfx

echo "Generating new client certificate..."

curl "https://${tags[0]}.$domain_name/admin/certificates" \
  -H 'content-type: application/x-www-form-urlencoded' \
  --data-raw 'Options=%7B%22Name%22%3A%22opus%22%2C%22Permissions%22%3Anull%2C%22SecurityClearance%22%3A%22Operator%22%2C%22NotAfter%22%3A%222122-04-28T15%3A05%3A04Z%22%7D' \
  --cert cert.pem \
  -o opus.zip

unzip opus.zip

echo "Updating ravendb/ravendb-client-secret using kubectl get and kubectl apply..."
/usr/local/bin/kubectl get secret ravendb-client-secret -n ravendb --dry-run=client -o json | jq ".data[\"opus.pfx\"]=\"$(cat ./opus.pfx | base64)\"" | /usr/local/bin/kubectl apply -f -

echo "Copy ravendb/ravendb-client-secret to opus/ravendb-client-secret"
/usr/local/bin/kubectl get secret ravendb-client-secret -n ravendb --dry-run=client -o yaml | sed s/"namespace: ravendb"/"namespace: opus"/| /usr/local/bin/kubectl apply -n opus -f -
