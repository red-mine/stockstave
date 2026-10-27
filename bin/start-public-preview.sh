#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

PORT="${STOCK_PREVIEW_PORT:-3000}"
DATABASE="${STOCK_DATABASE:-$REPO_DIR/tmp/ui-stock.sqlite3}"
ISOLATED_DATABASE="$REPO_DIR/tmp/ui-stock.sqlite3"
STATUS_PATH="$REPO_DIR/tmp/public-preview.json"
LOCK_PATH="$REPO_DIR/tmp/public-preview-start.lock"
TUNNEL_OUT="$REPO_DIR/tmp/cloudflared-out.log"
TUNNEL_ERR="$REPO_DIR/tmp/cloudflared-err.log"
SERVER_OUT="$REPO_DIR/tmp/public-preview-server-out.log"
SERVER_ERR="$REPO_DIR/tmp/public-preview-server-err.log"
CLOUDFLARED="${CLOUDFLARED:-cloudflared}"
AREAS=(sz sh bj)

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ -n "${TUNNEL_PID:-}" ]]; then
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
  fi
  # The lock is a directory (acquire_lock mkdirs it); `rm -f` cannot unlink a
  # directory, so a run that used rm -f leaked the lock and blocked the next
  # start for five minutes.
  rmdir "$LOCK_PATH" 2>/dev/null || true
}

trap cleanup EXIT

acquire_lock() {
  if ! mkdir "$LOCK_PATH" 2>/dev/null; then
    if [[ "$(find "$LOCK_PATH" -mmin +5 2>/dev/null)" ]]; then
      rmdir "$LOCK_PATH" 2>/dev/null || true
      mkdir "$LOCK_PATH" 2>/dev/null || {
        echo "A public preview start is already running" >&2
        exit 1
      }
    else
      echo "A public preview start is already running" >&2
      exit 1
    fi
  fi
}

acquire_lock

if [[ "$DATABASE" != "$ISOLATED_DATABASE" ]]; then
  echo "Public preview must use the isolated database: $ISOLATED_DATABASE" >&2
  exit 1
fi

if ! command -v "$CLOUDFLARED" >/dev/null 2>&1; then
  echo "cloudflared not found. Install it first:" >&2
  echo "  https://github.com/cloudflare/cloudflared#installing-cloudflared" >&2
  exit 1
fi

if [[ ! -f "$DATABASE" ]]; then
  echo "Isolated database not found: $DATABASE" >&2
  echo "Run: STOCK_DATABASE=$DATABASE bundle exec rails db:prepare" >&2
  exit 1
fi

export STOCK_DATABASE="$DATABASE"
export RAILS_ENV="production"
export RACK_ENV="production"
export RAILS_LOG_LEVEL="warn"
export RAILS_SERVE_STATIC_FILES="1"
# Production insists on a secret_key_base, but nothing in this app signs a
# session or a cookie and no route writes, so a per-run value satisfies the boot
# check without leaving a secret on disk or anywhere near the repository.
export SECRET_KEY_BASE="$(openssl rand -hex 64)"

# Production turns off config.assets.compile, so no page renders until the
# fingerprinted bundle exists. The monitor re-runs this script whenever the
# preview looks unhealthy, so rebuild only when the bundle is missing or older
# than its sources rather than on every restart.
assets_manifest=$(ls public/assets/.manifest.json public/assets/.sprockets-manifest-*.json 2>/dev/null | head -1 || true)
if [[ -z "$assets_manifest" ]] ||
   [[ -n "$(find app/assets app/javascript config/importmap.rb -newer "$assets_manifest" -print -quit 2>/dev/null)" ]]; then
  echo "Precompiling assets for the production preview"
  bundle exec rails assets:precompile
fi

# Refuse to stop a process this script did not start. Puma rewrites its own
# process title on Linux, so identify a process by the executable it is running
# and the directory it was started from; a rails_pid this script recorded
# earlier is accepted as proof of ownership too, because the repository
# directory has moved before and a stale cwd would otherwise never match.
# Mirrors Stop-VerifiedProcess in start-public-preview.ps1.
recorded_pid() {
  ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch(ARGV[1], "")' \
    "$STATUS_PATH" "$1" 2>/dev/null || true
}

process_executable() {
  basename "$(readlink -f "/proc/$1/exe" 2>/dev/null || true)" 2>/dev/null || true
}

refuse_unexpected() {
  local pid="$1" executable="$2" what="$3"
  echo "Refusing to stop unexpected process $pid ($executable) $what" >&2
  echo "Stop it yourself, or remove $STATUS_PATH if it is a stale preview." >&2
  exit 1
}

# Stop any existing Rails server on the same port.
recorded_rails_pid="$(recorded_pid rails_pid)"
while read -r pid; do
  [[ -n "$pid" ]] || continue
  executable="$(process_executable "$pid")"
  working_directory="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
  if [[ "$executable" != ruby* ]]; then
    refuse_unexpected "$pid" "$executable" "listening on port $PORT"
  fi
  if [[ "$working_directory" != "$REPO_DIR" && "$pid" != "$recorded_rails_pid" ]]; then
    refuse_unexpected "$pid" "$executable" "listening on port $PORT from $working_directory"
  fi
  echo "Stopping existing Rails server $pid on port $PORT"
  kill "$pid" 2>/dev/null || true
done < <(lsof -ti tcp:"$PORT" -sTCP:LISTEN 2>/dev/null || true)
sleep 2

# Stop any existing cloudflared tunnel.
while read -r pid; do
  [[ -n "$pid" ]] || continue
  executable="$(process_executable "$pid")"
  if [[ "$executable" != cloudflared* ]]; then
    refuse_unexpected "$pid" "$executable" "matching the tunnel pattern for port $PORT"
  fi
  echo "Stopping existing cloudflared tunnel $pid"
  kill "$pid" 2>/dev/null || true
done < <(pgrep -f "cloudflared.*tunnel.*127.0.0.1:$PORT" 2>/dev/null || true)
sleep 1

rm -f "$TUNNEL_OUT" "$TUNNEL_ERR" "$SERVER_OUT" "$SERVER_ERR"

# Start cloudflared tunnel.
"$CLOUDFLARED" tunnel --no-autoupdate --url "http://127.0.0.1:$PORT" --http-host-header localhost \
  >"$TUNNEL_OUT" 2>"$TUNNEL_ERR" &
TUNNEL_PID=$!

PUBLIC_URL=""
for _ in $(seq 1 30); do
  # cloudflared logs the issued URL to stderr; read both streams like the PowerShell launcher.
  # The issued URL is the only trycloudflare.com address that is not followed by a
  # path. A failed request logs "https://api.trycloudflare.com/tunnel", and
  # reading that as the preview's address sends every later check to the
  # Cloudflare API instead of the preview -- which is how a tunnel that never
  # started looked like a preview that would not answer.
  PUBLIC_URL=$(grep -hoE 'https://[a-z0-9-]+\.trycloudflare\.com([^[:alnum:]\/-]|$)' "$TUNNEL_OUT" "$TUNNEL_ERR" 2>/dev/null \
    | head -1 | sed -E 's/([^[:alnum:]\/-])$//' || true)
  if [[ -n "$PUBLIC_URL" ]]; then
    break
  fi
  sleep 2
done

if [[ -z "$PUBLIC_URL" ]]; then
  echo "Cloudflare did not issue a public URL within 60 seconds" >&2
  exit 1
fi

# Start Rails server.
bundle exec rails server -p "$PORT" -b 127.0.0.1 >"$SERVER_OUT" 2>"$SERVER_ERR" &
SERVER_PID=$!

# Wait for Rails to listen.
for _ in $(seq 1 40); do
  if lsof -ti tcp:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    break
  fi
  sleep 3
done

if ! lsof -ti tcp:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Rails did not listen on port $PORT within 120 seconds" >&2
  exit 1
fi

# Health checks.
health_ok() {
  local url="$1"
  local body
  body=$(curl -fsS --max-time 15 "$url/preview-health" 2>/dev/null) || return 1
  [[ "$body" == *'"status":"ready"'* ]] && [[ "$body" == *'"environment":"production"'* ]]
}

markets_ok() {
  local base="$1"
  for area in "${AREAS[@]}"; do
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$base/$area" 2>/dev/null || echo 0)
    if [[ "$code" != "200" ]]; then
      echo "$area=$code"
      return 1
    fi
  done
}

HEALTHY=false
for _ in $(seq 1 18); do
  if health_ok "http://127.0.0.1:$PORT" && health_ok "$PUBLIC_URL" && \
     markets_ok "http://127.0.0.1:$PORT" && markets_ok "$PUBLIC_URL"; then
    HEALTHY=true
    break
  fi
  sleep 5
done

if [[ "$HEALTHY" != "true" ]]; then
  echo "Preview market health check failed" >&2
  exit 1
fi

# Write status file.
# Without -sTCP:LISTEN the tunnel's client socket sorts first and the status file
# records cloudflared as rails_pid, which the status script then reads as dead.
RAILS_PID=$(lsof -ti tcp:"$PORT" -sTCP:LISTEN | head -1)
cat >"$STATUS_PATH" <<EOF
{
  "url": "$PUBLIC_URL",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "rails_pid": $RAILS_PID,
  "tunnel_pid": $TUNNEL_PID,
  "database": "$DATABASE",
  "port": $PORT,
  "environment": "production",
  "log_level": "warn"
}
EOF

echo "Public preview running at $PUBLIC_URL"
echo "Local: http://127.0.0.1:$PORT"
echo "Status: $STATUS_PATH"

# Keep running until interrupted.
wait "$SERVER_PID"
