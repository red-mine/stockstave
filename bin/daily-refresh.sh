#!/usr/bin/env bash
# Linux equivalent of bin/daily-refresh.ps1: runs `rails daily_refresh` with
# logging, log rotation, and the same STOCK_DATABASE/STOCK_REFRESH_SOURCE
# environment contract the Rake task and RefreshRun status files expect.
set -euo pipefail

# Captured before the option loop below consumes "$@", so the flock re-exec can
# hand the original arguments to the child that actually does the work.
ORIGINAL_ARGS=("$@")

DATABASE_PATH=""
RUN_SOURCE="manual"
LOG_RETENTION=30
TDX_DATA_PATH="${TDX_DATA_PATH:-}"
SKIP_TDX_UPDATE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --database) DATABASE_PATH="$2"; shift 2 ;;
    --source)
      case "$2" in
        manual|scheduled) RUN_SOURCE="$2" ;;
        *) echo "Invalid --source '$2'; expected manual or scheduled" >&2; exit 1 ;;
      esac
      shift 2 ;;
    --log-retention) LOG_RETENTION="$2"; shift 2 ;;
    --tdx-data-path) TDX_DATA_PATH="$2"; shift 2 ;;
    --skip-tdx-update) SKIP_TDX_UPDATE=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export STOCK_REFRESH_STARTED_AT="$STARTED_AT"

# The whole run has to be serialized. Two schedulers (or a manual run racing a
# scheduled one) used to share tmp/tdx-update/hsjday.zip.part and corrupt each
# other's archive, and the lock the Rails task takes is only held once Rails has
# already booted — too late to protect the download. Re-exec under flock so a
# second copy skips instead of racing the first one.
LOCK_PATH="${STOCK_REFRESH_LOCK:-$REPO_ROOT/tmp/daily-refresh.lock}"
if [[ -z "${STAVE_REFRESH_LOCK_HELD:-}" ]]; then
  if command -v flock >/dev/null 2>&1; then
    mkdir -p "$(dirname "$LOCK_PATH")"
    export STAVE_REFRESH_LOCK_HELD=1
    set +e
    flock --exclusive --nonblock --conflict-exit-code 99 "$LOCK_PATH" "$0" "${ORIGINAL_ARGS[@]}"
    lock_status=$?
    set -e
    if [[ "$lock_status" -ne 99 ]]; then
      exit "$lock_status"
    fi
    echo "[$STARTED_AT] Another Stock Stave refresh already holds the lock; skipping this run" >&2
    exit 0
  fi
  echo "[$STARTED_AT] flock is unavailable; running without the concurrency lock" >&2
fi

DATABASE_PATH="${DATABASE_PATH:-$REPO_ROOT/db/stock.sqlite3}"
TDX_DATA_PATH="${TDX_DATA_PATH:-$REPO_ROOT/vipdoc}"
LOG_DIR="$REPO_ROOT/log/daily-refresh"
LOG_FILE="$LOG_DIR/latest.log"
ARCHIVE_LOG="$LOG_DIR/refresh-$(date -u +%Y%m%d-%H%M%S)-$$.log"

resolve_ruby() {
  if [[ -n "${RUBY_BIN:-}" ]]; then
    echo "$RUBY_BIN"
  elif command -v ruby >/dev/null 2>&1; then
    command -v ruby
  elif [[ -x "$HOME/.rbenv/shims/ruby" ]]; then
    echo "$HOME/.rbenv/shims/ruby"
  else
    echo ""
  fi
}

RUBY_BIN="$(resolve_ruby)"
if [[ -z "$RUBY_BIN" || ! -x "$RUBY_BIN" ]]; then
  echo "Ruby executable not found (set RUBY_BIN to override)" >&2
  exit 1
fi
if [[ ! -f "$DATABASE_PATH" ]]; then
  echo "Stock database not found: $DATABASE_PATH" >&2
  exit 1
fi

# Keep the status files honest when a run dies before Rails ever boots. The
# Rails stage writes "failed" itself, but it never runs when the download fails,
# and leaving the previous "succeeded" in place made the website report healthy
# data while it silently aged.
record_refresh_failure() {
  local message="$1"
  export STOCK_REFRESH_ERROR="$message"
  if "$RUBY_BIN" bin/rails record_refresh_failure >/dev/null 2>&1; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Recorded refresh failure in the status files" | tee -a "$LOG_FILE"
  else
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Could not record the refresh failure in the status files" | tee -a "$LOG_FILE"
  fi
}

mkdir -p "$LOG_DIR"
export STOCK_DATABASE="$DATABASE_PATH"
export STOCK_REFRESH_SOURCE="$RUN_SOURCE"
export TDX_DATA_PATH
export RAILS_ENV="development"
export RACK_ENV="development"

cd "$REPO_ROOT"

: > "$LOG_FILE"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting daily refresh" | tee -a "$LOG_FILE"

set +e
if [[ "$SKIP_TDX_UPDATE" == true ]]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Skipping TongdaXin download by request" | tee -a "$LOG_FILE"
else
  "$REPO_ROOT/bin/update-tdx-data.sh" --data-path "$TDX_DATA_PATH" 2>&1 | tee -a "$LOG_FILE"
  update_status="${PIPESTATUS[0]}"
  if [[ "$update_status" -ne 0 ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] TongdaXin update failed with exit code $update_status" | tee -a "$LOG_FILE"
    record_refresh_failure "TongdaXin data update failed (exit code $update_status)"
    cp "$LOG_FILE" "$ARCHIVE_LOG"
    exit "$update_status"
  fi
fi
"$RUBY_BIN" bin/rails daily_refresh 2>&1 | tee -a "$LOG_FILE"
status="${PIPESTATUS[0]}"
set -e

if [[ "$status" -eq 0 ]]; then
  # The public preview serves an isolated database copy that nothing else
  # writes, so without this mirror the public site keeps serving whatever
  # that copy held when it was seeded. A mirror failure is not a refresh
  # failure: the data is current either way, so it is logged loudly and the
  # run still counts as successful.
  "$RUBY_BIN" bin/rails mirror_preview_database 2>&1 | tee -a "$LOG_FILE"
  mirror_status="${PIPESTATUS[0]}"
  set -e
  if [[ "$mirror_status" -ne 0 ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WARNING: could not mirror the public preview database; the public site may serve stale data" | tee -a "$LOG_FILE"
  fi
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Daily refresh succeeded" | tee -a "$LOG_FILE"
else
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Daily refresh failed with exit code $status" | tee -a "$LOG_FILE"
fi

cp "$LOG_FILE" "$ARCHIVE_LOG"

keep=$(( LOG_RETENTION > 1 ? LOG_RETENTION : 1 ))
# shellcheck disable=SC2012
ls -1t "$LOG_DIR"/refresh-*.log 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -f

exit "$status"
