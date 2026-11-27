#!/bin/zsh
# LiveFace integrated install (public fork, no submodule).
set -euo pipefail
cd "$(dirname "$0")"
echo "LiveFace Studio · 独立整合版安装"
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "✗ 需要 Xcode Command Line Tools：xcode-select --install"; exit 1
fi
PYTHON=""
for candidate in python3.12 python3; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 12) else 1)' 2>/dev/null; then
    PYTHON="$candidate"; break
  fi
done
if [ -z "$PYTHON" ]; then
  echo "✗ 需要 Python 3.12（例如 brew install python@3.12）"; exit 1
fi
[ -x .venv/bin/python ] || "$PYTHON" -m venv .venv
.venv/bin/pip install -r requirements.txt -r requirements-web.txt
./make_app.sh --install
echo
echo "✓ 已安装到 ~/Applications/LiveFace.app"
echo "  首次启动自动下载模型（约 1.2GB）并编译 CoreML，通常 1–3 分钟。"
