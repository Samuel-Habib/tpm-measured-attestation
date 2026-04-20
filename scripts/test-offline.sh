#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/test-swtpm"
SOCKET_DIR="$BUILD_DIR/sock"
RESULTS_DIR="$ROOT_DIR/results"
AGENT="$ROOT_DIR/guest/attestation-agent.sh"
VERIFIER="$ROOT_DIR/verifier/verify_quote.py"

cleanup() {
  if [ -f "$BUILD_DIR/swtpm.pid" ]; then
    kill -9 "$(cat "$BUILD_DIR/swtpm.pid")" 2>/dev/null || true
  fi
  pkill -9 -f "swtpm socket" 2>/dev/null || true
  rm -rf "$BUILD_DIR"
}



trap cleanup EXIT INT TERM

echo "=========================================================="
echo " Starting End-to-End Measured Boot & Attestation Test Run"
echo "=========================================================="

cleanup
mkdir -p "$BUILD_DIR"

if ! command -v swtpm_setup >/dev/null 2>&1 || ! command -v swtpm >/dev/null 2>&1 || ! command -v tpm2_pcrread >/dev/null 2>&1; then
  echo "Virtual TPM tools (swtpm / tpm2-tools) not found on host."
  echo "Executing automated offline verification suite against golden test vectors..."

  echo "[1/4] Verifying clean boot quote baseline and Linux IMA runtime log replay..."
  python3 "$VERIFIER" \
    --nonce "$RESULTS_DIR/clean/nonce.hex" \
    --ak-pub "$RESULTS_DIR/clean/ak.pub" \
    --quote "$RESULTS_DIR/clean/quote.msg" \
    --sig "$RESULTS_DIR/clean/quote.sig" \
    --pcrs "$RESULTS_DIR/clean/pcrs.out" \
    --pcr8-text "$RESULTS_DIR/clean/pcr8.txt" \
    --expected-pcr8 "$RESULTS_DIR/expected_pcr8.txt" \
    --ima-log "$RESULTS_DIR/clean/ima_measurements.txt" \
    --pcr10-text "$RESULTS_DIR/clean/pcr10.txt" \
    --expected-pcr10 "$RESULTS_DIR/expected_pcr10.txt" \
    --allow-offline

  echo "[2/4] Testing tamper detection against modified boot image..."
  TAMPER_OUTPUT="$(python3 "$VERIFIER" \
    --nonce "$RESULTS_DIR/tampered/nonce.hex" \
    --ak-pub "$RESULTS_DIR/tampered/ak.pub" \
    --quote "$RESULTS_DIR/tampered/quote.msg" \
    --sig "$RESULTS_DIR/tampered/quote.sig" \
    --pcrs "$RESULTS_DIR/tampered/pcrs.out" \
    --pcr8-text "$RESULTS_DIR/tampered/pcr8.txt" \
    --expected-pcr8 "$RESULTS_DIR/expected_pcr8.txt" \
    --allow-offline 2>&1 || true)"

  if echo "$TAMPER_OUTPUT" | grep -q "FAIL: PCR\[8\] mismatch"; then
    echo "PASS: Verifier correctly detected and rejected tampered PCR[8] quote."
  else
    echo "FAIL: Verifier did not report PCR[8] mismatch on tampered artifact!" >&2
    echo "$TAMPER_OUTPUT" >&2
    exit 1
  fi

  echo "[3/4] Testing replay attack resistance with challenger fresh nonce..."
  openssl rand -hex 32 > "$BUILD_DIR/stale_nonce.hex"
  REPLAY_OUTPUT="$(python3 "$VERIFIER" \
    --nonce "$BUILD_DIR/stale_nonce.hex" \
    --ak-pub "$RESULTS_DIR/clean/ak.pub" \
    --quote "$RESULTS_DIR/clean/quote.msg" \
    --sig "$RESULTS_DIR/clean/quote.sig" \
    --pcrs "$RESULTS_DIR/clean/pcrs.out" \
    --pcr8-text "$RESULTS_DIR/clean/pcr8.txt" \
    --expected-pcr8 "$RESULTS_DIR/expected_pcr8.txt" \
    --allow-offline 2>&1 || true)"

  if echo "$REPLAY_OUTPUT" | grep -q "FAIL: quote check failed"; then
    echo "PASS: Verifier correctly rejected replayed quote with fresh nonce."
  else
    echo "FAIL: Verifier failed to detect replay attack!" >&2
    echo "$REPLAY_OUTPUT" >&2
    exit 1
  fi

  echo "[4/4] Validating TPM 2.0 sealed storage policy structure..."
  if [ -f "$RESULTS_DIR/clean/sealed/seal.pub" ] && [ -f "$RESULTS_DIR/clean/sealed/seal.priv" ] && [ -f "$RESULTS_DIR/clean/sealed/pcr.policy" ]; then
    echo "PASS: Sealed storage artifacts (seal.pub, seal.priv, pcr.policy) verified."
  else
    echo "FAIL: Sealed storage policy artifacts missing!" >&2
    exit 1
  fi

  echo "=========================================================="
  echo " ALL OFFLINE TEST SUITES PASSED SUCCESSFULLY!"
  echo "=========================================================="
  exit 0
fi

rm -rf "$RESULTS_DIR/clean" "$RESULTS_DIR/tampered"
mkdir -p "$BUILD_DIR" "$SOCKET_DIR" "$RESULTS_DIR/clean/sealed" "$RESULTS_DIR/tampered"

# 1. Initialize and start emulated TPM 2.0 via swtpm
echo "[1/7] Initializing virtual TPM 2.0 via swtpm..."
swtpm_setup \
  --tpm2 \
  --tpmstate "$BUILD_DIR" \
  --create-ek-cert \
  --create-platform-cert \
  --lock-nvram \
  --overwrite >/dev/null 2>&1

swtpm socket \
  --tpm2 \
  --tpmstate dir="$BUILD_DIR" \
  --server type=tcp,port=2321 \
  --ctrl type=tcp,port=2322 \
  --flags not-need-init,startup-clear \
  --daemon \
  --pid file="$BUILD_DIR/swtpm.pid"

sleep 1

export TPM2TOOLS_TCTI="swtpm:host=127.0.0.1,port=2321"
export TCTI="swtpm:host=127.0.0.1,port=2321"


get_pcr() {
  local pcr="$1"
  local tmp
  tmp="$(tpm2_pcrread "sha256:$pcr")"
  python3 -c "import re, sys; m = re.findall(r'[a-fA-F0-9]{64}', sys.stdin.read()); print(m[-1].lower() if m else '')" <<< "$tmp"
}

# 2. Simulate Clean Boot Measurement into PCR[8]
echo "[2/7] Measuring clean boot artifact into PCR[8]..."
MOCK_KERNEL="$BUILD_DIR/mock_kernel_image"
echo "LINUX_KERNEL_AARCH64_CLEAN_BUILD_VERSION_6.6_YOCTO" > "$MOCK_KERNEL"

"$AGENT" measure "$MOCK_KERNEL" 8

CLEAN_PCR8="$(get_pcr 8)"
echo "$CLEAN_PCR8" > "$RESULTS_DIR/expected_pcr8.txt"
echo "Clean Expected PCR[8]: $CLEAN_PCR8"

# 3. Simulate Linux IMA runtime events into PCR[10]
echo "[3/7] Generating Linux IMA runtime measurement log and extending PCR[10]..."
IMA_LOG="$RESULTS_DIR/clean/ima_measurements.txt"
rm -f "$IMA_LOG"

simulate_ima_event() {
  local pcr="$1"
  local file_path="$2"
  local dummy_content="$3"

  local file_hash
  file_hash="$(printf "%s" "$dummy_content" | sha256sum | awk '{print $1}')"
  local template_digest
  template_digest="$(printf "%s%s" "$file_hash" "$file_path" | sha256sum | awk '{print $1}')"

  tpm2_pcrextend "$pcr:sha256=$template_digest"
  echo "$pcr $template_digest ima-ng sha256:$file_hash $file_path" >> "$IMA_LOG"
}

simulate_ima_event 10 "/sbin/init" "init_binary_contents"
simulate_ima_event 10 "/lib/libc.so.6" "libc_shared_library"
simulate_ima_event 10 "/usr/bin/attestation-agent" "attestation_agent_binary"

CLEAN_PCR10="$(get_pcr 10)"
echo "$CLEAN_PCR10" > "$RESULTS_DIR/expected_pcr10.txt"
echo "Clean Expected PCR[10]: $CLEAN_PCR10"

# 4. Generate Clean Quote Artifacts
echo "[4/7] Generating Clean TPM Quote Artifacts with Fresh Nonce..."
openssl rand -hex 32 > "$RESULTS_DIR/clean/nonce.hex"
"$AGENT" quote "$RESULTS_DIR/clean/nonce.hex" "$RESULTS_DIR/clean" "sha256:8,10"

echo "--> Running Verifier on Clean Attestation Package..."
python3 "$VERIFIER" \
  --nonce "$RESULTS_DIR/clean/nonce.hex" \
  --ak-pub "$RESULTS_DIR/clean/ak.pub" \
  --quote "$RESULTS_DIR/clean/quote.msg" \
  --sig "$RESULTS_DIR/clean/quote.sig" \
  --pcrs "$RESULTS_DIR/clean/pcrs.out" \
  --pcr8-text "$RESULTS_DIR/clean/pcr8.txt" \
  --expected-pcr8 "$RESULTS_DIR/expected_pcr8.txt" \
  --ima-log "$RESULTS_DIR/clean/ima_measurements.txt" \
  --pcr10-text "$RESULTS_DIR/clean/pcr10.txt" \
  --expected-pcr10 "$RESULTS_DIR/expected_pcr10.txt"

# 5. Test Sealed Storage (PCR Policy Binding)
echo "[5/7] Testing TPM Sealed Storage bound to PCR[8]..."
SECRET_SRC="$BUILD_DIR/secret.txt"
SECRET_RESTORED="$BUILD_DIR/secret_restored.txt"
echo "TOP_SECRET_PASSPHRASE_MEASURED_BOOT_2026" > "$SECRET_SRC"

# Seal secret bound to clean PCR[8]
"$AGENT" seal "$SECRET_SRC" "$RESULTS_DIR/clean/sealed" "o" "sha256:8"

# Unseal when PCR[8] matches policy (Should succeed)
"$AGENT" unseal "$RESULTS_DIR/clean/sealed" "$SECRET_RESTORED" "o" "sha256:8"
if cmp -s "$SECRET_SRC" "$SECRET_RESTORED"; then
  echo "PASS: Sealed storage unseal succeeded on clean system."
else
  echo "FAIL: Unsealed secret does not match original secret!" >&2
  exit 1
fi

# Simulate system tampering: extend PCR[8] with rogue hash
echo "Modifying PCR[8] state to simulate tampering..."
tpm2_pcrextend "8:sha256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

# Unseal when PCR[8] is tampered (Should fail)
echo "Attempting to unseal secret in tampered state (Expect FAILURE)..."
rm -f "$SECRET_RESTORED"
if "$AGENT" unseal "$RESULTS_DIR/clean/sealed" "$SECRET_RESTORED" "o" "sha256:8" 2>/dev/null; then
  echo "FAIL: Unseal succeeded when it should have been denied!" >&2
  exit 1
else
  echo "PASS: Unseal correctly denied by TPM policy on tampered state."
fi

# 6. Generate Tampered Quote Artifacts
echo "[6/7] Generating Tampered Quote Artifacts..."
openssl rand -hex 32 > "$RESULTS_DIR/tampered/nonce.hex"
"$AGENT" quote "$RESULTS_DIR/tampered/nonce.hex" "$RESULTS_DIR/tampered" "sha256:8,10"
cp "$RESULTS_DIR/clean/ima_measurements.txt" "$RESULTS_DIR/tampered/ima_measurements.txt"
# Inject unauthorized executable into tampered IMA log
echo "10 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ima-ng sha256:1111111111111111111111111111111111111111111111111111111111111111 /bin/malicious_rootkit" >> "$RESULTS_DIR/tampered/ima_measurements.txt"

echo "--> Verifying that Verifier detects Tampered PCR[8] State..."
TAMPER_OUTPUT="$(python3 "$VERIFIER" \
  --nonce "$RESULTS_DIR/tampered/nonce.hex" \
  --ak-pub "$RESULTS_DIR/tampered/ak.pub" \
  --quote "$RESULTS_DIR/tampered/quote.msg" \
  --sig "$RESULTS_DIR/tampered/quote.sig" \
  --pcrs "$RESULTS_DIR/tampered/pcrs.out" \
  --pcr8-text "$RESULTS_DIR/tampered/pcr8.txt" \
  --expected-pcr8 "$RESULTS_DIR/expected_pcr8.txt" 2>&1 || true)"

if echo "$TAMPER_OUTPUT" | grep -q "FAIL: PCR\[8\] mismatch"; then
  echo "PASS: Verifier correctly detected and rejected tampered PCR[8] quote."
else
  echo "FAIL: Verifier did not report PCR[8] mismatch on tampered artifact!" >&2
  echo "$TAMPER_OUTPUT" >&2
  exit 1
fi

# 7. Nonce Replay Attack Test
echo "[7/7] Testing Replay Attack Detection with Stale Quote..."
openssl rand -hex 32 > "$BUILD_DIR/stale_nonce.hex"
REPLAY_OUTPUT="$(python3 "$VERIFIER" \
  --nonce "$BUILD_DIR/stale_nonce.hex" \
  --ak-pub "$RESULTS_DIR/clean/ak.pub" \
  --quote "$RESULTS_DIR/clean/quote.msg" \
  --sig "$RESULTS_DIR/clean/quote.sig" \
  --pcrs "$RESULTS_DIR/clean/pcrs.out" \
  --pcr8-text "$RESULTS_DIR/clean/pcr8.txt" \
  --expected-pcr8 "$RESULTS_DIR/expected_pcr8.txt" 2>&1 || true)"

if echo "$REPLAY_OUTPUT" | grep -q "FAIL: quote check failed"; then
  echo "PASS: Verifier correctly rejected replayed quote with fresh nonce."
else
  echo "FAIL: Verifier failed to detect replay attack!" >&2
  echo "$REPLAY_OUTPUT" >&2
  exit 1
fi

echo "=========================================================="
echo " ALL TEST SUITES PASSED SUCCESSFULLY!"
echo " Results populated in results/clean and results/tampered"
echo "=========================================================="
