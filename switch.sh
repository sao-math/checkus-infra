#!/bin/bash
set -euo pipefail

# =============================================================
# CheckUS Blue-Green Switch Script
# Switches nginx to the standby container and stops the old one.
#
# Usage: ./switch.sh          (auto-detect standby)
#        ./switch.sh blue     (force switch to blue)
#        ./switch.sh green    (force switch to green)
# =============================================================

INFRA_DIR="$HOME/checkus-infra"
ACTIVE_FILE="$INFRA_DIR/active-color"
HEALTH_PATH="/public/health"

cd "$INFRA_DIR"

# ---- Determine current and target ----
if [ -f "$ACTIVE_FILE" ]; then
    CURRENT=$(cat "$ACTIVE_FILE")
else
    CURRENT="none"
fi

if [ -n "${1:-}" ]; then
    TARGET="$1"
else
    if [ "$CURRENT" = "blue" ]; then
        TARGET="green"
    else
        TARGET="blue"
    fi
fi

if [ "$TARGET" = "blue" ]; then
    TARGET_PORT=8081
else
    TARGET_PORT=8082
fi

echo "=========================================="
echo "Blue-Green Switch"
echo "  Current active: $CURRENT"
echo "  Switching to:   $TARGET (port $TARGET_PORT)"
echo "=========================================="

# ---- Verify target is healthy before switching ----
echo "[1/3] Verifying $TARGET is healthy..."
if ! curl -sf "http://localhost:$TARGET_PORT$HEALTH_PATH" > /dev/null 2>&1; then
    echo "ERROR: checkus-$TARGET is not healthy on port $TARGET_PORT"
    echo "Cannot switch. Run deploy.sh first."
    exit 1
fi
echo "  checkus-$TARGET is healthy!"

# ---- Switch nginx ----
echo "[2/3] Switching nginx to $TARGET..."
cp "$INFRA_DIR/nginx/$TARGET.conf" "$INFRA_DIR/nginx/active.conf"
docker exec nginx nginx -s reload

echo "$TARGET" > "$ACTIVE_FILE"

# ---- Stop old container ----
if [ "$CURRENT" != "none" ] && [ "$CURRENT" != "$TARGET" ]; then
    echo "[3/3] Stopping old container (checkus-$CURRENT)..."
    sleep 5
    docker compose -f compose.yml stop "checkus-$CURRENT"
else
    echo "[3/3] No old container to stop."
fi

docker image prune -f

echo "=========================================="
echo "Switch complete! Active: $TARGET"
echo "=========================================="
