#!/bin/zsh
# 双击启动实时换脸服务，并打开 Chrome。
# 关闭这个终端窗口 = 停止服务。

set -u
cd "$(dirname "$0")" || exit 1

PORT="${PORT:-8787}"
URL="http://127.0.0.1:${PORT}"
VENV_PY=".venv/bin/python"

echo ""
echo "  ┌─────────────────────────────────────────────┐"
echo "  │        实时换脸直播  ·  Live Face           │"
echo "  │        Deep-Live-Cam + CoreML               │"
echo "  └─────────────────────────────────────────────┘"
echo ""

if [ ! -x "$VENV_PY" ]; then
  echo "✗ 没有找到虚拟环境 .venv"
  echo "  请先在项目目录运行：python3.12 -m venv .venv && .venv/bin/pip install -r Deep-Live-Cam/requirements.txt"
  echo ""
  read -r "?按回车键退出…"
  exit 1
fi

MODELS_DIR="Deep-Live-Cam/models"
if [ -d "modules" ]; then MODELS_DIR="models"; fi
if [ ! -f "$MODELS_DIR/inswapper_128_fp16.onnx" ] && [ ! -f "$MODELS_DIR/inswapper_128.onnx" ]; then
  echo "⚠ 尚未找到 inswapper 模型，首次启动会自动从 HuggingFace 下载（约 277MB）。"
fi

# 如果服务已经在运行，直接打开浏览器
if curl -s --max-time 1 "${URL}/api/state" >/dev/null 2>&1; then
  echo "✓ 服务已经在运行，直接打开浏览器"
  open -a "Google Chrome" "$URL" 2>/dev/null || open "$URL"
  exit 0
fi

# 防止直播过程中 Mac 休眠（可选，设置 NO_CAFFEINATE=1 关闭）
CAFFEINATE_PID=""
if [ "${NO_CAFFEINATE:-0}" != "1" ] && command -v caffeinate >/dev/null 2>&1; then
  caffeinate -dims -w $$ >/dev/null 2>&1 &
  CAFFEINATE_PID=$!
fi

"$VENV_PY" web_server.py --port "$PORT" &
SERVER_PID=$!

cleanup() {
  echo ""
  echo "正在停止服务…"
  kill "$SERVER_PID" 2>/dev/null
  [ -n "$CAFFEINATE_PID" ] && kill "$CAFFEINATE_PID" 2>/dev/null
  wait "$SERVER_PID" 2>/dev/null
  exit 0
}
trap cleanup INT TERM HUP

echo "启动服务中（模型已在后台加载）…"
OPENED=0
for i in {1..120}; do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "✗ 服务进程已退出，请查看上方错误信息"
    wait "$SERVER_PID"
    exit 1
  fi
  if curl -s --max-time 1 "${URL}/api/state" >/dev/null 2>&1; then
    if [ "$OPENED" = "0" ]; then
      echo ""
      echo "✓ 服务已就绪：${URL}"
      echo "  首次启动会在页面里显示「编译 CoreML 模型」，约 1–3 分钟。"
      echo "  保持这个终端窗口打开；按 Ctrl+C 或关闭窗口即可停止。"
      echo ""
      open -a "Google Chrome" "$URL" 2>/dev/null || open "$URL"
      OPENED=1
    fi
    break
  fi
  sleep 0.5
done

if [ "$OPENED" = "0" ]; then
  echo "⚠ 等待服务超时，请手动打开 ${URL}"
fi

wait "$SERVER_PID"
STATUS=$?
[ -n "$CAFFEINATE_PID" ] && kill "$CAFFEINATE_PID" 2>/dev/null
echo "服务已退出（code ${STATUS}）"
