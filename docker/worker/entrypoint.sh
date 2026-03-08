#!/bin/sh
set -eu

Xvfb "${DISPLAY:-:99}" -screen 0 1920x1080x24 &
XVFB_PID=$!

cleanup() {
  kill "$XVFB_PID" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

exec python /app/worker.py
