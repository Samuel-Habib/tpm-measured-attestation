#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATE_DIR="${SWTPM_STATE_DIR:-$ROOT_DIR/build/swtpm-state}"
SOCKET_PATH="${SWTPM_SOCKET:-$STATE_DIR/swtpm-sock}"

QEMU_BIN="${QEMU_BIN:-qemu-system-aarch64}"
MEMORY="${QEMU_MEMORY:-1024}"
CPU="${QEMU_CPU:-cortex-a57}"
QEMU_CMDLINE="${QEMU_CMDLINE:-console=ttyAMA0 root=/dev/vda rw}"

if [ ! -S "$SOCKET_PATH" ]; then
  echo "TPM socket not found: $SOCKET_PATH"
  echo "Run ./scripts/start-swtpm.sh first."
  exit 1
fi

TPM_ARGS="-chardev socket,id=chrtpm,path=$SOCKET_PATH -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis-device,tpmdev=tpm0"
DRIVE_ARGS="-drive file=$QEMU_ROOTFS,format=raw,if=virtio"

if [ -n "${QEMU_UBOOT:-}" ]; then
  echo "Booting qemuarm64 via U-Boot firmware: $QEMU_UBOOT"
  # shellcheck disable=SC2086
  exec "$QEMU_BIN" \
    -machine virt \
    -cpu "$CPU" \
    -m "$MEMORY" \
    -nographic \
    -bios "$QEMU_UBOOT" \
    $DRIVE_ARGS \
    $TPM_ARGS
elif [ -n "${QEMU_KERNEL:-}" ]; then
  echo "Booting qemuarm64 via direct Linux kernel: $QEMU_KERNEL"
  # shellcheck disable=SC2086
  exec "$QEMU_BIN" \
    -machine virt \
    -cpu "$CPU" \
    -m "$MEMORY" \
    -nographic \
    -kernel "$QEMU_KERNEL" \
    -append "$QEMU_CMDLINE" \
    $DRIVE_ARGS \
    $TPM_ARGS
else
  echo "Error: Either QEMU_UBOOT or QEMU_KERNEL must be specified." >&2
  echo "Example U-Boot: export QEMU_UBOOT=/path/to/u-boot.bin; export QEMU_ROOTFS=/path/to/rootfs.ext4" >&2
  echo "Example Direct: export QEMU_KERNEL=/path/to/Image; export QEMU_ROOTFS=/path/to/rootfs.ext4" >&2
  exit 1
fi

