# serv00 FreeBSD 部署说明

本目录提供与 Windows 本机流程对齐的 FreeBSD/serv00 启动方式，**不包含** systemd，也**不包含** cron 保活。

对应关系：

| Windows | serv00 |
| --- | --- |
| `scripts/bootstrap.ps1` | `serv00/bootstrap.sh` |
| `start_agent.ps1` / `start_agent.cmd` | `serv00/start_agent.sh`（前台） |
| （无） | `serv00/start.sh`（FreeBSD `daemon` 后台启停） |

## 前置条件

- serv00 SSH 访问
- 已在面板开启 **Binexec**（安装自定义软件/虚拟环境前必须）
- Python 3.11+（`python3.11` / `python3.12`）
- 系统提供 `virtualenv`（脚本优先使用；缺失时回退 `python -m venv`）
- 后台运行需要 FreeBSD `daemon` 命令
- Arena Hero API Key

## 快速开始

```sh
git clone https://github.com/WuDiWangWaSai/arena-hero-agent.git
cd arena-hero-agent
sh serv00/bootstrap.sh
sh serv00/start.sh start
```

前台运行（对齐 Windows，可交互录入 API Key）：

```sh
sh serv00/start_agent.sh
```

仅运行 Agent：

```sh
sh serv00/start.sh start --no-dashboard
# 或前台：
sh serv00/start_agent.sh --no-dashboard
```

## 后台启停（推荐）

使用 FreeBSD `daemon` 写入 `bot.pid` / `bot.log`：

```sh
sh serv00/start.sh start
sh serv00/start.sh status
sh serv00/start.sh restart
sh serv00/start.sh stop
```

默认同时后台启动战术展示页（`dashboard.pid` / `dashboard.log`）。无参数时默认 `start`。

后台启动**不会**交互询问 API Key。请先准备 `.env` 或环境变量 `ARENA_HERO_API_KEY`。若还没有密钥，可先跑一次前台脚本录入：

```sh
sh serv00/start_agent.sh --no-dashboard
```

虚拟环境解析顺序：

1. `ARENA_PYTHON`
2. 项目内 `.venv/bin/python`（`bootstrap.sh` 产物）
3. `ARENA_VENV_ACTIVATE`
4. `~/.virtualenvs/arena-hero/bin/activate`

## 前台可选参数

```sh
sh serv00/start_agent.sh \
  --worker-target 18 \
  --beacon-policy pursue \
  --history-db ./arena_history.sqlite3 \
  --dashboard-host 127.0.0.1 \
  --dashboard-port 8765
```

前台运行时按 `Ctrl+C` 停止；脚本会同时结束后台拉起的展示页进程。修改代码后需要重新启动才会生效。

## bootstrap 做了什么

1. 检测 Python 3.11+
2. **优先** `virtualenv .venv -p <python>`，否则回退 `python -m venv`
3. 设置 serv00 官方推荐的编译/进程限制变量：
   - `CFLAGS` / `CXXFLAGS`
   - `CC` / `CXX`
   - `MAX_CONCURRENCY=1` `CPUCOUNT=1` `MAKEFLAGS=-j1`
4. 按 Windows 相同顺序安装哈希锁定依赖：
   - `requirements-build.lock`
   - `requirements.lock`
   - `pip install --no-deps --no-build-isolation --editable .`
   - `pip check`

若 `pip install` 因进程数限制失败，可按官方文档重试：

```sh
cpuset -l 0 .venv/bin/python -m pip install --require-hashes -r requirements.lock
```

## start_agent 行为（前台）

- 缺失 API Key 时交互写入项目根目录 `.env`（权限尽量设为 `600`）
- 单实例锁：`state/serv00-agent.lock`
- 默认日志：`arena_farmer.log`（约 5MB × 3 备份轮转）
- 默认历史库：`arena_history.sqlite3`
- 瞬时失败（退出码 `75`）指数退避重试：2s → 30s
- 默认启动战术展示页；可用 `--no-dashboard` 关闭

## Dashboard 访问

默认绑定 `127.0.0.1:8765`，与 Windows 本机行为一致，仅本机可访问。

若需要从外网访问，请先在 serv00 预留端口，再显式指定：

```sh
sh serv00/start.sh start --dashboard-host 0.0.0.0 --dashboard-port <预留端口>
```

本方案**不**使用 Phusion Passenger / WSGI，保持与 Windows 相同的 `arena_dashboard` HTTP 服务启动方式。

## 运行产物

| 路径 | 说明 |
| --- | --- |
| `.venv/` | virtualenv 环境 |
| `.env` | API Key（勿提交 Git） |
| `bot.pid` / `bot.log` | 后台 Agent 的 pid 与日志 |
| `dashboard.pid` / `dashboard.log` | 后台展示页的 pid 与日志 |
| `arena_farmer.log` | 前台 Agent 日志 |
| `arena_history.sqlite3` | 战术历史库 |
| `arena_dashboard.log` | 前台展示页标准输出 |
| `arena_dashboard.error.log` | 前台展示页错误输出 |
| `state/serv00-agent.lock` | 前台单实例锁 |

## 与生产 systemd 的关系

仓库中的 `scripts/install-systemd.sh` / `update-systemd.sh` 仍供独立 Linux 生产机使用，**不属于**本 serv00 流程。

## 安全

- 不要打印、提交 API Key 或私有运行日志
- 不要把 `.env` 同步到公开位置
- 展示页排行榜只访问公开接口，不发送 Agent API Key
