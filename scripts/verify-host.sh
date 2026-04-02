#!/usr/bin/env sh
set -eu

CASE="${1:-clean}"

python3 verifier/verify_quote.py \
  --nonce "results/$CASE/nonce.hex" \
  --ak-pub "results/$CASE/ak.pub" \
  --quote "results/$CASE/quote.msg" \
  --sig "results/$CASE/quote.sig" \
  --pcrs "results/$CASE/pcrs.out" \
  --pcr8-text "results/$CASE/pcr8.txt" \
  --expected-pcr8 "results/expected_pcr8.txt"
