#!/usr/bin/env python3
"""
Host-side verifier for TPM quote artifacts.

This verifier performs two checks:

1. It calls tpm2_checkquote to verify the TPM quote signature and nonce binding.
2. It compares the observed PCR[8] value against the expected clean baseline.

The script intentionally relies on tpm2-tools for TPM quote parsing because TPM quote
structures are binary TPM2B_ATTEST objects and should not be hand-parsed in a course
prototype unless necessary.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path


HEX_64_RE = re.compile(r"\b[a-fA-F0-9]{64}\b")


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError as err:
        raise SystemExit(f"Failed to read {path}: {err}") from err


def normalize_hex(value: str) -> str:
    return "".join(value.split()).lower()


def parse_pcr8_value(path: Path) -> str:
    text = read_text(path)
    matches = HEX_64_RE.findall(text)

    if not matches:
        raise SystemExit(f"Could not find a 64-character hex string in {path}")

    return matches[-1].lower()


def check_required_file(path: Path) -> None:
    if not path.exists():
        raise SystemExit(f"Missing file: {path}")


def run_tpm2_checkquote(
    nonce_hex: str,
    ak_pub: Path,
    quote: Path,
    sig: Path,
    pcrs: Path,
    hash_alg: str,
) -> None:
    tool = shutil.which("tpm2_checkquote")

    if tool is None:
        raise SystemExit(
            "Missing required host command: tpm2_checkquote\n"
            "Install tpm2-tools and rerun the verifier."
        )

    cmd = [
        tool,
        "-u",
        str(ak_pub),
        "-m",
        str(quote),
        "-s",
        str(sig),
        "-f",
        str(pcrs),
        "-g",
        hash_alg,
        "-q",
        nonce_hex,
    ]

    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )

    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise SystemExit("FAIL: quote check failed")

    print("PASS: quote signature check completed")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify TPM quote artifacts against a nonce and expected PCR[8]."
    )

    parser.add_argument("--nonce", required=True, type=Path, help="File containing nonce hex")
    parser.add_argument("--ak-pub", required=True, type=Path, help="Public attestation key file")
    parser.add_argument("--quote", required=True, type=Path, help="quote.msg from tpm2_quote")
    parser.add_argument("--sig", required=True, type=Path, help="quote.sig from tpm2_quote")
    parser.add_argument("--pcrs", required=True, type=Path, help="pcrs.out from tpm2_quote")
    parser.add_argument("--pcr8-text", required=True, type=Path, help="Text output from tpm2_pcrread sha256:8")
    parser.add_argument("--expected-pcr8", required=True, type=Path, help="Expected clean PCR[8] baseline")
    parser.add_argument("--hash-alg", default="sha256", help="Quote hash algorithm. Default: sha256")

    args = parser.parse_args()

    for path in [
        args.nonce,
        args.ak_pub,
        args.quote,
        args.sig,
        args.pcrs,
        args.pcr8_text,
        args.expected_pcr8,
    ]:
        check_required_file(path)

    nonce_hex = normalize_hex(read_text(args.nonce))
    expected_pcr8 = normalize_hex(read_text(args.expected_pcr8))
    observed_pcr8 = parse_pcr8_value(args.pcr8_text)

    if not re.fullmatch(r"[a-f0-9]+", nonce_hex):
        raise SystemExit("Nonce file must contain hex characters only.")

    if not re.fullmatch(r"[a-f0-9]{64}", expected_pcr8):
        raise SystemExit("Expected PCR[8] file must contain exactly one 64-character SHA-256 hex value.")

    run_tpm2_checkquote(
        nonce_hex=nonce_hex,
        ak_pub=args.ak_pub,
        quote=args.quote,
        sig=args.sig,
        pcrs=args.pcrs,
        hash_alg=args.hash_alg,
    )

    if observed_pcr8 != expected_pcr8:
        print("FAIL: PCR[8] mismatch")
        print(f"Expected: {expected_pcr8}")
        print(f"Observed: {observed_pcr8}")
        return 1

    print("PASS: PCR[8] matches expected baseline")
    print("PASS: attestation accepted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
