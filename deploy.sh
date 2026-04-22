#!/bin/bash
set -euo pipefail

# =============================================================
# CheckUS Blue-Green Deploy Script
# Usage: ./deploy.sh
# Requires: environment variables exported by CI/CD before calling
# =============================================================

NO_SWITCH=false
if [ "${1:-}" = "--no-switch" ]; then
    NO_SWITCH=true
fi

INFRA_DIR="$HOME/checkus-infra"
ACTIVE_FILE="$INFRA_DIR/active-color"
ECR_IMAGE="855673866113.dkr.ecr.ap-northeast-2.amazonaws.com/checkus/server:latest"
HEALTH_PATH="/public/health"
MAX_HEALTH_ATTEMPTS=90
HEALTH_INTERVAL=5

cd "$INFRA_DIR"

# ---- Determine current active and target ----
if [ -f "$ACTIVE_FILE" ]; then
    CURRENT=$(cat "$ACTIVE_FILE")
else
    CURRENT="none"
fi

if [ "$CURRENT" = "blue" ]; then
    TARGET="green"
    TARGET_PORT=8082
elif [ "$CURRENT" = "green" ]; then
    TARGET="blue"
    TARGET_PORT=8081
else
    TARGET="blue"
    TARGET_PORT=8081
fi

echo "=========================================="
echo "Blue-Green Deploy"
echo "  Current active: $CURRENT"
echo "  Deploying to:   $TARGET (port $TARGET_PORT)"
echo "=========================================="

# ---- Pull latest image ----
echo "[1/6] Pulling latest image..."
docker pull "$ECR_IMAGE"

# ---- Stop the target (standby) container if running ----
echo "[2/6] Stopping target container (checkus-$TARGET) if running..."
docker compose -f compose.yml stop "checkus-$TARGET" 2>/dev/null || true
docker compose -f compose.yml rm -f "checkus-$TARGET" 2>/dev/null || true

# ---- Start the target container with new image ----
echo "[3/6] Starting checkus-$TARGET..."
docker compose -f compose.yml up -d "checkus-$TARGET"

# ---- Health check on the target container ----
echo "[4/6] Waiting for checkus-$TARGET to become healthy..."
for i in $(seq 1 $MAX_HEALTH_ATTEMPTS); do
    if curl -sf "http://localhost:$TARGET_PORT$HEALTH_PATH" > /dev/null 2>&1; then
        echo "  checkus-$TARGET is healthy! (attempt $i)"
        break
    fi
    if [ "$i" -eq "$MAX_HEALTH_ATTEMPTS" ]; then
        echo "ERROR: checkus-$TARGET did not become healthy within $((MAX_HEALTH_ATTEMPTS * HEALTH_INTERVAL))s"
        echo "Rolling back: stopping checkus-$TARGET"
        docker compose -f compose.yml stop "checkus-$TARGET"
        exit 1
    fi
    sleep $HEALTH_INTERVAL
done

# ---- Switch or stop here ----
if [ "$NO_SWITCH" = true ]; then
    echo "[5/6] --no-switch: skipping nginx switch"
    echo "[6/6] Target $TARGET is running on port $TARGET_PORT — verify manually"
    echo ""
    echo "=========================================="
    echo "Deploy complete (NO SWITCH)"
    echo "  $TARGET is ready on port $TARGET_PORT"
    echo "  Current active: $CURRENT"
    echo "  To switch: ./switch.sh"
    echo "=========================================="
    exit 0
fi

# ---- Switch nginx to point to the new target ----
echo "[5/6] Switching nginx to $TARGET..."
cp "$INFRA_DIR/nginx/$TARGET.conf" "$INFRA_DIR/nginx/active.conf"
docker exec nginx nginx -s reload

echo "$TARGET" > "$ACTIVE_FILE"

# ---- Stop the old active container ----
if [ "$CURRENT" != "none" ]; then
    echo "[6/6] Stopping old container (checkus-$CURRENT)..."
    sleep 5
    docker compose -f compose.yml stop "checkus-$CURRENT"
else
    echo "[6/6] No old container to stop (first deploy)."
fi

# ---- Cleanup ----
docker image prune -f

echo "=========================================="
echo "Deploy complete! Active: $TARGET"
echo "=========================================="
