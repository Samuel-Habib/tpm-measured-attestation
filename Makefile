SHELL := /bin/sh

.PHONY: help start-tpm stop-tpm

help:
	@echo "Targets:"
	@echo "  make start-tpm       Start swtpm"
	@echo "  make stop-tpm        Stop swtpm"

start-tpm:
	./scripts/start-swtpm.sh

stop-tpm:
	./scripts/stop-swtpm.sh
