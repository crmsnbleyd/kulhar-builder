#!/bin/sh
# Report whether IMAGE:TAG exists on ghcr.io.
#
# Usage: GHCR_USER=... GHCR_TOKEN=... ghcr-tag-exists.sh OWNER/NAME TAG
#
# Exit 0 and print "exists" if the tag exists, exit 0 and print "absent" if
# the registry says it does not, and exit 2 if the registry's answer is
# anything else, so callers can fail closed.
set -eu

repo=$1
tag=$2

token=$(curl -fsS -u "$GHCR_USER:$GHCR_TOKEN" \
  "https://ghcr.io/token?service=ghcr.io&scope=repository:$repo:pull" | jq -r '.token // empty') || true
if [ -z "$token" ]; then
  echo "unknown (no registry token for $repo; the package may not exist yet)"
  exit 2
fi

status=$(curl -sS -o /dev/null -w '%{http_code}' -I \
  -H "Authorization: Bearer $token" \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
  "https://ghcr.io/v2/$repo/manifests/$tag")

case $status in
  200) echo exists ;;
  404) echo absent ;;
  *) echo "unknown (HTTP $status for $repo:$tag)"; exit 2 ;;
esac
