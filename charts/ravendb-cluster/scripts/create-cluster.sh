#!/bin/bash

set -e

BACKUP_ENABLED=$1
BACKUP_TASK_NAME=$2
BACKUP_FullBackupFrequency=$3
BACKUP_IncrementalBackupFrequency=$4
BACKUP_MinimumBackupAgeToKeep=$5
BACKUP_AZURE_StorageContainer=$6
BACKUP_AZURE_AccountName=$7
BACKUP_AZURE_SasTokenSecretName=$8

KUBECTL_VERSION=1.26.10

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
echo "Checking https://$tag.$domain_name"
while ! curl "https://$tag.$domain_name/setup/alive"
do
    echo -n "$tag... "
    sleep 3
done
done


echo "Figuring out which tags should be called..."
for tag in "${tags[@]}" ; do
  tag_index="$(curl https://"${tags[0]}"."$domain_name"/cluster/topology -Ss --cert cert.pem |  jq ".Topology.AllNodes | keys | index( \"$(echo "$tag" | tr '[:lower:]' '[:upper:]')\" )" )"
  echo "$tag index is: $tag_index"
  if [ "$tag" != "${tags[0]}" ] && [ "$tag_index" == "null" ]; then
      urls+=("https://${tags[0]}.$domain_name/admin/cluster/node?url=https%3A%2F%2F$tag.$domain_name&tag=$(echo "$tag" | tr '[:lower:]' '[:upper:]')")
  fi
done


echo "Building cluster..."
echo "${urls[@]}"
for url in "${urls[@]}"
do
    curl --retry 5 -L -X PUT "$url" --cert cert.pem
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


echo "Checking for existing client certificate..."
num_opus_certs=$(curl "https://${tags[0]}.$domain_name/admin/certificates?secondary=true&metadataOnly=true" -Ss --cert cert.pem | jq '.Results[] | select( .Name == "opus") | length')

if [ "$num_opus_certs" == "" ] || [ $num_opus_certs == 0 ]; then
  echo "Generating new client certificate..."

  curl "https://${tags[0]}.$domain_name/admin/certificates" \
    -H 'content-type: application/x-www-form-urlencoded' \
    --data-raw 'Options=%7B%22Name%22%3A%22opus%22%2C%22Permissions%22%3Anull%2C%22SecurityClearance%22%3A%22Operator%22%2C%22NotAfter%22%3A%222122-04-28T15%3A05%3A04Z%22%7D' \
    --cert cert.pem \
    -o opus.zip

  unzip opus.zip

  echo "Setting opus/ravendb-client-secret..."
  /usr/local/bin/kubectl create secret generic ravendb-client-secret -n opus --save-config --dry-run=client --from-file=opus.pfx=./opus.pfx -o yaml | /usr/local/bin/kubectl apply -f -
else
  echo "Client certificate already exists"
fi

if [ "$BACKUP_ENABLED" == "true" ]; then
  echo "Checking for existing server-wide periodic backup task..."

  num_backup_tasks=$(curl "https://${tags[0]}.$domain_name/admin/server-wide/tasks" -Ss --cert cert.pem | jq '.Tasks[] | select( .TaskType == "Backup") | length')

  if [ "$num_backup_tasks" == "" ] || [ $num_backup_tasks == 0 ]; then
    echo "Creating new server-wide periodic backup task..."

    AzureSasToken=$(/usr/local/bin/kubectl -n ravendb get secret $BACKUP_AZURE_SasTokenSecretName -o jsonpath="{.data.token}" | base64 -d)

    request_body="{\"TaskId\":0,\"Name\":\"${BACKUP_TASK_NAME}\",\"Disabled\":false,\"PinToMentorNode\":false,\"FullBackupFrequency\":\"${BACKUP_FullBackupFrequency}\",\"IncrementalBackupFrequency\":\"${BACKUP_IncrementalBackupFrequency}\",\"RetentionPolicy\":{\"Disabled\":false,\"MinimumBackupAgeToKeep\":\"${BACKUP_MinimumBackupAgeToKeep}\"},\"BackupType\":\"Snapshot\",\"SnapshotSettings\":{\"CompressionLevel\":\"Optimal\",\"ExcludeIndexes\":true},\"BackupEncryptionSettings\":{\"EncryptionMode\":\"None\"},\"LocalSettings\":{\"Disabled\":true},\"S3Settings\":{\"Disabled\":true},\"GlacierSettings\":{\"Disabled\":true},\"AzureSettings\":{\"Disabled\":false,\"StorageContainer\":\"${BACKUP_AZURE_StorageContainer}\",\"AccountName\":\"${BACKUP_AZURE_AccountName}\",\"SasToken\":\"${AzureSasToken}\"},\"GoogleCloudSettings\":{\"Disabled\":true},\"FtpSettings\":{\"Disabled\":true},\"ExcludedDatabases\":[]}"

    echo "Request body: $request_body"

    curl "https://${tags[0]}.$domain_name/admin/configuration/server-wide/backup" \
      -X 'PUT' \
      -H 'content-type: application/json; charset=UTF-8' \
      --data-raw "$request_body" \
      --cert cert.pem

    echo "Period server-wide backup task created"
  else
    echo "Periodic backup task already exists"
  fi
fi
