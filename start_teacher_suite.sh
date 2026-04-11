#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$ROOT_DIR/backend"
TEACHER_DIR="$ROOT_DIR/teacher-desktop"
DEFAULT_BACKEND_PORT="${BACKEND_PORT:-8000}"

detect_lan_ip() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i !~ /^127\./) {print $i; exit}}')"
  if [[ -n "$ip" ]]; then
    printf '%s' "$ip"
    return 0
  fi

  ip="$(ip route get 1.1.1.1 2>/dev/null | awk 'match($0, /src ([0-9.]+)/, m) { print m[1]; exit }')"
  if [[ -n "$ip" ]]; then
    printf '%s' "$ip"
    return 0
  fi

  printf '%s' "${LAN_HOST:-10.212.19.217}"
}

PYTHON_BIN="${PYTHON_BIN:-/home/hp/Attea/.venv/bin/python}"
if [[ ! -x "$PYTHON_BIN" ]]; then
  PYTHON_BIN="${PYTHON_BIN_FALLBACK:-python3}"
fi

export SQLALCHEMY_DATABASE_URL="${SQLALCHEMY_DATABASE_URL:-postgresql://postgres:REDACTED@localhost:5432/attendance_db}"

LAN_HOST="$(detect_lan_ip)"
BACKEND_BIND_HOST="0.0.0.0"
BACKEND_PORT="${BACKEND_PORT:-8000}"

BACKEND_PID=""
cleanup() {
  if [[ -n "$BACKEND_PID" ]] && kill -0 "$BACKEND_PID" 2>/dev/null; then
    kill "$BACKEND_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "[1/3] Starting backend on http://${BACKEND_BIND_HOST}:${BACKEND_PORT} (bind address)"
echo "      Phone/student app should use http://${LAN_HOST}:${BACKEND_PORT}"
(
  cd "$BACKEND_DIR"
  "$PYTHON_BIN" -m uvicorn app.main:app --host "$BACKEND_BIND_HOST" --port "$BACKEND_PORT"
) >"$ROOT_DIR/backend.log" 2>&1 &
BACKEND_PID=$!

echo "[2/3] Installing teacher desktop dependencies (if needed)"
(
  cd "$TEACHER_DIR"
  npm install >/dev/null
)

echo "[3/3] Launching teacher desktop app"
(
  cd "$TEACHER_DIR"
  npm start
)
