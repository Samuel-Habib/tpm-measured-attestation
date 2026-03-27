#!/usr/bin/env sh
set -eu

PCR_INDEX="${PCR_INDEX:-8}"
PCR_BANK="${PCR_BANK:-sha256}"

usage() {
  cat <<EOF
Usage:
  attestation-agent measure <artifact-path>
  attestation-agent quote <nonce-hex-file> <output-dir>

Commands:
  measure   Hash an artifact and extend the digest into PCR[$PCR_INDEX].
  quote     Create/load an Attestation Key and generate quote artifacts.

Environment:
  PCR_INDEX  PCR index to use. Default: 8
  PCR_BANK   PCR hash bank. Default: sha256
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

  tpm2_pcrextend "$PCR_INDEX:$PCR_BANK=$HASH"
  echo "Extended PCR[$PCR_INDEX] in bank $PCR_BANK"

  echo "Current PCR[$PCR_INDEX] value:"
  tpm2_pcrread "$PCR_BANK:$PCR_INDEX"
}

quote_pcr() {
  NONCE_FILE="$1"
  OUT_DIR="$2"

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

  echo "Generating quote for PCR[$PCR_INDEX] in bank $PCR_BANK..."
  tpm2_quote     -c "$OUT_DIR/ak.ctx"     -l "$PCR_BANK:$PCR_INDEX"     -q "$NONCE_HEX"     -m "$OUT_DIR/quote.msg"     -s "$OUT_DIR/quote.sig"     -o "$OUT_DIR/pcrs.out"     -g "$PCR_BANK"

  tpm2_pcrread "$PCR_BANK:$PCR_INDEX" > "$OUT_DIR/pcr8.txt"
  printf '%s\n' "$NONCE_HEX" > "$OUT_DIR/nonce.hex"

  tpm2_flushcontext "$OUT_DIR/ek.ctx" 2>/dev/null || true
  tpm2_flushcontext "$OUT_DIR/ak.ctx" 2>/dev/null || true

  echo "Quote artifacts written to $OUT_DIR"
  ls -1 "$OUT_DIR"
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

case "$1" in
  measure)
    if [ $# -ne 2 ]; then
      usage
      exit 1
    fi
    measure_artifact "$2"
    ;;
  quote)
    if [ $# -ne 3 ]; then
      usage
      exit 1
    fi
    quote_pcr "$2" "$3"
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
