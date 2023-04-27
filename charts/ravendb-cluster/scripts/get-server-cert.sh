#!/usr/bin/env sh

# get node tag
node_tag="$(env | grep HOSTNAME | cut -f 2 -d '-')"

# print .pfx
cat /ravendb/certs/"$node_tag".pfx
exit
