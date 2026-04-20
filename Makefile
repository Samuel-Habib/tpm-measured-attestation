SHELL := /bin/sh

.PHONY: help start-tpm stop-tpm run-qemu verify-clean verify-tampered verify-ima test-all test-offline

help:
	@echo "Targets:"
	@echo "  make start-tpm       Start swtpm"
	@echo "  make stop-tpm        Stop swtpm"
	@echo "  make run-qemu        Boot QEMU using QEMU_KERNEL/QEMU_UBOOT and QEMU_ROOTFS"
	@echo "  make verify-clean    Verify results/clean against results/expected_pcr8.txt"
	@echo "  make verify-tampered Verify results/tampered against results/expected_pcr8.txt"
	@echo "  make verify-ima      Verify results/clean quote and replay IMA measurement log"
	@echo "  make test-all        Run full automated test suite (clean, tampered, replay, IMA, sealed storage)"

start-tpm:
	./scripts/start-swtpm.sh

stop-tpm:
	./scripts/stop-swtpm.sh

run-qemu:
	./scripts/run-qemu.sh

verify-clean:
	python3 verifier/verify_quote.py \
	  --nonce results/clean/nonce.hex \
	  --ak-pub results/clean/ak.pub \
	  --quote results/clean/quote.msg \
	  --sig results/clean/quote.sig \
	  --pcrs results/clean/pcrs.out \
	  --pcr8-text results/clean/pcr8.txt \
	  --expected-pcr8 results/expected_pcr8.txt

verify-tampered:
	python3 verifier/verify_quote.py \
	  --nonce results/tampered/nonce.hex \
	  --ak-pub results/tampered/ak.pub \
	  --quote results/tampered/quote.msg \
	  --sig results/tampered/quote.sig \
	  --pcrs results/tampered/pcrs.out \
	  --pcr8-text results/tampered/pcr8.txt \
	  --expected-pcr8 results/expected_pcr8.txt

verify-ima:
	python3 verifier/verify_quote.py \
	  --nonce results/clean/nonce.hex \
	  --ak-pub results/clean/ak.pub \
	  --quote results/clean/quote.msg \
	  --sig results/clean/quote.sig \
	  --pcrs results/clean/pcrs.out \
	  --pcr8-text results/clean/pcr8.txt \
	  --expected-pcr8 results/expected_pcr8.txt \
	  --ima-log results/clean/ima_measurements.txt \
	  --pcr10-text results/clean/pcr10.txt \
	  --expected-pcr10 results/expected_pcr10.txt

test-all:
	./scripts/test-offline.sh

test-offline: test-all
