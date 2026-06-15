#!/usr/bin/env bash
set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_DIR="${PROJECT_ROOT}/frontend"
BACKEND_DIR="${PROJECT_ROOT}/backend"
LOG_DIR="${PROJECT_ROOT}/.accept-logs"
mkdir -p "${LOG_DIR}"

STAGE=0
PASSED=0
declare -a FAIL_REASONS=()
BACKEND_PID=""
EXIT_CODE=0

step_log()  { echo -e "${CYAN}[步骤 $1]${NC} $2"; }
info()      { echo -e "${GREEN}  ✔${NC} $*"; }
warn()      { echo -e "${YELLOW}  ⚠${NC} $*"; }
fail_item() { echo -e "${RED}  ✘${NC} $*"; FAIL_REASONS+=("$*"); EXIT_CODE=1; }
section()   { echo ""; echo -e "${YELLOW}━━━ $1 ━━━${NC}"; }
hr()        { echo -e "${YELLOW}────────────────────────────────────────────────────────────${NC}"; }

bail() {
  fail_item "$1"
  end_report
  exit 1
}

load_nvm() {
  if [ -s "$HOME/.nvm/nvm.sh" ]; then
    export NVM_DIR="$HOME/.nvm"
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
  fi
}

ensure_docker_running() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi
  warn "Docker daemon 未运行，正在尝试启动 Docker Desktop..."
  if [ -d "/Applications/Docker.app" ]; then
    open /Applications/Docker.app
    local waited=0
    while [ $waited -lt 60 ]; do
      sleep 2
      waited=$((waited + 2))
      if docker info >/dev/null 2>&1; then
        info "Docker daemon 已就绪（等待 ${waited}s）"
        return 0
      fi
    done
  fi
  return 1
}

wait_for_http() {
  local url="$1"
  local max_wait="${2:-30}"
  local waited=0 code="000"
  local ok_count=0
  while [ $waited -lt $max_wait ]; do
    code="000"
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null) || code="000"
    [ -z "$code" ] && code="000"
    if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
      ok_count=$((ok_count + 1))
      if [ $ok_count -ge 2 ]; then
        info "$url 响应正常（连续2次 HTTP ${code}，等待 ${waited}s）"
        return 0
      fi
      sleep 0.5
    else
      ok_count=0
      sleep 1
    fi
    waited=$((waited + 1))
  done
  fail_item "$url 在 ${max_wait}s 内未连续2次返回 200/301/302，最后状态码：${code}"
  return 1
}

append_log() {
  echo "" >> "$1" 2>/dev/null || true
  echo "=== $2 ===" >> "$1" 2>/dev/null || true
  cat >> "$1" 2>/dev/null || true
}

cleanup_all() {
  if [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" 2>/dev/null; then
    kill "$BACKEND_PID" 2>/dev/null || true
    sleep 1
  fi
  BACKEND_PID=""
  if [ -f "${PROJECT_ROOT}/docker-compose.yml" ] || [ -f "${PROJECT_ROOT}/docker-compose.yaml" ]; then
    (cd "${PROJECT_ROOT}" && docker compose down >/dev/null 2>&1 || true)
  fi
}

end_report() {
  local s1="跳过" s1c=""
  local s2="跳过" s2c=""
  local s3="跳过" s3c=""
  [ $(( STAGE & 1 )) -gt 0 ] && { [ $(( PASSED & 1 )) -gt 0 ] && { s1="通过"; s1c="$GREEN"; } || { s1="失败"; s1c="$RED"; }; }
  [ $(( STAGE & 2 )) -gt 0 ] && { [ $(( PASSED & 2 )) -gt 0 ] && { s2="通过"; s2c="$GREEN"; } || { s2="失败"; s2c="$RED"; }; }
  [ $(( STAGE & 4 )) -gt 0 ] && { [ $(( PASSED & 4 )) -gt 0 ] && { s3="通过"; s3c="$GREEN"; } || { s3="失败"; s3c="$RED"; }; }

  echo ""
  hr
  echo -e "                     验 收 结 果 汇 总"
  hr
  echo -e "  项目路径  : ${PROJECT_ROOT}"
  echo -e "  执行时间  : $(date '+%Y-%m-%d %H:%M:%S')"
  echo -e "  日志目录  : ${LOG_DIR}"
  echo ""
  echo -e "  阶段一 [${s1c}${s1}${NC}]  前端构建"
  echo -e "  阶段二 [${s2c}${s2}${NC}]  后端接口检查"
  echo -e "  阶段三 [${s3c}${s3}${NC}]  容器启动验证"
  echo ""

  if [ ${#FAIL_REASONS[@]} -gt 0 ]; then
    echo -e "${RED}  失败原因列表（共 ${#FAIL_REASONS[@]} 项）：${NC}"
    local i=1 reason
    for reason in "${FAIL_REASONS[@]}"; do
      echo -e "    ${RED}${i}. ${reason}${NC}"
      i=$((i + 1))
    done
    echo ""
    echo -e "  相关日志文件（所有阶段日志均保存在：${LOG_DIR}/）"
    local f
    for f in "${LOG_DIR}"/*.log "${LOG_DIR}"/*.log_tail.log; do
      [ -s "$f" ] && echo -e "    - $f"
    done
    hr
    echo -e "${RED}                 ❌  验 收 失 败  ❌${NC}"
    hr
  else
    hr
    echo -e "${GREEN}                 ✅  验 收 全 部 通 过  ✅${NC}"
    hr
  fi
}

trap cleanup_all EXIT

# ============================================================================
# 阶段一：前端构建
# ============================================================================
section "阶段一：前端构建"
STAGE=$(( STAGE | 1 ))
BUILD_LOG="${LOG_DIR}/1_frontend_build.log"
: > "${BUILD_LOG}"

step_log 1.1 "检查 Node.js 环境"
load_nvm
if ! command -v node >/dev/null 2>&1; then
  bail "未找到 node 命令：请先安装 Node.js，或通过 nvm 激活（未检测到可用 Node.js 环境）"
fi
if ! command -v npm >/dev/null 2>&1; then
  bail "未找到 npm 命令：Node.js 环境异常，缺少 npm"
fi
info "node $(node --version) / npm $(npm --version)"

step_log 1.2 "安装 frontend 依赖（npm install）"
{
  echo "=== $(date '+%H:%M:%S') npm install ==="
  cd "${FRONTEND_DIR}"
  npm install 2>&1
} >> "${BUILD_LOG}" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  {
    echo ""
    echo "=== npm install 失败关键信息（节选最后 60 行） ==="
    tail -n 60 "${BUILD_LOG}" | grep -i -E "error|fatal|E404|EINTEGRITY|ECONNREFUSED|ENOTFOUND" || tail -n 30 "${BUILD_LOG}"
  } >> "${BUILD_LOG}" 2>&1
  bail "npm install 失败（exit=${rc}）。常见原因：
      1. 网络不通，无法访问 npm registry；
      2. package.json / package-lock.json 损坏；
      3. 磁盘空间不足。
      请查看 ${BUILD_LOG} 获取完整日志。"
fi
info "npm install 完成"

step_log 1.3 "执行生产构建（npm run build）"
{
  echo ""
  echo "=== $(date '+%H:%M:%S') npm run build ==="
  cd "${FRONTEND_DIR}"
  npm run build 2>&1
} >> "${BUILD_LOG}" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  {
    echo ""
    echo "=== npm run build 失败关键信息（节选最后 60 行） ==="
    tail -n 60 "${BUILD_LOG}" | grep -i -E "error|failed|cannot|vite|unresolved|import|jsx|tsx|syntax" || tail -n 30 "${BUILD_LOG}"
  } >> "${BUILD_LOG}" 2>&1
  bail "npm run build 失败（exit=${rc}）。常见原因：
      1. 源代码存在语法错误（JSX 语法、未定义变量、引用丢失等）；
      2. vite / 插件版本不兼容；
      3. import 路径错误或文件缺失。
      请查看 ${BUILD_LOG} 获取完整构建日志。"
fi
if [ ! -d "${FRONTEND_DIR}/dist" ] || [ ! -f "${FRONTEND_DIR}/dist/index.html" ]; then
  bail "npm run build 完成但产物缺失：未找到 dist/index.html"
fi
info "构建产物就绪：$(du -sh "${FRONTEND_DIR}/dist" 2>/dev/null | cut -f1)"
PASSED=$(( PASSED | 1 ))
info "阶段一 前端构建 通过 ✅"

# ============================================================================
# 阶段二：后端接口检查（本地 uvicorn）
# ============================================================================
section "阶段二：后端接口检查"
STAGE=$(( STAGE | 2 ))
API_LOG="${LOG_DIR}/2_backend_api.log"
BACKEND_STDOUT="${LOG_DIR}/2_backend_stdout.log"
: > "${API_LOG}"
: > "${BACKEND_STDOUT}"
LOCAL_PORT=18000

step_log 2.1 "检查 Python 环境"
if ! command -v python3 >/dev/null 2>&1; then
  bail "未找到 python3 命令：请先安装 Python 3"
fi
info "python3 $(python3 --version 2>&1)"

step_log 2.2 "安装 backend 依赖"
{
  echo "=== $(date '+%H:%M:%S') pip install -r requirements.txt ==="
  cd "${BACKEND_DIR}"
  pip3 install -r requirements.txt 2>&1
} >> "${API_LOG}" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  {
    echo ""
    echo "=== pip install 失败关键信息（最后 50 行） ==="
    tail -n 50 "${API_LOG}" | grep -i -E "error|could not|no matching|failed" || tail -n 20 "${API_LOG}"
  } >> "${API_LOG}" 2>&1
  bail "pip install 失败（exit=${rc}）。请查看 ${API_LOG}"
fi
info "Python 依赖就绪"

step_log 2.3 "启动本地后端服务（端口 ${LOCAL_PORT}）"
cd "${BACKEND_DIR}"
nohup python3 -m uvicorn app.main:app --host 127.0.0.1 --port "${LOCAL_PORT}" \
  > "${BACKEND_STDOUT}" 2>&1 &
BACKEND_PID=$!
info "后端 PID=${BACKEND_PID}，等待服务就绪..."

step_log 2.4 "等待后端健康检查可用（最长 30s）"
if ! wait_for_http "http://127.0.0.1:${LOCAL_PORT}/api/health" 30; then
  {
    echo "=== 后端启动失败，stdout/stderr（最后 80 行） ==="
    tail -n 80 "${BACKEND_STDOUT}"
  } >> "${API_LOG}" 2>&1
  bail "后端启动失败：/api/health 在 30s 内无响应。
      可能原因：
      1. Python 包缺失（ModuleNotFoundError / ImportError）；
      2. app.main:app 导入路径错误；
      3. 启动时抛异常；
      4. uvicorn 启动但立即退出。
      请查看 ${BACKEND_STDOUT} 获取后端 stdout/stderr，${API_LOG} 查看汇总日志。"
fi

step_log 2.5 "验证所有 GET 接口"
declare -a GET_ENDPOINTS=(
  "/api/health|health|200"
  "/api/courts|球场列表|200"
  "/api/members|会员列表|200"
  "/api/time-slots|时间段列表|200"
  "/api/bookings|预订列表|200"
)
for item in "${GET_ENDPOINTS[@]}"; do
  path="${item%%|*}"
  rest="${item#*|}"
  name="${rest%%|*}"
  expect="${rest##*|}"
  code="000"
  code=$(curl -s -o /tmp/accept_resp.json -w "%{http_code}" "http://127.0.0.1:${LOCAL_PORT}${path}" 2>/dev/null || code="000")
  body=$(cat /tmp/accept_resp.json 2>/dev/null || echo "")
  if [ "$code" != "$expect" ]; then
    bail "GET ${path}（${name}）失败：期望 HTTP ${expect}，实际 ${code}。响应体：${body:0:500}"
  fi
  if [ -z "$body" ]; then
    bail "GET ${path}（${name}）响应体为空"
  fi
  info "GET ${path} → HTTP ${code} OK"
done

step_log 2.6 "验证写操作接口 POST /api/courts"
code=$(curl -s -o /tmp/accept_resp.json -w "%{http_code}" \
  -X POST "http://127.0.0.1:${LOCAL_PORT}/api/courts" \
  -H "Content-Type: application/json" \
  -d '{"name":"验收球场","surface":"PVC","indoor":true}' 2>/dev/null || code="000")
if [ "$code" != "201" ]; then
  bail "POST /api/courts 失败：期望 201，实际 ${code}，响应：$(cat /tmp/accept_resp.json 2>/dev/null)"
fi
info "POST /api/courts → HTTP 201（创建验收球场）"

step_log 2.7 "验证 POST /api/bookings（创建预订 + 结算 + 取消）"
code=$(curl -s -o /tmp/accept_resp.json -w "%{http_code}" \
  -X POST "http://127.0.0.1:${LOCAL_PORT}/api/bookings" \
  -H "Content-Type: application/json" \
  -d '{"slot_id":1,"member_id":2,"contact_name":"李明"}' 2>/dev/null || code="000")
if [ "$code" != "201" ]; then
  bail "POST /api/bookings 创建预订失败：期望 201，实际 ${code}，响应：$(cat /tmp/accept_resp.json 2>/dev/null)"
fi
booking_id=$(python3 -c "import json,sys; d=json.load(open('/tmp/accept_resp.json')); print(d.get('id',0))" 2>/dev/null || echo "0")
info "POST /api/bookings → HTTP 201（预订 id=${booking_id}）"

if [ -n "$booking_id" ] && [ "$booking_id" != "0" ]; then
  code=$(curl -s -o /tmp/accept_resp.json -w "%{http_code}" \
    -X POST "http://127.0.0.1:${LOCAL_PORT}/api/bookings/${booking_id}/settle" 2>/dev/null || code="000")
  if [ "$code" != "200" ]; then
    bail "POST /api/bookings/${booking_id}/settle 结算失败：期望 200，实际 ${code}"
  fi
  info "POST /api/bookings/${booking_id}/settle → HTTP 200（status=paid）"

  # 再创建一个待取消的预订
  code=$(curl -s -o /tmp/accept_resp.json -w "%{http_code}" \
    -X POST "http://127.0.0.1:${LOCAL_PORT}/api/bookings" \
    -H "Content-Type: application/json" \
    -d '{"slot_id":4,"member_id":3,"contact_name":"王悦"}' 2>/dev/null || code="000")
  booking2_id=$(python3 -c "import json,sys; d=json.load(open('/tmp/accept_resp.json')); print(d.get('id',0))" 2>/dev/null || echo "0")
  if [ -n "$booking2_id" ] && [ "$booking2_id" != "0" ]; then
    code=$(curl -s -o /tmp/accept_resp.json -w "%{http_code}" \
      -X POST "http://127.0.0.1:${LOCAL_PORT}/api/bookings/${booking2_id}/cancel" 2>/dev/null || code="000")
    if [ "$code" != "200" ]; then
      bail "POST /api/bookings/${booking2_id}/cancel 取消失败：期望 200，实际 ${code}"
    fi
    info "POST /api/bookings/${booking2_id}/cancel → HTTP 200（status=canceled）"
  fi
fi

step_log 2.8 "验证 PATCH /api/time-slots/1"
code=$(curl -s -o /tmp/accept_resp.json -w "%{http_code}" \
  -X PATCH "http://127.0.0.1:${LOCAL_PORT}/api/time-slots/1" \
  -H "Content-Type: application/json" \
  -d '{"price":99.0}' 2>/dev/null || code="000")
if [ "$code" != "200" ]; then
  bail "PATCH /api/time-slots/1 失败：期望 200，实际 ${code}，响应：$(cat /tmp/accept_resp.json 2>/dev/null)"
fi
info "PATCH /api/time-slots/1 → HTTP 200（更新价格）"

# 停掉本地后端
if [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" 2>/dev/null; then
  kill "$BACKEND_PID" 2>/dev/null || true
  sleep 1
fi
BACKEND_PID=""

PASSED=$(( PASSED | 2 ))
info "阶段二 后端接口检查 通过 ✅"

# ============================================================================
# 阶段三：容器启动验证（docker compose）
# ============================================================================
section "阶段三：容器启动验证"
STAGE=$(( STAGE | 4 ))
DOCKER_LOG="${LOG_DIR}/3_docker.log"
: > "${DOCKER_LOG}"
BACKEND_URL="http://127.0.0.1:8000"
FRONTEND_URL="http://127.0.0.1:5173"

step_log 3.1 "检查 Docker 环境并确保 daemon 运行"
if ! ensure_docker_running; then
  bail "Docker daemon 无法启动：请手动启动 Docker Desktop 后重试"
fi
info "docker $(docker --version 2>&1 | head -1)"
info "docker compose $(docker compose version 2>&1 | head -1)"

step_log 3.2 "检查 8000/5173 端口占用并清理"
for port in 8000 5173; do
  pids=$(lsof -iTCP:${port} -sTCP:LISTEN -P -n -t 2>/dev/null || true)
  if [ -n "$pids" ]; then
    warn "发现端口 ${port} 被进程占用（PID: ${pids}），正在自动清理..."
    kill ${pids} 2>/dev/null || true
    sleep 2
    still=$(lsof -iTCP:${port} -sTCP:LISTEN -P -n -t 2>/dev/null || true)
    if [ -n "$still" ]; then
      bail "端口 ${port} 仍被 PID ${still} 占用且无法自动清理。请手动关闭该进程后重试（可能需要：kill -9 ${still}）"
    fi
    info "端口 ${port} 已释放"
  fi
done

step_log 3.3 "清理旧容器/网络（docker compose down）"
(cd "${PROJECT_ROOT}" && docker compose down >> "${DOCKER_LOG}" 2>&1 || true)
info "旧容器清理完成"

step_log 3.4 "执行 docker compose build"
(cd "${PROJECT_ROOT}" && docker compose build --progress plain 2>&1) >> "${DOCKER_LOG}" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  {
    echo ""
    echo "=== docker compose build 失败关键信息（最后 80 行） ==="
    tail -n 80 "${DOCKER_LOG}" | grep -i -E "error|failed|exit code|no such|cannot|JSONDecodeError|permission|E:Unable" || tail -n 40 "${DOCKER_LOG}"
  } >> "${DOCKER_LOG}_tail.log" 2>&1 || true
  ERR_HINT=$(tail -n 100 "${DOCKER_LOG}" 2>/dev/null | grep -i -E "error|failed|exit code|no such file|cannot|JSONDecodeError|permission" | head -n 8 | sed 's/^/        - /' || echo "        - （未提取到明显关键词，请查看完整日志）")
  bail "docker compose build 失败（exit=${rc}）。
      可能原因：
${ERR_HINT}
      请查看 ${DOCKER_LOG} 与 ${DOCKER_LOG}_tail.log 获取完整日志。"
fi
info "docker compose build 完成（backend + frontend 镜像）"

step_log 3.5 "启动容器（docker compose up -d）"
(cd "${PROJECT_ROOT}" && docker compose up -d 2>&1) >> "${DOCKER_LOG}" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  bail "docker compose up -d 启动失败（exit=${rc}），请查看 ${DOCKER_LOG}"
fi

step_log 3.6 "等待容器进入 running 状态（最长 20s）"
waited=0
RUNNING_OK=0
backend_state="unknown"
frontend_state="unknown"
while [ $waited -lt 20 ]; do
  statuses=$(cd "${PROJECT_ROOT}" && docker compose ps --format '{{.Service}}:{{.State}}' 2>/dev/null || true)
  backend_state=$(echo "$statuses" | grep -E "^backend:" | cut -d: -f2 || echo "unknown")
  frontend_state=$(echo "$statuses" | grep -E "^frontend:" | cut -d: -f2 || echo "unknown")
  if [ "$backend_state" = "running" ] && [ "$frontend_state" = "running" ]; then
    RUNNING_OK=1
    break
  fi
  sleep 1
  waited=$((waited + 1))
done
if [ $RUNNING_OK -ne 1 ]; then
  {
    echo "=== 容器未进入 running 状态 ==="
    echo "backend_state=${backend_state}"
    echo "frontend_state=${frontend_state}"
    echo "--- docker compose ps ---"
    (cd "${PROJECT_ROOT}" && docker compose ps 2>&1 || true)
    echo "--- backend 容器日志最后 80 行 ---"
    (cd "${PROJECT_ROOT}" && docker compose logs --tail 80 backend 2>&1 || true)
    echo "--- frontend 容器日志最后 80 行 ---"
    (cd "${PROJECT_ROOT}" && docker compose logs --tail 80 frontend 2>&1 || true)
  } >> "${DOCKER_LOG}" 2>&1
  bail "容器未在 20s 内全部进入 running：backend=${backend_state}, frontend=${frontend_state}。详情请查看 ${DOCKER_LOG}"
fi
info "容器状态：backend=running, frontend=running（等待 ${waited}s）"

step_log 3.7 "关键：等待容器内后端健康检查响应（最长 45s，避免服务未就绪报错）"
if ! wait_for_http "${BACKEND_URL}/api/health" 45; then
  {
    echo "=== 容器内后端未就绪，backend 容器日志（最后 120 行） ==="
    (cd "${PROJECT_ROOT}" && docker compose logs --tail 120 backend 2>&1 || true)
  } >> "${DOCKER_LOG}" 2>&1
  bail "容器内后端未就绪：${BACKEND_URL}/api/health 在 45s 内无响应。
      可能原因：
      - Dockerfile 中 pip/依赖安装有问题，应用启动崩溃；
      - uvicorn 监听地址错误（应为 0.0.0.0:8000）；
      - 应用导入路径错误或启动异常。
      请查看 ${DOCKER_LOG} 中 backend 容器日志。"
fi

step_log 3.8 "验证前端页面可访问（Nginx，最长 20s）"
if ! wait_for_http "${FRONTEND_URL}/" 20; then
  {
    echo "=== 容器内前端未就绪，frontend 容器日志（最后 120 行） ==="
    (cd "${PROJECT_ROOT}" && docker compose logs --tail 120 frontend 2>&1 || true)
  } >> "${DOCKER_LOG}" 2>&1
  bail "容器内前端未就绪：${FRONTEND_URL}/ 在 20s 内无响应。可能原因：
      - 前端 Dockerfile 中构建步骤失败，dist 目录为空；
      - Nginx 配置错误，/usr/share/nginx/html 下无文件；
      - Nginx 未正确监听 80 端口。
      请查看 ${DOCKER_LOG} 中 frontend 容器日志。"
fi

step_log 3.9 "通过容器验证后端业务接口"
declare -a DOCKER_APIS=(
  "${BACKEND_URL}/api/courts"
  "${BACKEND_URL}/api/members"
  "${BACKEND_URL}/api/time-slots"
  "${BACKEND_URL}/api/bookings"
)
for url in "${DOCKER_APIS[@]}"; do
  code="000"
  code=$(curl -s -o /tmp/accept_dock.json -w "%{http_code}" "$url" 2>/dev/null || code="000")
  if [ "$code" != "200" ]; then
    bail "容器内接口验证失败：${url} → HTTP ${code}，响应：$(cat /tmp/accept_dock.json 2>/dev/null)"
  fi
done
info "容器内 GET 接口（courts/members/time-slots/bookings）全部 200 OK"

step_log 3.10 "验证前端 HTML 入口正确性"
html_body=$(curl -s "${FRONTEND_URL}/" 2>/dev/null || echo "")
if ! echo "$html_body" | grep -q -E 'id=.root.|root|vite|React'; then
  bail "前端页面 HTML 异常：未检测到 id=root 或 vite/react 标记，可能是 Nginx 目录错误或构建产物未正确拷贝。"
fi
info "前端 HTML 包含入口节点，构建产物正确挂载"

step_log 3.11 "关闭容器，清理资源"
(cd "${PROJECT_ROOT}" && docker compose down >> "${DOCKER_LOG}" 2>&1 || true)
info "docker compose down 完成"

PASSED=$(( PASSED | 4 ))
info "阶段三 容器启动验证 通过 ✅"

end_report
exit 0
