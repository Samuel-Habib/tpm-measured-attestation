#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATE_DIR="${SWTPM_STATE_DIR:-$ROOT_DIR/build/swtpm-state}"
SOCKET_PATH="${SWTPM_SOCKET:-$STATE_DIR/swtpm-sock}"
PID_FILE="${SWTPM_PID_FILE:-$STATE_DIR/swtpm.pid}"

mkdir -p "$STATE_DIR"

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "swtpm is already running with PID $(cat "$PID_FILE")"
  exit 0
fi

rm -f "$SOCKET_PATH"

if [ ! -f "$STATE_DIR/tpm2-00.permall" ]; then
  echo "Initializing TPM state in $STATE_DIR"
  swtpm_setup \
    --tpm2 \
    --tpmstate "$STATE_DIR" \
    --create-ek-cert \
    --create-platform-cert \
    --lock-nvram \
    --overwrite
fi

echo "Starting swtpm on $SOCKET_PATH"
swtpm socket \
  --tpm2 \
  --tpmstate dir="$STATE_DIR" \
  --ctrl type=unixio,path="$SOCKET_PATH" \
  --log level=20 \
  --daemon \
  --pid file="$PID_FILE"

echo "swtpm started"
echo "Socket: $SOCKET_PATH"
