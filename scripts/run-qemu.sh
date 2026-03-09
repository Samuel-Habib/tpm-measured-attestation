#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATE_DIR="${SWTPM_STATE_DIR:-$ROOT_DIR/build/swtpm-state}"
SOCKET_PATH="${SWTPM_SOCKET:-$STATE_DIR/swtpm-sock}"

: "${QEMU_KERNEL:?Set QEMU_KERNEL to the Yocto qemuarm64 kernel Image path}"
: "${QEMU_ROOTFS:?Set QEMU_ROOTFS to the Yocto qemuarm64 rootfs ext4 path}"

QEMU_BIN="${QEMU_BIN:-qemu-system-aarch64}"
MEMORY="${QEMU_MEMORY:-1024}"
CPU="${QEMU_CPU:-cortex-a57}"

if [ ! -S "$SOCKET_PATH" ]; then
  echo "TPM socket not found: $SOCKET_PATH"
  echo "Start swtpm first using: make start-tpm"
  exit 1
fi

exec "$QEMU_BIN" \
  -machine virt \
  -cpu "$CPU" \
  -m "$MEMORY" \
  -nographic \
  -kernel "$QEMU_KERNEL" \
  -append "console=ttyAMA0 root=/dev/vda rw" \
  -drive "file=$QEMU_ROOTFS,format=raw,if=virtio" \
  -chardev "socket,id=chrtpm,path=$SOCKET_PATH" \
  -tpmdev "emulator,id=tpm0,chardev=chrtpm" \
  -device "tpm-tis-device,tpmdev=tpm0"
