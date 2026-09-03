#!/usr/bin/env bash
# capcut-mcp 一鍵重建腳本
#
# 為什麼需要它：這個遠端開發環境是臨時容器，只有 git 內容跨重啟保留；
# 手動裝的 capcut-mcp / ffmpeg / 字型在容器回收後都會消失。把重建步驟放進 repo，
# 任何新 session 只要跑這支就能把整套影片工具鏈裝回來。
#
# 用法：  bash scripts/setup-capcut-mcp.sh
# 完成後 capcut-mcp 伺服器會跑在 http://localhost:9000

set -euo pipefail

CLONE_DIR="${CAPCUT_DIR:-$HOME/capcut-mcp}"
PORT=9000
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> 1/5 安裝系統相依（ffmpeg + Noto CJK TC 字型）"
if ! command -v ffmpeg >/dev/null 2>&1; then
  (apt-get update -y && apt-get install -y ffmpeg fonts-noto-cjk) >/dev/null 2>&1 || \
    echo "  (略過 apt：非 Debian/Ubuntu 或無權限，請自行確認 ffmpeg 已安裝)"
else
  echo "  ffmpeg 已存在"
fi

echo "==> 2/5 取得 capcut-mcp 原始碼"
if [ ! -d "$CLONE_DIR/.git" ]; then
  git clone --depth 1 https://github.com/fancyboi999/capcut-mcp.git "$CLONE_DIR"
else
  git -C "$CLONE_DIR" pull --ff-only || true
fi

echo "==> 3/5 設定 config.json（埠 $PORT）"
cd "$CLONE_DIR"
[ -f config.json ] || cp config.json.example config.json
python3 - "$PORT" <<'PY'
import json, sys
p = "config.json"
d = json.load(open(p))
d["port"] = int(sys.argv[1])
json.dump(d, open(p, "w"), indent=2)
print("  port =", d["port"])
PY

echo "==> 4/5 安裝 Python 相依（fastapi-mcp 釘 0.3.4，與本專案程式相容）"
pip install -r requirements.txt >/dev/null
pip install "fastapi-mcp==0.3.4" >/dev/null
echo "  依賴安裝完成"

echo "==> 5/5 寫回 Claude Code 的本地 MCP 設定 .mcp.json（SSE 傳輸）"
cat > "$REPO_ROOT/.mcp.json" <<JSON
{
  "mcpServers": {
    "capcut-mcp": {
      "type": "sse",
      "url": "http://localhost:$PORT/mcp"
    }
  }
}
JSON
echo "  已寫入 $REPO_ROOT/.mcp.json（此檔已被 .gitignore 忽略）"

echo
echo "完成。啟動伺服器："
echo "  cd $CLONE_DIR && python3 main.py"
echo "伺服器起來後，開新的 Claude Code session 即可載入 capcut-mcp（type: sse）。"
echo "注意：fastapi-mcp 0.3.4 用 SSE 傳輸，Claude 設定要用 \"type\": \"sse\"（不是官方 README 的 \"http\"）。"
