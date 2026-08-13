#!/bin/sh
# serv00 FreeBSD bootstrap: mirror scripts/bootstrap.ps1，优先使用 virtualenv。
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
VENV_PATH=$PROJECT_ROOT/.venv
PYTHON_BIN=${PYTHON_BIN:-}
NO_UPGRADE_PIP=0

usage() {
    cat <<'EOF'
Usage: sh serv00/bootstrap.sh [options]

Options:
  --python PATH     Python 3.11+ interpreter (default: auto-detect)
  --no-upgrade-pip  Skip pip self-upgrade
  -h, --help        Show this help

Requires Binexec enabled on serv00 before installing packages.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --python)
            [ "$#" -ge 2 ] || { echo "--python requires a path" >&2; exit 2; }
            PYTHON_BIN=$2
            shift 2
            ;;
        --no-upgrade-pip)
            NO_UPGRADE_PIP=1
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

# serv00 官方建议：限制并发编译并暴露本地头文件。
export CFLAGS="${CFLAGS:--I/usr/local/include}"
export CXXFLAGS="${CXXFLAGS:--I/usr/local/include}"
export CC="${CC:-gcc}"
export CXX="${CXX:-g++}"
export MAX_CONCURRENCY="${MAX_CONCURRENCY:-1}"
export CPUCOUNT="${CPUCOUNT:-1}"
export MAKEFLAGS="${MAKEFLAGS:--j1}"
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-1}"
export PYTHONDONTWRITEBYTECODE=1

python_version_supported() {
    "$1" -c 'import sys; raise SystemExit(sys.version_info < (3, 11))' >/dev/null 2>&1
}

select_python() {
    if [ -n "$PYTHON_BIN" ]; then
        if [ ! -x "$PYTHON_BIN" ] && ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
            echo "Selected Python interpreter is unavailable: $PYTHON_BIN" >&2
            exit 2
        fi
        if command -v "$PYTHON_BIN" >/dev/null 2>&1; then
            PYTHON_BIN=$(command -v "$PYTHON_BIN")
        fi
        if ! python_version_supported "$PYTHON_BIN"; then
            echo "Selected Python interpreter must be Python 3.11 or newer: $PYTHON_BIN" >&2
            exit 2
        fi
        return
    fi

    for candidate in \
        /usr/local/bin/python3.12 \
        /usr/local/bin/python3.11 \
        python3.12 \
        python3.11 \
        python3 \
        python
    do
        if command -v "$candidate" >/dev/null 2>&1 && python_version_supported "$candidate"; then
            PYTHON_BIN=$(command -v "$candidate")
            return
        fi
    done

    echo "No compatible Python 3.11+ interpreter found." >&2
    exit 2
}

create_virtualenv() {
    if [ -d "$VENV_PATH" ]; then
        echo "Virtual environment already exists: $VENV_PATH"
        return
    fi

    echo "Creating virtual environment at $VENV_PATH"
    if command -v virtualenv >/dev/null 2>&1; then
        # 优先使用 serv00 官方文档中的 virtualenv 流程。
        virtualenv "$VENV_PATH" -p "$PYTHON_BIN"
        return
    fi

    echo "virtualenv command not found; falling back to python -m venv." >&2
    "$PYTHON_BIN" -m venv "$VENV_PATH"
}

require_project_files() {
    for required in \
        "$PROJECT_ROOT/requirements-build.lock" \
        "$PROJECT_ROOT/requirements.lock" \
        "$PROJECT_ROOT/pyproject.toml" \
        "$PROJECT_ROOT/arena_farmer.py"
    do
        if [ ! -f "$required" ]; then
            echo "Missing project file: $required" >&2
            exit 2
        fi
    done
}

echo "=== Arena Hero serv00 bootstrap ==="
echo "Project root: $PROJECT_ROOT"
echo "Warning: enable Binexec in the serv00 panel before installing packages."
echo

select_python
require_project_files
echo "Using Python: $PYTHON_BIN ($("$PYTHON_BIN" -c 'import sys; print(sys.version.split()[0])'))"

create_virtualenv
VENV_PYTHON=$VENV_PATH/bin/python

if [ ! -x "$VENV_PYTHON" ] && [ ! -f "$VENV_PYTHON" ]; then
    echo "Virtual environment Python is missing: $VENV_PYTHON" >&2
    exit 2
fi

cd "$PROJECT_ROOT"

if [ "$NO_UPGRADE_PIP" -eq 0 ]; then
    echo "Upgrading pip..."
    "$VENV_PYTHON" -m pip install --upgrade pip || {
        echo "pip upgrade failed. Retry with: cpuset -l 0 $VENV_PYTHON -m pip install --upgrade pip" >&2
        exit 1
    }
fi

echo "Installing locked build dependencies..."
"$VENV_PYTHON" -m pip install --require-hashes -r "$PROJECT_ROOT/requirements-build.lock" || {
    echo "Build dependency install failed. Retry with: cpuset -l 0 $VENV_PYTHON -m pip install --require-hashes -r requirements-build.lock" >&2
    exit 1
}

echo "Installing locked runtime dependencies..."
"$VENV_PYTHON" -m pip install --require-hashes -r "$PROJECT_ROOT/requirements.lock" || {
    echo "Runtime dependency install failed. Retry with: cpuset -l 0 $VENV_PYTHON -m pip install --require-hashes -r requirements.lock" >&2
    exit 1
}

echo "Installing arena-hero-agent (editable, no deps)..."
"$VENV_PYTHON" -m pip install --no-deps --no-build-isolation --editable "$PROJECT_ROOT" || {
    echo "Editable install failed." >&2
    exit 1
}

echo "Checking installed dependency set..."
"$VENV_PYTHON" -m pip check || {
    echo "The installed dependency set is inconsistent." >&2
    exit 1
}

echo
echo "Environment ready."
echo "Start with: sh serv00/start_agent.sh"
echo "Agent only: sh serv00/start_agent.sh --no-dashboard"
