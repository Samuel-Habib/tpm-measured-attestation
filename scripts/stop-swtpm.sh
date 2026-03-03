#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATE_DIR="${SWTPM_STATE_DIR:-$ROOT_DIR/build/swtpm-state}"
PID_FILE="${SWTPM_PID_FILE:-$STATE_DIR/swtpm.pid}"

if [ ! -f "$PID_FILE" ]; then
  echo "No swtpm PID file found."
  exit 0
fi

PID="$(cat "$PID_FILE")"

if kill -0 "$PID" 2>/dev/null; then
  kill "$PID"
  echo "Stopped swtpm PID $PID"
else
  echo "swtpm PID $PID was not running."
fi

rm -f "$PID_FILE"
