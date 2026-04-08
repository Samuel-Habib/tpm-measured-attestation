#!/usr/bin/env sh
set -eu

PCR_INDEX="${PCR_INDEX:-8}"
PCR_BANK="${PCR_BANK:-sha256}"
PCR_SELECTION="${PCR_SELECTION:-sha256:8,10}"
HIERARCHY="${HIERARCHY:-o}"
IMA_SYSFS_LOG="/sys/kernel/security/ima/ascii_runtime_measurements"

usage() {
  cat <<EOF
Usage:
  attestation-agent measure <artifact-path> [pcr-index]
  attestation-agent quote <nonce-hex-file> <output-dir> [pcr-selection]
  attestation-agent ima-log <output-file>

Commands:
  measure   Hash an artifact and extend the digest into PCR[8] (or specified index).
  quote     Create/load an Attestation Key and generate quote artifacts for PCR selection.
  ima-log   Extract Linux IMA runtime measurement log from securityfs.

Environment:
  PCR_INDEX      Default PCR index for measure (Default: 8)
  PCR_BANK       PCR hash bank (Default: sha256)
  PCR_SELECTION  Default PCR list for quoting (Default: sha256:8,10)
  HIERARCHY      TPM authorization hierarchy (Default: o)
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

normalize_hex() {
  tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'
}

measure_artifact() {
  ARTIFACT="$1"
  TARGET_PCR="${2:-$PCR_INDEX}"

  require_cmd sha256sum
  require_cmd tpm2_pcrextend
  require_cmd tpm2_pcrread

  if [ ! -f "$ARTIFACT" ]; then
    echo "Artifact not found: $ARTIFACT" >&2
    exit 1
  fi

  HASH="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
  echo "Measured artifact: $ARTIFACT"
  echo "SHA-256 digest:    $HASH"

  tpm2_pcrextend "$TARGET_PCR:$PCR_BANK=$HASH"
  echo "Extended PCR[$TARGET_PCR] in bank $PCR_BANK"

  echo "Current PCR[$TARGET_PCR] value:"
  tpm2_pcrread "$PCR_BANK:$TARGET_PCR"
}

quote_pcr() {
  NONCE_FILE="$1"
  OUT_DIR="$2"
  SELECTION="${3:-$PCR_SELECTION}"

  require_cmd tpm2_createprimary
  require_cmd tpm2_create
  require_cmd tpm2_load
  require_cmd tpm2_quote
  require_cmd tpm2_readpublic
  require_cmd tpm2_flushcontext
  require_cmd tpm2_pcrread

  if [ ! -f "$NONCE_FILE" ]; then
    echo "Nonce file not found: $NONCE_FILE" >&2
    exit 1
  fi

  NONCE_HEX="$(normalize_hex < "$NONCE_FILE")"
  if [ -z "$NONCE_HEX" ]; then
    echo "Nonce file is empty: $NONCE_FILE" >&2
    exit 1
  fi

  mkdir -p "$OUT_DIR"

  tpm2_flushcontext -t 2>/dev/null || true
  tpm2_flushcontext -l 2>/dev/null || true

  echo "Creating Primary Key under endorsement hierarchy..."
  tpm2_createprimary -C e -c "$OUT_DIR/ek.ctx"

  echo "Creating Attestation Key..."
  tpm2_create -C "$OUT_DIR/ek.ctx" -u "$OUT_DIR/ak.pub" -r "$OUT_DIR/ak.priv"
  tpm2_load -C "$OUT_DIR/ek.ctx" -u "$OUT_DIR/ak.pub" -r "$OUT_DIR/ak.priv" -c "$OUT_DIR/ak.ctx"
  tpm2_readpublic -c "$OUT_DIR/ak.ctx" -o "$OUT_DIR/ak.pub" -n "$OUT_DIR/ak.name"

  echo "Generating quote for selection '$SELECTION' in bank $PCR_BANK..."
  tpm2_quote \
    -c "$OUT_DIR/ak.ctx" \
    -l "$SELECTION" \
    -q "$NONCE_HEX" \
    -m "$OUT_DIR/quote.msg" \
    -s "$OUT_DIR/quote.sig" \
    -o "$OUT_DIR/pcrs.out" \
    -g "$PCR_BANK"

  printf '%s\n' "$NONCE_HEX" > "$OUT_DIR/nonce.hex"

  tpm2_flushcontext "$OUT_DIR/ek.ctx" 2>/dev/null || true
  tpm2_flushcontext "$OUT_DIR/ak.ctx" 2>/dev/null || true

  tpm2_pcrread "$PCR_BANK:8" > "$OUT_DIR/pcr8.txt" 2>/dev/null || true
  tpm2_pcrread "$PCR_BANK:10" > "$OUT_DIR/pcr10.txt" 2>/dev/null || true
  tpm2_pcrread "$SELECTION" > "$OUT_DIR/pcrs.txt" 2>/dev/null || true

  if [ -r "$IMA_SYSFS_LOG" ]; then
    echo "Collecting Linux IMA runtime measurement log..."
    cp "$IMA_SYSFS_LOG" "$OUT_DIR/ima_measurements.txt"
  elif [ -f "/var/log/ima_measurements.txt" ]; then
    cp "/var/log/ima_measurements.txt" "$OUT_DIR/ima_measurements.txt"
  fi

  echo "Quote artifacts written to $OUT_DIR"
  ls -1 "$OUT_DIR"
}

extract_ima_log() {
  OUT_FILE="$1"
  mkdir -p "$(dirname "$OUT_FILE")"

  if [ -r "$IMA_SYSFS_LOG" ]; then
    cp "$IMA_SYSFS_LOG" "$OUT_FILE"
    echo "IMA runtime measurement log saved to $OUT_FILE ($(wc -l < "$OUT_FILE") events)"
  else
    echo "IMA measurement log not available at $IMA_SYSFS_LOG (is securityfs mounted?)" >&2
    exit 1
  fi
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

case "$1" in
  measure)
    if [ $# -lt 2 ] || [ $# -gt 3 ]; then
      usage
      exit 1
    fi
    measure_artifact "$2" "${3:-$PCR_INDEX}"
    ;;
  quote)
    if [ $# -lt 3 ] || [ $# -gt 4 ]; then
      usage
      exit 1
    fi
    quote_pcr "$2" "$3" "${4:-$PCR_SELECTION}"
    ;;
  ima-log)
    if [ $# -ne 2 ]; then
      usage
      exit 1
    fi
    extract_ima_log "$2"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "Unknown command: $1" >&2
    usage
    exit 1
    ;;
esac
