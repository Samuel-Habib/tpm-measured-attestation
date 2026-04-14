#!/usr/bin/env sh
set -eu

PCR_INDEX="${PCR_INDEX:-8}"
PCR_BANK="${PCR_BANK:-sha256}"
PCR_SELECTION="${PCR_SELECTION:-sha256:8}"
HIERARCHY="${HIERARCHY:-o}"
IMA_SYSFS_LOG="/sys/kernel/security/ima/ascii_runtime_measurements"

usage() {
  cat <<EOF
Usage:
  attestation-agent measure <artifact-path> [pcr-index]
  attestation-agent quote <nonce-hex-file> <output-dir> [pcr-selection]
  attestation-agent seal <secret-file> <output-dir> [hierarchy] [pcr-selection]
  attestation-agent unseal <sealed-dir> <output-secret-file> [hierarchy] [pcr-selection]
  attestation-agent ima-log <output-file>

Commands:
  measure   Hash an artifact and extend the digest into PCR.
  quote     Create/load an Attestation Key and generate quote artifacts.
  seal      Create a PCR-bound sealed secret object under specified hierarchy.
  unseal    Unseal a protected object using an active PCR policy session.
  ima-log   Extract the Linux IMA runtime measurement log.

Environment Variables & Defaults:
  PCR_INDEX       Default PCR index for measure (default: 8)
  PCR_BANK        Default hash bank (default: sha256)
  PCR_SELECTION   Default PCR selection for quote and seal (default: sha256:8)
  HIERARCHY       Default TPM hierarchy: 'o' (owner), 'e' (endorsement), 'p' (platform) (default: o)
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

  DIGEST="$(sha256sum "$ARTIFACT" | awk '{print $1}' | normalize_hex)"

  echo "Extending PCR[$TARGET_PCR] ($PCR_BANK) with SHA-256 digest:"
  echo "$DIGEST"

  tpm2_pcrextend "$TARGET_PCR:$PCR_BANK=$DIGEST"

  echo "Current PCR[$TARGET_PCR]:"
  tpm2_pcrread "$PCR_BANK:$TARGET_PCR"
}

create_or_load_ak() {
  OUT_DIR="$1"

  require_cmd tpm2_createek
  require_cmd tpm2_createak
  require_cmd tpm2_load
  require_cmd tpm2_readpublic
  require_cmd tpm2_flushcontext

  mkdir -p "$OUT_DIR"

  if [ -f "$OUT_DIR/ak.ctx" ]; then
    if ! tpm2_readpublic -c "$OUT_DIR/ak.ctx" >/dev/null 2>&1; then
      echo "Existing AK context invalid for current TPM instance; recreating..."
      rm -f "$OUT_DIR/ak.ctx" "$OUT_DIR/ak.pub" "$OUT_DIR/ak.name" "$OUT_DIR/ek.ctx"
    fi
  fi

  if [ ! -f "$OUT_DIR/ak.ctx" ] || [ ! -f "$OUT_DIR/ak.pub" ]; then

    echo "Creating EK and AK under $OUT_DIR"
    tpm2_flushcontext -t 2>/dev/null || true

    tpm2_createek -c "$OUT_DIR/ek.ctx"


    tpm2_createak \
      -C "$OUT_DIR/ek.ctx" \
      -c "$OUT_DIR/ak.ctx" \
      -u "$OUT_DIR/ak.pub" \
      -n "$OUT_DIR/ak.name" \
      -G rsa \
      -g sha256 \
      -s rsassa

    tpm2_flushcontext "$OUT_DIR/ek.ctx" 2>/dev/null || true
    tpm2_readpublic -c "$OUT_DIR/ak.ctx" -o "$OUT_DIR/ak.public.pem" -f pem >/dev/null 2>&1 || true
  fi
}

quote_pcr() {
  NONCE_FILE="$1"
  OUT_DIR="$2"
  SELECTION="${3:-$PCR_SELECTION}"

  require_cmd tpm2_quote
  require_cmd tpm2_pcrread
  require_cmd tpm2_flushcontext

  if [ ! -f "$NONCE_FILE" ]; then
    echo "Nonce file not found: $NONCE_FILE" >&2
    exit 1
  fi

  mkdir -p "$OUT_DIR"
  create_or_load_ak "$OUT_DIR"

  NONCE_HEX="$(cat "$NONCE_FILE" | normalize_hex)"

  if [ "$(printf "%s" "$NONCE_HEX" | wc -c | awk '{print $1}')" -lt 16 ]; then
    echo "Nonce is too short. Use a fresh random nonce, for example: openssl rand -hex 32" >&2
    exit 1
  fi

  printf "%s\n" "$NONCE_HEX" > "$OUT_DIR/nonce.hex"

  echo "Quoting PCR selection: $SELECTION"
  tpm2_flushcontext -t 2>/dev/null || true
  tpm2_quote \
    -c "$OUT_DIR/ak.ctx" \
    -l "$SELECTION" \
    -q "$NONCE_HEX" \
    -m "$OUT_DIR/quote.msg" \
    -s "$OUT_DIR/quote.sig" \
    -o "$OUT_DIR/pcrs.out" \
    -g sha256

  tpm2_flushcontext "$OUT_DIR/ak.ctx" 2>/dev/null || true

  # Record discrete PCR states
  tpm2_pcrread "$PCR_BANK:8" > "$OUT_DIR/pcr8.txt" 2>/dev/null || true
  tpm2_pcrread "$PCR_BANK:10" > "$OUT_DIR/pcr10.txt" 2>/dev/null || true
  tpm2_pcrread "$SELECTION" > "$OUT_DIR/pcrs.txt" 2>/dev/null || true

  # Extract IMA runtime measurement log if present
  if [ -r "$IMA_SYSFS_LOG" ]; then
    echo "Collecting Linux IMA runtime measurement log..."
    cp "$IMA_SYSFS_LOG" "$OUT_DIR/ima_measurements.txt"
  elif [ -f "/var/log/ima_measurements.txt" ]; then
    cp "/var/log/ima_measurements.txt" "$OUT_DIR/ima_measurements.txt"
  fi

  echo "Quote artifacts written to $OUT_DIR"
  ls -1 "$OUT_DIR"
}

seal_secret() {
  SECRET_FILE="$1"
  OUT_DIR="$2"
  HIER="${3:-$HIERARCHY}"
  SELECTION="${4:-$PCR_SELECTION}"

  require_cmd tpm2_createprimary
  require_cmd tpm2_createpolicy
  require_cmd tpm2_create
  require_cmd tpm2_flushcontext

  if [ ! -f "$SECRET_FILE" ]; then
    echo "Secret file not found: $SECRET_FILE" >&2
    exit 1
  fi

  mkdir -p "$OUT_DIR"

  tpm2_flushcontext -t 2>/dev/null || true
  echo "Sealing secret $SECRET_FILE under hierarchy '$HIER' bound to PCRs '$SELECTION'..."


  tpm2_createprimary -C "$HIER" -c "$OUT_DIR/primary.ctx"

  tpm2_createpolicy \
    --policy-pcr \
    -l "$SELECTION" \
    -L "$OUT_DIR/pcr.policy"

  tpm2_create \
    -C "$OUT_DIR/primary.ctx" \
    -u "$OUT_DIR/seal.pub" \
    -r "$OUT_DIR/seal.priv" \
    -L "$OUT_DIR/pcr.policy" \
    -i "$SECRET_FILE"

  tpm2_flushcontext "$OUT_DIR/primary.ctx" 2>/dev/null || true

  cat <<METADATA > "$OUT_DIR/seal.meta"
HIERARCHY=$HIER
PCR_SELECTION=$SELECTION
METADATA

  echo "Sealed object generated successfully in $OUT_DIR:"
  ls -1 "$OUT_DIR"
}

unseal_secret() {
  SEALED_DIR="$1"
  OUT_SECRET="$2"
  HIER="${3:-}"
  SELECTION="${4:-}"

  require_cmd tpm2_createprimary
  require_cmd tpm2_load
  require_cmd tpm2_startauthsession
  require_cmd tpm2_policypcr
  require_cmd tpm2_unseal
  require_cmd tpm2_flushcontext

  if [ ! -d "$SEALED_DIR" ] || [ ! -f "$SEALED_DIR/seal.pub" ] || [ ! -f "$SEALED_DIR/seal.priv" ]; then
    echo "Invalid sealed directory: $SEALED_DIR (missing seal.pub or seal.priv)" >&2
    exit 1
  fi

  if [ -z "$HIER" ] && [ -f "$SEALED_DIR/seal.meta" ]; then
    # shellcheck disable=SC1090
    HIER="$(grep '^HIERARCHY=' "$SEALED_DIR/seal.meta" | cut -d'=' -f2)"
  fi
  HIER="${HIER:-$HIERARCHY}"

  if [ -z "$SELECTION" ] && [ -f "$SEALED_DIR/seal.meta" ]; then
    # shellcheck disable=SC1090
    SELECTION="$(grep '^PCR_SELECTION=' "$SEALED_DIR/seal.meta" | cut -d'=' -f2)"
  fi
  SELECTION="${SELECTION:-$PCR_SELECTION}"

  TMP_DIR="$(mktemp -d)"

  tpm2_flushcontext -t 2>/dev/null || true
  tpm2_flushcontext -l 2>/dev/null || true
  echo "Unsealing object from $SEALED_DIR (Hierarchy: $HIER, PCR Selection: $SELECTION)..."

  tpm2_createprimary -C "$HIER" -c "$TMP_DIR/primary.ctx"

  tpm2_load \
    -C "$TMP_DIR/primary.ctx" \
    -u "$SEALED_DIR/seal.pub" \
    -r "$SEALED_DIR/seal.priv" \
    -c "$TMP_DIR/seal.ctx"

  tpm2_flushcontext 0x80000000 2>/dev/null || true

  tpm2_startauthsession -S "$TMP_DIR/session.ctx" --policy-session
  tpm2_policypcr -S "$TMP_DIR/session.ctx" -l "$SELECTION"

  UNSEAL_STATUS=0
  if tpm2_unseal -c "$TMP_DIR/seal.ctx" -p "session:$TMP_DIR/session.ctx" -o "$OUT_SECRET" 2>/dev/null; then
    echo "SUCCESS: Secret successfully unsealed to $OUT_SECRET"
  else
    echo "FAIL: Unsealing failed! PCR policy not satisfied or invalid authorization." >&2
    UNSEAL_STATUS=1
  fi

  tpm2_flushcontext -t 2>/dev/null || true
  tpm2_flushcontext -l 2>/dev/null || true
  rm -rf "$TMP_DIR"


  return $UNSEAL_STATUS
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
  seal)
    if [ $# -lt 3 ] || [ $# -gt 5 ]; then
      usage
      exit 1
    fi
    seal_secret "$2" "$3" "${4:-$HIERARCHY}" "${5:-$PCR_SELECTION}"
    ;;
  unseal)
    if [ $# -lt 3 ] || [ $# -gt 5 ]; then
      usage
      exit 1
    fi
    unseal_secret "$2" "$3" "${4:-}" "${5:-}"
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
    usage
    exit 1
    ;;
esac
