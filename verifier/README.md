# Host-Side Remote Verifier

`verify_quote.py` validates TPM quote packages received from the target system.

Requirements:
* Python 3.10+
* `tpm2-tools` (`tpm2_checkquote`) on the host system (or `--allow-offline` for simulated environments)

---

## Verification Modes

### 1. Clean Boot & IMA Log Replay
Validates AK quote signature, freshness nonce, PCR[8] baseline, and recalculates the cumulative PCR[10] hash from the ASCII IMA measurement log:
```sh
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
```

### 2. Tamper Detection Test
Verifies that modified boot measurements cause verification to fail:
```sh
python3 verifier/verify_quote.py \
  --nonce results/tampered/nonce.hex \
  --ak-pub results/tampered/ak.pub \
  --quote results/tampered/quote.msg \
  --sig results/tampered/quote.sig \
  --pcrs results/tampered/pcrs.out \
  --pcr8-text results/tampered/pcr8.txt \
  --expected-pcr8 results/expected_pcr8.txt
```
Expected output:
```text
FAIL: PCR[8] mismatch
```

### 3. Offline / CI Simulation Mode
When `tpm2_checkquote` is not installed on the host, pass `--allow-offline` to validate the quote structure and nonce freshness directly via binary parsing.
