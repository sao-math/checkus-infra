#!/bin/bash
# checkus-sql: prod DB 직접 조작 안전 래퍼
# 사용법:
#   checkus-sql "UPDATE table SET col='val' WHERE id=1"
#   checkus-sql --yes "DELETE FROM table WHERE id=1"    # 확인 없이 실행
#   checkus-sql --dry-run "UPDATE table SET col='val'"   # 미리보기만
#   checkus-sql --file script.sql                        # 파일 실행
#
# SELECT는 래퍼 없이 바로 실행됨 (읽기 전용)

set -euo pipefail

LOG_DIR="$HOME/db-ops-log"
mkdir -p "$LOG_DIR"

# --- DB 접속 정보 ---
get_db_credentials() {
    local container
    container=$(docker ps --filter "name=checkus-blue" --filter "status=running" -q 2>/dev/null)
    if [ -z "$container" ]; then
        container=$(docker ps --filter "name=checkus-green" --filter "status=running" -q 2>/dev/null)
    fi
    if [ -z "$container" ]; then
        echo "ERROR: No active checkus container found" >&2
        exit 1
    fi

    DB_PASSWORD=$(docker exec "$container" env 2>/dev/null | grep RDS_PASSWORD | cut -d= -f2)
    DB_HOST="checkus-mysql.cj6wkcia26d4.ap-northeast-2.rds.amazonaws.com"
    DB_USER="checkus-user"
    DB_NAME="checkus"
}

run_mysql() {
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" "$@" 2>/dev/null
}

# --- 인자 파싱 ---
AUTO_YES=false
DRY_RUN=false
SQL_FILE=""
SQL=""
MEMO=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y) AUTO_YES=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --file|-f) SQL_FILE="$2"; shift 2 ;;
        --memo|-m) MEMO="$2"; shift 2 ;;
        *) SQL="$1"; shift ;;
    esac
done

if [ -n "$SQL_FILE" ]; then
    if [ ! -f "$SQL_FILE" ]; then
        echo "ERROR: File not found: $SQL_FILE" >&2
        exit 1
    fi
    SQL=$(cat "$SQL_FILE")
fi

if [ -z "$SQL" ]; then
    echo "Usage: checkus-sql [--yes] [--dry-run] [--memo 'reason'] \"SQL\""
    echo "       checkus-sql --file script.sql"
    exit 1
fi

get_db_credentials

# --- SELECT는 바로 실행 ---
SQL_UPPER=$(echo "$SQL" | tr '[:lower:]' '[:upper:]' | sed 's/^[[:space:]]*//')
if [[ "$SQL_UPPER" == SELECT* ]] || [[ "$SQL_UPPER" == SHOW* ]] || [[ "$SQL_UPPER" == DESCRIBE* ]] || [[ "$SQL_UPPER" == EXPLAIN* ]]; then
    run_mysql -e "$SQL"
    exit 0
fi

# --- 변경 쿼리: 안전 래퍼 ---
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
LOG_FILE="$LOG_DIR/${TIMESTAMP}.log"

echo "============================================"
echo "  checkus-sql — Safe DB Operation Wrapper"
echo "============================================"
echo ""
echo "SQL:"
echo "  $SQL"
echo ""

# 영향 받는 행 수 미리보기 (UPDATE/DELETE → SELECT COUNT 변환)
PREVIEW_COUNT=""
if echo "$SQL_UPPER" | grep -qE '^(UPDATE|DELETE)'; then
    # WHERE 절 추출
    WHERE_CLAUSE=$(echo "$SQL" | grep -ioP 'WHERE\s+.*' || echo "")
    # 테이블명 추출
    if echo "$SQL_UPPER" | grep -qE '^UPDATE'; then
        TABLE=$(echo "$SQL" | sed -n 's/^[Uu][Pp][Dd][Aa][Tt][Ee]\s\+\([^ ]*\).*/\1/p')
    else
        TABLE=$(echo "$SQL" | sed -n 's/^[Dd][Ee][Ll][Ee][Tt][Ee]\s\+[Ff][Rr][Oo][Mm]\s\+\([^ ]*\).*/\1/p')
    fi

    if [ -n "$TABLE" ] && [ -n "$WHERE_CLAUSE" ]; then
        PREVIEW_COUNT=$(run_mysql -N -e "SELECT COUNT(*) FROM $TABLE $WHERE_CLAUSE;" 2>/dev/null || echo "?")
        echo "Affected rows (estimate): $PREVIEW_COUNT"
        echo ""
    fi
fi

# dry-run이면 여기서 중단
if $DRY_RUN; then
    echo "[DRY-RUN] No changes made."
    exit 0
fi

# 확인 프롬프트
if ! $AUTO_YES; then
    read -rp "Execute? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Cancelled."
        exit 0
    fi
fi

# before snapshot (affected rows)
BEFORE_SNAPSHOT=""
if [ -n "$TABLE" ] && [ -n "$WHERE_CLAUSE" ]; then
    BEFORE_SNAPSHOT=$(run_mysql -e "SELECT * FROM $TABLE $WHERE_CLAUSE LIMIT 20;" 2>/dev/null || echo "(snapshot failed)")
fi

# 실행
echo "Executing..."
RESULT=$(run_mysql -v -e "$SQL" 2>&1)
EXIT_CODE=$?

# after snapshot
AFTER_SNAPSHOT=""
if [ -n "$TABLE" ] && [ -n "$WHERE_CLAUSE" ]; then
    AFTER_COUNT=$(run_mysql -N -e "SELECT COUNT(*) FROM $TABLE $WHERE_CLAUSE;" 2>/dev/null || echo "?")
    AFTER_SNAPSHOT=$(run_mysql -e "SELECT * FROM $TABLE $WHERE_CLAUSE LIMIT 20;" 2>/dev/null || echo "(snapshot failed)")
fi

# 로그 기록
{
    echo "=== DB Operation Log ==="
    echo "Timestamp: $TIMESTAMP"
    echo "User: $(whoami)"
    echo "Memo: ${MEMO:-"(none)"}"
    echo ""
    echo "--- SQL ---"
    echo "$SQL"
    echo ""
    echo "--- Result ---"
    echo "Exit code: $EXIT_CODE"
    echo "$RESULT"
    echo ""
    if [ -n "$PREVIEW_COUNT" ]; then
        echo "--- Row Count ---"
        echo "Before: $PREVIEW_COUNT"
        echo "After: ${AFTER_COUNT:-?}"
        echo ""
    fi
    if [ -n "$BEFORE_SNAPSHOT" ]; then
        echo "--- Before Snapshot (first 20 rows) ---"
        echo "$BEFORE_SNAPSHOT"
        echo ""
    fi
    if [ -n "$AFTER_SNAPSHOT" ]; then
        echo "--- After Snapshot (first 20 rows) ---"
        echo "$AFTER_SNAPSHOT"
        echo ""
    fi
} > "$LOG_FILE"

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "Done. ${PREVIEW_COUNT:+($PREVIEW_COUNT → ${AFTER_COUNT:-?} rows)}"
    echo "Log: $LOG_FILE"
else
    echo "FAILED (exit code: $EXIT_CODE)"
    echo "Log: $LOG_FILE"
fi
