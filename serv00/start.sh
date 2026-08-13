#!/bin/sh
# Serv00 / FreeBSD：Arena Hero Agent 后台启停（daemon + pid/log）。
#
# 用法：
#   sh serv00/start.sh              # 默认 start
#   sh serv00/start.sh start
#   sh serv00/start.sh stop
#   sh serv00/start.sh restart
#   sh serv00/start.sh status
#   sh serv00/start.sh help

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$SCRIPT_DIR/../arena_farmer.py" ]; then
    PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
elif [ -f "$SCRIPT_DIR/arena_farmer.py" ]; then
    PROJECT_ROOT=$SCRIPT_DIR
else
    echo "✗ 未找到 arena_farmer.py，请在仓库内执行。" >&2
    exit 2
fi

cd "$PROJECT_ROOT"

PID_FILE=$PROJECT_ROOT/bot.pid
LOG_FILE=$PROJECT_ROOT/bot.log
DASHBOARD_PID_FILE=$PROJECT_ROOT/dashboard.pid
DASHBOARD_LOG_FILE=$PROJECT_ROOT/dashboard.log
AGENT_PATH=$PROJECT_ROOT/arena_farmer.py
DASHBOARD_PATH=$PROJECT_ROOT/arena_dashboard.py
ENV_FILE=${ARENA_ENV_FILE:-$PROJECT_ROOT/.env}
HISTORY_DB=${ARENA_HISTORY_DB:-$PROJECT_ROOT/arena_history.sqlite3}
WORKER_TARGET=${ARENA_WORKER_TARGET:-18}
BEACON_POLICY=${ARENA_BEACON_POLICY:-pursue}
DASHBOARD_HOST=${ARENA_DASHBOARD_HOST:-127.0.0.1}
DASHBOARD_PORT=${ARENA_DASHBOARD_PORT:-8765}
NO_DASHBOARD=0
CMD=

usage() {
    cat <<'EOF'
用法: sh serv00/start.sh [start|stop|restart|status|help] [options]

  start     后台启动 Agent（daemon + bot.pid / bot.log）
  stop      停止进程（按 pid 文件杀进程并清理）
  restart   先 stop 再 start
  status    查看是否在运行
  help      显示本说明

无参数时默认执行 start（兼容旧用法）。

选项：
  --no-dashboard           不启动战术展示页
  --dashboard-host HOST    展示页绑定地址（默认 127.0.0.1）
  --dashboard-port PORT    展示页端口（默认 8765）

环境变量：
  ARENA_PYTHON             指定 python 可执行文件
  ARENA_VENV_ACTIVATE      指定 virtualenv activate 路径
  ARENA_WORKER_TARGET      Worker 目标（默认 18）
  ARENA_BEACON_POLICY      hold|pursue|retreat（默认 pursue）
  ARENA_HISTORY_DB         历史库路径
  ARENA_ENV_FILE           凭证文件路径
  ARENA_DASHBOARD_HOST / ARENA_DASHBOARD_PORT
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        start|stop|restart|status|help)
            if [ -n "$CMD" ]; then
                echo "未知参数组合: $CMD $1" >&2
                usage >&2
                exit 2
            fi
            CMD=$1
            shift
            ;;
        -h|--help)
            CMD=help
            shift
            ;;
        --no-dashboard)
            NO_DASHBOARD=1
            shift
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
        *)
            echo "未知参数: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

CMD=${CMD:-start}

is_running() {
    pid=${1:-}
    if [ -z "$pid" ]; then
        return 1
    fi
    ps -p "$pid" >/dev/null 2>&1
}

read_pid_file() {
    file=$1
    if [ -f "$file" ]; then
        tr -d ' \t\n' < "$file" 2>/dev/null || true
    fi
}

has_api_key() {
    if [ -n "${ARENA_HERO_API_KEY:-}" ]; then
        return 0
    fi
    if [ ! -f "$ENV_FILE" ]; then
        return 1
    fi
    awk '
        BEGIN { found=0 }
        /^[[:space:]]*ARENA_HERO_API_KEY[[:space:]]*=[[:space:]]*[^[:space:]]+/ {
            line=$0
            sub(/^[[:space:]]*ARENA_HERO_API_KEY[[:space:]]*=[[:space:]]*/, "", line)
            if (line ~ /^(replace-with|your-|<)/) next
            found=1
        }
        END { exit found ? 0 : 1 }
    ' "$ENV_FILE"
}

resolve_python() {
    if [ -n "${ARENA_PYTHON:-}" ]; then
        PYTHON_BIN=$ARENA_PYTHON
        return 0
    fi
    if [ -f "$PROJECT_ROOT/.venv/bin/python" ]; then
        PYTHON_BIN=$PROJECT_ROOT/.venv/bin/python
        return 0
    fi

    if [ -n "${ARENA_VENV_ACTIVATE:-}" ]; then
        VENV_ACTIVATE=$ARENA_VENV_ACTIVATE
    elif [ -f "$PROJECT_ROOT/.venv/bin/activate" ]; then
        VENV_ACTIVATE=$PROJECT_ROOT/.venv/bin/activate
    elif [ -f "${HOME}/.virtualenvs/arena-hero/bin/activate" ]; then
        VENV_ACTIVATE=${HOME}/.virtualenvs/arena-hero/bin/activate
    else
        echo "✗ 未找到虚拟环境: $PROJECT_ROOT/.venv 或 ${HOME}/.virtualenvs/arena-hero" >&2
        echo "  请先执行: sh serv00/bootstrap.sh" >&2
        exit 1
    fi

    if [ ! -f "$VENV_ACTIVATE" ]; then
        echo "✗ 未找到虚拟环境: $VENV_ACTIVATE" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    . "$VENV_ACTIVATE"
    if ! command -v python >/dev/null 2>&1; then
        echo "✗ 激活虚拟环境后未找到 python" >&2
        exit 1
    fi
    PYTHON_BIN=$(command -v python)
}

require_daemon() {
    if ! command -v daemon >/dev/null 2>&1; then
        echo "✗ 未找到 daemon 命令（FreeBSD/Serv00 需要）" >&2
        exit 1
    fi
}

describe_one() {
    name=$1
    pid_file=$2
    log_file=$3
    pid=$(read_pid_file "$pid_file")
    if [ -n "$pid" ] && is_running "$pid"; then
        echo "✓ $name is running"
        echo "  PID:  $pid"
        echo "  Log:  $log_file"
        echo "  File: $pid_file"
        return 0
    fi
    if [ -n "$pid" ]; then
        echo "✗ $name is not running (stale pid file: $pid)"
        echo "  File: $pid_file"
        return 1
    fi
    echo "✗ $name is not running"
    return 1
}

stop_one() {
    name=$1
    pid_file=$2
    pid=$(read_pid_file "$pid_file")

    if [ -z "$pid" ]; then
        echo "$name is not running (no pid file)"
        return 0
    fi

    if ! is_running "$pid"; then
        rm -f "$pid_file"
        echo "✓ Removed stale $name pid file (was $pid)"
        return 0
    fi

    echo "Stopping $name (PID: $pid) ..."
    kill "$pid" 2>/dev/null || true

    i=1
    while [ "$i" -le 10 ]; do
        if ! is_running "$pid"; then
            break
        fi
        sleep 0.5
        i=$((i + 1))
    done

    if is_running "$pid"; then
        echo "  still alive, sending KILL ..."
        kill -9 "$pid" 2>/dev/null || true
        sleep 0.5
    fi

    if is_running "$pid"; then
        echo "✗ Failed to stop $name PID $pid" >&2
        exit 1
    fi

    rm -f "$pid_file"
    echo "✓ $name stopped"
}

start_one() {
    name=$1
    pid_file=$2
    log_file=$3
    shift 3

    old_pid=$(read_pid_file "$pid_file")
    if [ -n "$old_pid" ] && is_running "$old_pid"; then
        echo "$name already running (PID: $old_pid)"
        exit 1
    fi
    if [ -n "$old_pid" ]; then
        rm -f "$pid_file"
    fi

    daemon -p "$pid_file" -o "$log_file" "$@"

    sleep 1
    new_pid=$(read_pid_file "$pid_file")
    if [ -n "$new_pid" ] && is_running "$new_pid"; then
        echo "✓ $name started successfully"
        echo "✓ PID: $new_pid"
        echo "✓ Log: $log_file"
        return 0
    fi
    echo "✗ $name failed to start. Check $log_file for errors" >&2
    exit 1
}

do_status() {
    agent_ok=0
    dash_ok=0
    if describe_one "Bot" "$PID_FILE" "$LOG_FILE"; then
        agent_ok=1
    fi
    if [ "$NO_DASHBOARD" -eq 0 ] || [ -f "$DASHBOARD_PID_FILE" ]; then
        if describe_one "Dashboard" "$DASHBOARD_PID_FILE" "$DASHBOARD_LOG_FILE"; then
            dash_ok=1
        fi
    fi
    if [ "$agent_ok" -eq 1 ]; then
        return 0
    fi
    return 1
}

do_stop() {
    if [ -f "$DASHBOARD_PID_FILE" ]; then
        stop_one "Dashboard" "$DASHBOARD_PID_FILE"
    fi
    stop_one "Bot" "$PID_FILE"
}

do_start() {
    require_daemon
    resolve_python

    if [ ! -f "$AGENT_PATH" ]; then
        echo "✗ Missing agent entry: $AGENT_PATH" >&2
        exit 1
    fi
    if ! has_api_key; then
        echo "✗ 未找到 API Key。请先设置 ARENA_HERO_API_KEY 或写入 $ENV_FILE" >&2
        echo "  前台首次录入可用: sh serv00/start_agent.sh --no-dashboard" >&2
        exit 1
    fi

    start_one "Bot" "$PID_FILE" "$LOG_FILE" \
        "$PYTHON_BIN" -u "$AGENT_PATH" \
        --env-file "$ENV_FILE" \
        --worker-target "$WORKER_TARGET" \
        --beacon-policy "$BEACON_POLICY" \
        --history-db "$HISTORY_DB" \
        --no-compatibility-marker

    if [ "$NO_DASHBOARD" -eq 1 ]; then
        return 0
    fi
    if [ ! -f "$DASHBOARD_PATH" ]; then
        echo "✗ Missing dashboard entry: $DASHBOARD_PATH" >&2
        do_stop
        exit 1
    fi
    start_one "Dashboard" "$DASHBOARD_PID_FILE" "$DASHBOARD_LOG_FILE" \
        "$PYTHON_BIN" -u "$DASHBOARD_PATH" \
        --history-db "$HISTORY_DB" \
        --host "$DASHBOARD_HOST" \
        --port "$DASHBOARD_PORT"
}

do_restart() {
    do_stop
    sleep 1
    do_start
}

case "$CMD" in
    start) do_start ;;
    stop) do_stop ;;
    restart) do_restart ;;
    status) do_status ;;
    help) usage ;;
    *)
        echo "未知参数: $CMD" >&2
        usage >&2
        exit 2
        ;;
esac
