#!/usr/bin/env bash
# capcut-mcp 一鍵重建腳本（實測可行配方）
#
# 為什麼需要它：這個遠端開發環境是臨時容器，只有 git 內容跨重啟保留；
# 手動裝的 capcut-mcp / ffmpeg / 字型在容器回收後都會消失。把重建步驟放進 repo，
# 任何新 session 只要跑這支就能把整套影片工具鏈裝回來。
#
# 這個 repo（fancyboi999/capcut-mcp）沒有鎖任何相依版本，程式碼是對 2025 年中的
# fastapi / mcp / pydantic 快照寫的，直接 pip install 會踩到一連串版本不相容：
#   - crcmod（oss2 的相依）在新 Python 編不過
#   - mcp 2.x 改了 Server() 簽章，fastapi-mcp 0.3.4 不相容
#   - mcp 1.9.4 又在 pydantic 2.11+ 觸發 RequestParams.Meta 錯誤
# 因此這裡用「乾淨 venv + 完整鎖版本」，並用 oss2 替身模組跳過用不到的 OSS 上傳。
#
# 用法：  bash scripts/setup-capcut-mcp.sh
# 完成後：cd ~/capcut-mcp && .venv/bin/python main.py   （伺服器跑在 :9000）

set -euo pipefail

CLONE_DIR="${CAPCUT_DIR:-$HOME/capcut-mcp}"
PORT=9000
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> 1/6 安裝系統相依（ffmpeg + Noto CJK TC 字型，供影片渲染/燒字幕）"
if ! command -v ffmpeg >/dev/null 2>&1; then
  (apt-get update -y && apt-get install -y ffmpeg fonts-noto-cjk) >/dev/null 2>&1 || \
    echo "  (略過 apt：非 Debian/Ubuntu 或無權限，請自行確認 ffmpeg 已安裝)"
else
  echo "  ffmpeg 已存在"
fi

echo "==> 2/6 取得 capcut-mcp 原始碼"
if [ ! -d "$CLONE_DIR/.git" ]; then
  git clone --depth 1 https://github.com/fancyboi999/capcut-mcp.git "$CLONE_DIR"
else
  git -C "$CLONE_DIR" pull --ff-only || true
fi
cd "$CLONE_DIR"

echo "==> 3/6 設定 config.json（埠 $PORT，不上傳 OSS）"
[ -f config.json ] || cp config.json.example config.json
python3 - "$PORT" <<'PY'
import json, sys
d = json.load(open("config.json"))
d["port"] = int(sys.argv[1])
d["is_upload_draft"] = False
json.dump(d, open("config.json", "w"), indent=2)
print("  port =", d["port"], "| is_upload_draft =", d["is_upload_draft"])
PY

echo "==> 4/6 建立 oss2 替身模組（is_upload_draft=false，永不上傳；免裝編不過的 oss2/crcmod）"
cat > oss2.py <<'PY'
# oss2 替身：本專案不上傳 OSS，oss.py 僅頂層 import oss2，實際 Auth/Bucket 只在上傳函式內用到。
class _Disabled:
    def __init__(self, *a, **k): pass
    def __getattr__(self, name):
        def _raise(*a, **k):
            raise NotImplementedError("oss2 stub：未安裝真 oss2 且 is_upload_draft=false。")
        return _raise
class Auth(_Disabled): pass
class AuthV4(_Disabled): pass
class Bucket(_Disabled): pass
PY

echo "==> 5/6 建立 venv 並安裝鎖定版本（與 fastapi-mcp 0.3.4 相容的一致組合）"
python3 -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q \
  "pydantic==2.10.6" "pydantic-settings==2.7.1" "fastapi==0.115.12" \
  "mcp==1.9.4" "fastapi-mcp==0.3.4" "uvicorn==0.34.2" \
  imageio psutil requests
echo "  venv 依賴安裝完成"
.venv/bin/python -c "from app import create_app; create_app(); print('  app 匯入驗證 OK')"

echo "==> 6/6 寫回 Claude Code 本地 MCP 設定 .mcp.json（SSE 傳輸）"
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
echo "完成。啟動伺服器（背景）："
echo "  cd $CLONE_DIR && .venv/bin/python main.py"
echo "驗證：curl -s -o /dev/null -w '%{http_code}' http://localhost:$PORT/docs   # 應為 200"
echo "注意：fastapi-mcp 0.3.4 用 SSE 傳輸，Claude 設定必須是 \"type\": \"sse\"（非官方 README 的 \"http\"）。"
echo "伺服器起來後，開新的 Claude Code session 即可載入 capcut-mcp。"
