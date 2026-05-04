#!/bin/bash
# prod-to-dev-snapshot: restore the current prod DB snapshot into checkus_dev.
#
# Default mode is dry-run. Destructive restore requires --execute --yes.
# Run this on the CheckUS EC2 host where Docker containers are available.

set -euo pipefail

PROD_DB_EXPECTED="${PROD_DB_EXPECTED:-checkus}"
DEV_DB_EXPECTED="${DEV_DB_EXPECTED:-checkus_dev}"
PROD_CONTAINER_CANDIDATES=("checkus-blue" "checkus-green")
DEV_CONTAINER_NAME="${DEV_CONTAINER_NAME:-checkus-server-dev}"
BASE_DIR="${CHECKUS_SNAPSHOT_DIR:-$HOME/prod-to-dev-snapshots}"
LOG_DIR="$BASE_DIR/logs"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$BASE_DIR/$RUN_ID"
LOG_FILE="$LOG_DIR/${RUN_ID}.log"
MODE="dry-run"
AUTO_YES=false
STOP_DEV=true
START_DEV=true
MEMO=""
ROLLBACK_FILE=""

usage() {
    cat <<'EOF'
Usage:
  prod-to-dev-snapshot.sh [--dry-run] [--memo "reason"]
  prod-to-dev-snapshot.sh --execute --yes --memo "reason"
  prod-to-dev-snapshot.sh --rollback /path/to/dev-backup.sql.gz --yes --memo "reason"

Options:
  --dry-run          Preflight only. This is the default.
  --execute          Backup dev, stop dev app, dump prod, restore into dev, cleanup, restart dev.
  --rollback FILE    Restore a previous dev backup file into checkus_dev.
  --yes              Required for --execute and --rollback.
  --memo TEXT        Audit memo.
  --no-stop-dev      Do not stop the dev container before restore. Not recommended.
  --no-start-dev     Do not start the dev container after restore.
EOF
}

log() {
    local message="$1"
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] $message"
    if [[ -d "$LOG_DIR" ]]; then
        echo "$line" | tee -a "$LOG_FILE"
    else
        echo "$line"
    fi
}

fail() {
    log "ERROR: $1"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) MODE="dry-run"; shift ;;
            --execute) MODE="execute"; shift ;;
            --rollback)
                [[ $# -ge 2 ]] || fail "--rollback requires a file path"
                MODE="rollback"; ROLLBACK_FILE="$2"; shift 2
                ;;
            --yes|-y) AUTO_YES=true; shift ;;
            --memo|-m)
                [[ $# -ge 2 ]] || fail "--memo requires text"
                MEMO="$2"; shift 2
                ;;
            --no-stop-dev) STOP_DEV=false; shift ;;
            --no-start-dev) START_DEV=false; shift ;;
            --help|-h) usage; exit 0 ;;
            *) fail "Unknown argument: $1" ;;
        esac
    done
}

init_dirs() {
    mkdir -p "$LOG_DIR" "$RUN_DIR"
    chmod 700 "$BASE_DIR" "$RUN_DIR" "$LOG_DIR"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
}

active_prod_container() {
    local name
    for name in "${PROD_CONTAINER_CANDIDATES[@]}"; do
        if docker ps --filter "name=^/${name}$" --filter "status=running" -q | grep -q .; then
            echo "$name"
            return 0
        fi
    done
    return 1
}

container_env() {
    local container="$1"
    local key="$2"
    docker inspect "$container" \
        --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | sed -n "s/^${key}=//p" \
        | tail -n 1
}

load_credentials() {
    PROD_CONTAINER="$(active_prod_container)" || fail "No running prod container found among: ${PROD_CONTAINER_CANDIDATES[*]}"
    docker ps -a --filter "name=^/${DEV_CONTAINER_NAME}$" -q | grep -q . || fail "Dev container not found: $DEV_CONTAINER_NAME"

    PROD_HOST="$(container_env "$PROD_CONTAINER" RDS_ENDPOINT)"
    PROD_USER="$(container_env "$PROD_CONTAINER" RDS_USERNAME)"
    PROD_PASS="$(container_env "$PROD_CONTAINER" RDS_PASSWORD)"
    PROD_DB="$(container_env "$PROD_CONTAINER" RDS_DATABASE)"
    PROD_PROFILE="$(container_env "$PROD_CONTAINER" SPRING_PROFILES_ACTIVE)"

    DEV_HOST="$(container_env "$DEV_CONTAINER_NAME" RDS_ENDPOINT)"
    DEV_USER="$(container_env "$DEV_CONTAINER_NAME" RDS_USERNAME)"
    DEV_PASS="$(container_env "$DEV_CONTAINER_NAME" RDS_PASSWORD)"
    DEV_DB="$(container_env "$DEV_CONTAINER_NAME" RDS_DATABASE)"
    DEV_PROFILE="$(container_env "$DEV_CONTAINER_NAME" SPRING_PROFILES_ACTIVE)"
    DEV_SIDE_EFFECT_ENV="$(container_env "$DEV_CONTAINER_NAME" EXTERNAL_SIDE_EFFECTS_ENABLED)"
}

mysql_prod() {
    MYSQL_PWD="$PROD_PASS" mysql -h "$PROD_HOST" -u "$PROD_USER" "$PROD_DB" "$@"
}

mysql_dev() {
    MYSQL_PWD="$DEV_PASS" mysql -h "$DEV_HOST" -u "$DEV_USER" "$DEV_DB" "$@"
}

mysqldump_prod() {
    MYSQL_PWD="$PROD_PASS" mysqldump -h "$PROD_HOST" -u "$PROD_USER" "$PROD_DB" "$@"
}

mysqldump_dev() {
    MYSQL_PWD="$DEV_PASS" mysqldump -h "$DEV_HOST" -u "$DEV_USER" "$DEV_DB" "$@"
}

verify_identity() {
    [[ "$PROD_PROFILE" == "prod" ]] || fail "Prod container profile is not prod: $PROD_PROFILE"
    [[ "$DEV_PROFILE" == "dev" ]] || fail "Dev container profile is not dev: $DEV_PROFILE"
    [[ "$PROD_DB" == "$PROD_DB_EXPECTED" ]] || fail "Prod DB mismatch: expected $PROD_DB_EXPECTED, got $PROD_DB"
    [[ "$DEV_DB" == "$DEV_DB_EXPECTED" ]] || fail "Dev DB mismatch: expected $DEV_DB_EXPECTED, got $DEV_DB"
    [[ "$PROD_DB" != "$DEV_DB" ]] || fail "Source and target DB names must differ"
    [[ "${DEV_SIDE_EFFECT_ENV,,}" != "true" ]] || fail "Dev external side effects env override is true"

    local prod_current dev_current
    prod_current="$(mysql_prod -N -e "SELECT DATABASE();")"
    dev_current="$(mysql_dev -N -e "SELECT DATABASE();")"
    [[ "$prod_current" == "$PROD_DB_EXPECTED" ]] || fail "Connected prod DB mismatch: $prod_current"
    [[ "$dev_current" == "$DEV_DB_EXPECTED" ]] || fail "Connected dev DB mismatch: $dev_current"
}

table_count() {
    local db="$1"
    local host="$2"
    local user="$3"
    local pass="$4"
    MYSQL_PWD="$pass" mysql -h "$host" -u "$user" -N -e \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${db}' AND table_type='BASE TABLE';"
}

row_count_if_exists() {
    local table="$1"
    local exists
    exists="$(mysql_dev -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DEV_DB}' AND table_name='${table}';")"
    if [[ "$exists" == "1" ]]; then
        mysql_dev -N -e "SELECT COUNT(*) FROM \`${table}\`;"
    else
        echo "N/A"
    fi
}

preflight() {
    log "Mode: $MODE"
    log "Memo: ${MEMO:-"(none)"}"
    log "Prod container: $PROD_CONTAINER"
    log "Dev container: $DEV_CONTAINER_NAME"
    log "Prod target: host=$PROD_HOST user=$PROD_USER db=$PROD_DB profile=$PROD_PROFILE"
    log "Dev target: host=$DEV_HOST user=$DEV_USER db=$DEV_DB profile=$DEV_PROFILE sideEffectsEnv=${DEV_SIDE_EFFECT_ENV:-"(unset)"}"
    log "Prod base table count: $(table_count "$PROD_DB" "$PROD_HOST" "$PROD_USER" "$PROD_PASS")"
    log "Dev base table count: $(table_count "$DEV_DB" "$DEV_HOST" "$DEV_USER" "$DEV_PASS")"
    log "Dev pending_notification rows: $(row_count_if_exists pending_notification)"
    log "Dev web_push_subscription rows: $(row_count_if_exists web_push_subscription)"
}

require_confirmation() {
    if [[ "$MODE" != "dry-run" ]] && ! $AUTO_YES; then
        fail "--yes is required for $MODE"
    fi
}

backup_dev() {
    DEV_BACKUP="$RUN_DIR/dev-before-restore-${RUN_ID}.sql.gz"
    log "Backing up current dev DB to $DEV_BACKUP"
    mysqldump_dev --single-transaction --quick --routines --triggers --events --set-gtid-purged=OFF | gzip > "$DEV_BACKUP"
    chmod 600 "$DEV_BACKUP"
    log "Dev backup complete: $DEV_BACKUP"
}

dump_prod() {
    PROD_DUMP="$RUN_DIR/prod-${RUN_ID}.sql.gz"
    log "Dumping prod DB read-only snapshot to $PROD_DUMP"
    mysqldump_prod --single-transaction --quick --routines --triggers --events --set-gtid-purged=OFF | gzip > "$PROD_DUMP"
    chmod 600 "$PROD_DUMP"
    log "Prod dump complete: $PROD_DUMP"
}

stop_dev_app() {
    if $STOP_DEV; then
        if docker ps --filter "name=^/${DEV_CONTAINER_NAME}$" --filter "status=running" -q | grep -q .; then
            log "Stopping dev app container: $DEV_CONTAINER_NAME"
            docker stop "$DEV_CONTAINER_NAME" >/dev/null
        else
            log "Dev app container is already stopped: $DEV_CONTAINER_NAME"
        fi
    else
        log "Skipping dev app stop by request"
    fi
}

start_dev_app() {
    if $START_DEV; then
        if docker ps --filter "name=^/${DEV_CONTAINER_NAME}$" --filter "status=running" -q | grep -q .; then
            log "Dev app container is already running: $DEV_CONTAINER_NAME"
        else
            log "Starting dev app container: $DEV_CONTAINER_NAME"
            docker start "$DEV_CONTAINER_NAME" >/dev/null
        fi
    else
        log "Skipping dev app start by request"
    fi
}

drop_dev_tables() {
    local drop_file="$RUN_DIR/drop-dev-tables.sql"
    log "Generating DROP statements for current dev tables"
    {
        echo "SET FOREIGN_KEY_CHECKS=0;"
        MYSQL_PWD="$DEV_PASS" mysql -h "$DEV_HOST" -u "$DEV_USER" -N -e \
            "SELECT CONCAT('DROP TABLE IF EXISTS \`', TABLE_NAME, '\`;') FROM information_schema.tables WHERE table_schema='${DEV_DB}' AND table_type='BASE TABLE' ORDER BY TABLE_NAME;"
        echo "SET FOREIGN_KEY_CHECKS=1;"
    } > "$drop_file"
    chmod 600 "$drop_file"
    log "Dropping current dev tables"
    MYSQL_PWD="$DEV_PASS" mysql -h "$DEV_HOST" -u "$DEV_USER" "$DEV_DB" < "$drop_file"
}

restore_prod_into_dev() {
    log "Restoring prod dump into dev DB"
    gunzip -c "$PROD_DUMP" | MYSQL_PWD="$DEV_PASS" mysql -h "$DEV_HOST" -u "$DEV_USER" "$DEV_DB"
    log "Restore import complete"
}

table_exists_dev() {
    local table="$1"
    [[ "$(mysql_dev -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DEV_DB}' AND table_name='${table}';")" == "1" ]]
}

post_restore_cleanup() {
    log "Running post-restore dev cleanup"
    if table_exists_dev pending_notification; then
        local pending_before
        pending_before="$(mysql_dev -N -e "SELECT COUNT(*) FROM pending_notification WHERE status='PENDING';")"
        mysql_dev -e "UPDATE pending_notification SET status='CANCELLED', result_message='[dev snapshot] cancelled to prevent external send', processed_at=UTC_TIMESTAMP() WHERE status='PENDING';"
        log "pending_notification PENDING cancelled: $pending_before"
    else
        log "pending_notification table not found; skipped"
    fi

    if table_exists_dev web_push_subscription; then
        local push_before
        push_before="$(mysql_dev -N -e "SELECT COUNT(*) FROM web_push_subscription;")"
        mysql_dev -e "DELETE FROM web_push_subscription;"
        log "web_push_subscription deleted: $push_before"
    else
        log "web_push_subscription table not found; skipped"
    fi
}

verify_after_restore() {
    log "Verifying restored dev DB"
    verify_identity
    log "Restored dev base table count: $(table_count "$DEV_DB" "$DEV_HOST" "$DEV_USER" "$DEV_PASS")"
    log "Restored dev pending_notification rows: $(row_count_if_exists pending_notification)"
    log "Restored dev web_push_subscription rows: $(row_count_if_exists web_push_subscription)"
}

health_check_dev() {
    if $START_DEV; then
        log "Waiting for dev health check"
        local attempt
        for attempt in $(seq 1 30); do
            if curl -fsS "http://localhost:8083/public/health" >/dev/null 2>&1; then
                log "Dev health check passed"
                return 0
            fi
            sleep 2
        done
        fail "Dev health check failed after restart"
    fi
}

rollback_dev() {
    [[ -n "$ROLLBACK_FILE" ]] || fail "--rollback requires a backup file"
    [[ -f "$ROLLBACK_FILE" ]] || fail "Rollback file not found: $ROLLBACK_FILE"
    log "Rolling back dev DB from $ROLLBACK_FILE"
    stop_dev_app
    drop_dev_tables
    gunzip -c "$ROLLBACK_FILE" | MYSQL_PWD="$DEV_PASS" mysql -h "$DEV_HOST" -u "$DEV_USER" "$DEV_DB"
    post_restore_cleanup
    start_dev_app
    health_check_dev
    log "Rollback complete"
}

execute_restore() {
    backup_dev
    stop_dev_app
    dump_prod
    drop_dev_tables
    restore_prod_into_dev
    post_restore_cleanup
    verify_after_restore
    start_dev_app
    health_check_dev
    log "Restore complete"
    log "Dev backup for rollback: $DEV_BACKUP"
}

main() {
    parse_args "$@"
    init_dirs
    require_cmd docker
    require_cmd mysql
    require_cmd mysqldump
    require_cmd gzip
    require_cmd gunzip
    require_cmd curl
    load_credentials
    verify_identity
    preflight
    require_confirmation

    case "$MODE" in
        dry-run)
            log "[DRY-RUN] No changes made."
            ;;
        execute)
            execute_restore
            ;;
        rollback)
            rollback_dev
            ;;
        *)
            fail "Unsupported mode: $MODE"
            ;;
    esac
}

main "$@"
