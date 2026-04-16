#!/bin/bash
# Unblock endpoint(s) at nginx level
# Usage: ./unblock-endpoint.sh              (unblock all)
#        ./unblock-endpoint.sh "/api/path"   (unblock specific)

set -e

CONF="/home/ubuntu/checkus-infra/nginx/blocked-endpoints.conf"
HEADER="# Emergency endpoint kill switch
# Usage: ./block-endpoint.sh \"/api/path\" \"reason\"
# This file is included by nginx.conf before the main location block.
# When empty, no endpoints are blocked."

if [ -z "$1" ]; then
    echo "$HEADER" > "$CONF"
    echo "All endpoints unblocked"
else
    # Remove the comment line + location block for the given endpoint
    sed -i "/$(echo "$1" | sed 's/\//\\\//g')/,/^}/d" "$CONF"
    echo "Unblocked: $1"
fi

# Validate and reload
docker exec nginx nginx -t && docker exec nginx nginx -s reload
