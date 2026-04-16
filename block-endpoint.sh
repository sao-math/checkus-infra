#!/bin/bash
# Block a specific API endpoint at nginx level (no app deploy needed)
# Usage: ./block-endpoint.sh "/api/tasks/student" "connection leak in createTaskInstance"

set -e

ENDPOINT=$1
REASON=$2
CONF="/home/ubuntu/checkus-infra/nginx/blocked-endpoints.conf"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M')

if [ -z "$ENDPOINT" ]; then
    echo "Usage: $0 <endpoint-path> <reason>"
    echo "Example: $0 \"/api/tasks/student\" \"connection leak\""
    exit 1
fi

if [ -z "$REASON" ]; then
    REASON="manual block"
fi

cat >> "$CONF" <<EOF
# [$TIMESTAMP] $REASON
location = $ENDPOINT {
    default_type application/json;
    return 503 '{"code":"SERVICE_TEMPORARILY_UNAVAILABLE","message":"일시적으로 사용할 수 없습니다"}';
}
EOF

# Validate and reload
docker exec nginx nginx -t && docker exec nginx nginx -s reload
echo "BLOCKED: $ENDPOINT ($REASON)"
echo "Unblock with: ./unblock-endpoint.sh \"$ENDPOINT\""
