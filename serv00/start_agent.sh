#!/bin/sh
# serv00 FreeBSD launcher: mirror start_agent.ps1 (no keepalive/cron).
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

PYTHON_PATH=${PYTHON_PATH:-}
ENV_FILE=$PROJECT_ROOT/.env
LOG_FILE=$PROJECT_ROOT/arena_farmer.log
HISTORY_DB=$PROJECT_ROOT/arena_history.sqlite3
WORKER_TARGET=18
BEACON_POLICY=pursue
BASE_URL=
DASHBOARD_HOST=127.0.0.1
DASHBOARD_PORT=8765
NO_DASHBOARD=0
NO_COMPATIBILITY_MARKER=0

TRANSIENT_EXIT_CODE=75
RETRY_DELAY_SECONDS=2
MAXIMUM_RETRY_DELAY_SECONDS=30
MAXIMUM_LOG_BYTES=5242880
LOG_BACKUP_COUNT=3

STATE_DIR=$PROJECT_ROOT/state
LOCK_PATH=$STATE_DIR/serv00-agent.lock
DASHBOARD_LOG=$PROJECT_ROOT/arena_dashboard.log
DASHBOARD_ERROR_LOG=$PROJECT_ROOT/arena_dashboard.error.log
DASHBOARD_PID=
TAIL_PID=
AGENT_EXIT_CODE=0

usage() {
    cat <<'EOF'
Usage: sh serv00/start_agent.sh [options]

Options:
  --python PATH              Virtualenv python (default: .venv/bin/python)
  --env-file PATH            Credential file (default: .env)
  --log-file PATH            Agent log file (default: arena_farmer.log)
  --history-db PATH          History sqlite path (default: arena_history.sqlite3)
  --worker-target N          Worker goal 1-18 (default: 18)
  --beacon-policy POLICY     hold|pursue|retreat (default: pursue)
  --base-url URL             Arena Hero API base URL
  --dashboard-host HOST      Dashboard bind host (default: 127.0.0.1)
  --dashboard-port PORT      Dashboard port (default: 8765)
  --no-dashboard             Do not start the tactical dashboard
  --no-compatibility-marker  Disable systemd compatibility-marker checks
  -h, --help                 Show this help

Ctrl+C stops the Agent and any dashboard started by this script.
EOF
}

is_abs_path() {
    case "$1" in
        /*) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_project_path() {
    value=$1
    if is_abs_path "$value"; then
        printf '%s\n' "$value"
    else
        printf '%s\n' "$PROJECT_ROOT/$value"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --python)
            [ "$#" -ge 2 ] || { echo "--python requires a path" >&2; exit 2; }
            PYTHON_PATH=$2
            shift 2
            ;;
        --env-file)
            [ "$#" -ge 2 ] || { echo "--env-file requires a path" >&2; exit 2; }
            ENV_FILE=$(resolve_project_path "$2")
            shift 2
            ;;
        --log-file)
            [ "$#" -ge 2 ] || { echo "--log-file requires a path" >&2; exit 2; }
            LOG_FILE=$(resolve_project_path "$2")
            shift 2
            ;;
        --history-db)
            [ "$#" -ge 2 ] || { echo "--history-db requires a path" >&2; exit 2; }
            HISTORY_DB=$(resolve_project_path "$2")
            shift 2
            ;;
        --worker-target)
            [ "$#" -ge 2 ] || { echo "--worker-target requires a value" >&2; exit 2; }
            WORKER_TARGET=$2
            shift 2
            ;;
        --beacon-policy)
            [ "$#" -ge 2 ] || { echo "--beacon-policy requires a value" >&2; exit 2; }
            BEACON_POLICY=$2
            shift 2
            ;;
        --base-url)
            [ "$#" -ge 2 ] || { echo "--base-url requires a value" >&2; exit 2; }
            BASE_URL=$2
            shift 2
            ;;
        --dashboard-host)
            [ "$#" -ge 2 ] || { echo "--dashboard-host requires a value" >&2; exit 2; }
            DASHBOARD_HOST=$2
            shift 2
            ;;
        --dashboard-port)
            [ "$#" -ge 2 ] || { echo "--dashboard-port requires a value" >&2; exit 2; }
            DASHBOARD_PORT=$2
            shift 2
            ;;
        --no-dashboard)
            NO_DASHBOARD=1
            shift
            ;;
        --no-compatibility-marker)
            NO_COMPATIBILITY_MARKER=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$WORKER_TARGET" in
    ''|*[!0-9]*)
        echo "--worker-target must be an integer from 1 to 18." >&2
        exit 2
        ;;
esac
if [ "$WORKER_TARGET" -lt 1 ] || [ "$WORKER_TARGET" -gt 18 ]; then
    echo "--worker-target must be an integer from 1 to 18." >&2
    exit 2
fi

case "$BEACON_POLICY" in
    hold|pursue|retreat) ;;
    *)
        echo "--beacon-policy must be hold, pursue, or retreat." >&2
        exit 2
        ;;
esac

case "$DASHBOARD_PORT" in
    ''|*[!0-9]*)
        echo "--dashboard-port must be an integer from 1 to 65535." >&2
        exit 2
        ;;
esac
if [ "$DASHBOARD_PORT" -lt 1 ] || [ "$DASHBOARD_PORT" -gt 65535 ]; then
    echo "--dashboard-port must be an integer from 1 to 65535." >&2
    exit 2
fi

if [ -z "$PYTHON_PATH" ]; then
    PYTHON_PATH=$PROJECT_ROOT/.venv/bin/python
else
    PYTHON_PATH=$(resolve_project_path "$PYTHON_PATH")
fi

AGENT_PATH=$PROJECT_ROOT/arena_farmer.py
DASHBOARD_PATH=$PROJECT_ROOT/arena_dashboard.py
DASHBOARD_URL="http://${DASHBOARD_HOST}:${DASHBOARD_PORT}/"

if [ ! -f "$PYTHON_PATH" ]; then
    echo "Python environment is missing. Run: sh serv00/bootstrap.sh" >&2
    echo "Expected: $PYTHON_PATH" >&2
    exit 2
fi
if [ ! -f "$AGENT_PATH" ]; then
    echo "Missing agent entry: $AGENT_PATH" >&2
    exit 2
fi

# 确保 API Key 存在于环境变量或 .env（绝不打印密钥明文）。
ensure_api_key() {
    if [ -n "${ARENA_HERO_API_KEY:-}" ]; then
        return 0
    fi

    if [ -f "$ENV_FILE" ]; then
        if awk '
            BEGIN { found=0 }
            /^[[:space:]]*ARENA_HERO_API_KEY[[:space:]]*=[[:space:]]*[^[:space:]]+/ {
                line=$0
                sub(/^[[:space:]]*ARENA_HERO_API_KEY[[:space:]]*=[[:space:]]*/, "", line)
                if (line ~ /^(replace-with|your-|<)/) next
                found=1
            }
            END { exit found ? 0 : 1 }
        ' "$ENV_FILE"; then
            return 0
        fi
    fi

    echo "No Arena Hero API key was found. The key will be appended to $ENV_FILE."
    if [ ! -t 0 ]; then
        echo "Non-interactive shell: set ARENA_HERO_API_KEY or write $ENV_FILE first." >&2
        exit 2
    fi

    printf 'Enter the current Arena Hero API key: ' >&2
    stty -echo
    IFS= read -r plain_key || true
    stty echo
    printf '\n' >&2

    if [ -z "${plain_key:-}" ]; then
        echo "API key cannot be empty." >&2
        exit 2
    fi

    env_dir=$(dirname -- "$ENV_FILE")
    mkdir -p "$env_dir"
    if [ -f "$ENV_FILE" ]; then
        tail_c=$(tail -c 1 "$ENV_FILE" 2>/dev/null || true)
        if [ -n "$tail_c" ]; then
            printf '\n' >> "$ENV_FILE"
        fi
    else
        umask 077
        : > "$ENV_FILE"
    fi
    printf 'ARENA_HERO_API_KEY=%s\n' "$plain_key" >> "$ENV_FILE"
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    plain_key=
}

rotate_agent_log() {
    if [ ! -f "$LOG_FILE" ]; then
        return 0
    fi
    size=$(wc -c < "$LOG_FILE" | tr -d ' ')
    if [ "$size" -lt "$MAXIMUM_LOG_BYTES" ]; then
        return 0
    fi

    oldest=$LOG_FILE.$LOG_BACKUP_COUNT
    if [ -f "$oldest" ]; then
        rm -f -- "$oldest"
    fi
    index=$((LOG_BACKUP_COUNT - 1))
    while [ "$index" -ge 1 ]; do
        source=$LOG_FILE.$index
        if [ -f "$source" ]; then
            mv -f -- "$source" "$LOG_FILE.$((index + 1))"
        fi
        index=$((index - 1))
    done
    mv -f -- "$LOG_FILE" "$LOG_FILE.1"
}

dashboard_ready() {
    "$PYTHON_PATH" - "$DASHBOARD_HOST" "$DASHBOARD_PORT" <<'PY' >/dev/null 2>&1
import sys
import urllib.request

host = sys.argv[1]
port = int(sys.argv[2])
check_host = "127.0.0.1" if host in {"0.0.0.0", "::"} else host
url = f"http://{check_host}:{port}/api/overview"
try:
    with urllib.request.urlopen(url, timeout=1) as response:
        raise SystemExit(0 if getattr(response, "status", 200) == 200 else 1)
except Exception:
    raise SystemExit(1)
PY
}

port_in_use() {
    "$PYTHON_PATH" - "$DASHBOARD_HOST" "$DASHBOARD_PORT" <<'PY' >/dev/null 2>&1
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
connect_host = "127.0.0.1" if host in {"0.0.0.0", "::"} else host
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(0.2)
try:
    result = sock.connect_ex((connect_host, port))
    raise SystemExit(0 if result == 0 else 1)
finally:
    sock.close()
PY
}

start_dashboard() {
    if dashboard_ready; then
        echo "Dashboard already running at $DASHBOARD_URL"
        DASHBOARD_PID=
        return 0
    fi
    if port_in_use; then
        echo "Port $DASHBOARD_PORT is occupied by another process. Stop it or use --dashboard-port." >&2
        exit 2
    fi
    if [ ! -f "$DASHBOARD_PATH" ]; then
        echo "Missing dashboard entry: $DASHBOARD_PATH" >&2
        exit 2
    fi

    : >> "$DASHBOARD_LOG"
    : >> "$DASHBOARD_ERROR_LOG"
    (
        cd "$PROJECT_ROOT"
        "$PYTHON_PATH" "$DASHBOARD_PATH" \
            --history-db "$HISTORY_DB" \
            --host "$DASHBOARD_HOST" \
            --port "$DASHBOARD_PORT" \
            >>"$DASHBOARD_LOG" 2>>"$DASHBOARD_ERROR_LOG"
    ) &
    DASHBOARD_PID=$!

    attempt=0
    while [ "$attempt" -lt 20 ]; do
        if ! kill -0 "$DASHBOARD_PID" 2>/dev/null; then
            echo "Dashboard stopped during startup. See $DASHBOARD_ERROR_LOG" >&2
            exit 1
        fi
        if dashboard_ready; then
            echo "Dashboard running at $DASHBOARD_URL"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.25
    done

    kill "$DASHBOARD_PID" 2>/dev/null || true
    wait "$DASHBOARD_PID" 2>/dev/null || true
    DASHBOARD_PID=
    echo "Dashboard did not become ready. See $DASHBOARD_ERROR_LOG" >&2
    exit 1
}

cleanup() {
    if [ -n "${TAIL_PID:-}" ]; then
        kill "$TAIL_PID" 2>/dev/null || true
        wait "$TAIL_PID" 2>/dev/null || true
        TAIL_PID=
    fi
    if [ -n "${DASHBOARD_PID:-}" ]; then
        kill "$DASHBOARD_PID" 2>/dev/null || true
        wait "$DASHBOARD_PID" 2>/dev/null || true
        DASHBOARD_PID=
    fi
    if [ -f "$LOCK_PATH" ]; then
        lock_pid=$(cat "$LOCK_PATH" 2>/dev/null || true)
        if [ "$lock_pid" = "$$" ]; then
            rm -f -- "$LOCK_PATH"
        fi
    fi
}

acquire_lock() {
    mkdir -p "$STATE_DIR"
    if [ -f "$LOCK_PATH" ]; then
        old_pid=$(cat "$LOCK_PATH" 2>/dev/null || true)
        case "$old_pid" in
            ''|*[!0-9]*)
                rm -f -- "$LOCK_PATH"
                ;;
            *)
                if kill -0 "$old_pid" 2>/dev/null; then
                    echo "Arena Hero Agent is already running. Use the existing session." >&2
                    exit 2
                fi
                rm -f -- "$LOCK_PATH"
                ;;
        esac
    fi
    printf '%s\n' "$$" > "$LOCK_PATH"
}

run_agent_once() {
    rotate_agent_log
    : >> "$LOG_FILE"

    # 用 tail -f 镜像日志，避免 POSIX sh 无 pipefail 时丢失 Agent 退出码。
    tail -n 0 -f "$LOG_FILE" &
    TAIL_PID=$!

    set +e
    (
        cd "$PROJECT_ROOT"
        set -- "$PYTHON_PATH" "$AGENT_PATH" \
            --env-file "$ENV_FILE" \
            --worker-target "$WORKER_TARGET" \
            --beacon-policy "$BEACON_POLICY" \
            --history-db "$HISTORY_DB"
        if [ -n "$BASE_URL" ]; then
            set -- "$@" --base-url "$BASE_URL"
        fi
        if [ "$NO_COMPATIBILITY_MARKER" -eq 1 ]; then
            set -- "$@" --no-compatibility-marker
        fi
        "$@" >>"$LOG_FILE" 2>&1
    )
    AGENT_EXIT_CODE=$?
    set -e

    if [ -n "${TAIL_PID:-}" ]; then
        kill "$TAIL_PID" 2>/dev/null || true
        wait "$TAIL_PID" 2>/dev/null || true
        TAIL_PID=
    fi
}

cd "$PROJECT_ROOT"
acquire_lock
trap cleanup EXIT INT HUP TERM
ensure_api_key

if [ "$NO_DASHBOARD" -eq 0 ]; then
    start_dashboard
fi

retry_delay=$RETRY_DELAY_SECONDS
while :; do
    run_started=$(date +%s)
    run_agent_once

    if [ "$AGENT_EXIT_CODE" -ne "$TRANSIENT_EXIT_CODE" ]; then
        break
    fi

    run_ended=$(date +%s)
    ran_seconds=$((run_ended - run_started))
    if [ "$ran_seconds" -ge 300 ]; then
        retry_delay=$RETRY_DELAY_SECONDS
    fi

    echo "Transient Agent failure. Restarting in ${retry_delay} seconds." >&2
    sleep "$retry_delay"
    next_delay=$((retry_delay * 2))
    if [ "$next_delay" -gt "$MAXIMUM_RETRY_DELAY_SECONDS" ]; then
        next_delay=$MAXIMUM_RETRY_DELAY_SECONDS
    fi
    retry_delay=$next_delay
done

echo "Agent stopped with exit code $AGENT_EXIT_CODE."
exit "$AGENT_EXIT_CODE"
