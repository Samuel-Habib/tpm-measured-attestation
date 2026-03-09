SHELL := /bin/sh

.PHONY: help start-tpm stop-tpm run-qemu

help:
	@echo "Targets:"
	@echo "  make start-tpm       Start swtpm"
	@echo "  make stop-tpm        Stop swtpm"
	@echo "  make run-qemu        Boot QEMU using QEMU_KERNEL and QEMU_ROOTFS"

start-tpm:
	./scripts/start-swtpm.sh

stop-tpm:
	./scripts/stop-swtpm.sh

run-qemu:
	./scripts/run-qemu.sh
