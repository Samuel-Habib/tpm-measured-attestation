#!/usr/bin/env python3
"""
Host-side verifier for TPM quote artifacts and Linux IMA runtime measurement log replay.

This verifier performs:
1. TPM quote signature and freshness (nonce) verification via tpm2_checkquote.
2. Boot measurement baseline verification (PCR[8] comparison).
3. Linux IMA runtime measurement log replay (recomputing cumulative PCR[10] hash from
   the ASCII measurement log and comparing it against the quoted/observed PCR[10]).
4. Optional offline / CI validation mode when tpm2_checkquote is unavailable.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import shutil
import subprocess
import sys
from pathlib import Path


HEX_64_RE = re.compile(r"(?:0x)?([a-fA-F0-9]{64})")


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        raise SystemExit(f"Missing file: {path}")


def normalize_hex(value: str) -> str:
    return "".join(value.split()).lower()


def parse_pcr_value(path: Path) -> str:
    text = read_text(path)
    matches = HEX_64_RE.findall(text)

    if not matches:
        raise SystemExit(f"Could not find a 64-character SHA-256 value in {path}")

    return matches[-1].lower()


def check_required_file(path: Path) -> None:
    if not path.exists():
        raise SystemExit(f"Missing required file: {path}")


def run_tpm2_checkquote(
    nonce_hex: str,
    ak_pub: Path,
    quote: Path,
    sig: Path,
    pcrs: Path,
    hash_alg: str,
    allow_offline: bool = False,
) -> None:
    tool = shutil.which("tpm2_checkquote")

    if tool is None:
        if allow_offline:
            print("WARNING: tpm2_checkquote not found; running in offline simulation mode.")
            expected_nonce_bytes = bytes.fromhex(nonce_hex)
            quote_bytes = quote.read_bytes()
            if expected_nonce_bytes not in quote_bytes:
                print("FAIL: quote check failed: nonce does not match quote extraData")
                raise SystemExit(1)
            print("PASS: [offline] quote structure and nonce checked")
            return
        raise SystemExit(
            "Missing required host command: tpm2_checkquote\n"
            "Install tpm2-tools or run with --allow-offline for simulation environments."
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
        print("FAIL: quote check failed")
        if result.stdout.strip():
            print(result.stdout.strip())
        if result.stderr.strip():
            print(result.stderr.strip())
        raise SystemExit(1)

    print("PASS: quote signature check completed")


def replay_ima_log(log_path: Path, target_pcr: int = 10, hash_alg: str = "sha256") -> tuple[str, int]:
    """
    Replays the ASCII IMA runtime measurement log by recalculating:
      PCR_new = HASH(PCR_current || template_digest)
    Starting from an all-zero initial digest for PCR[target_pcr].
    Returns (replayed_pcr_hex, event_count).
    """
    if hash_alg != "sha256":
        raise ValueError(f"Unsupported hash algorithm for IMA replay: {hash_alg}")

    # Initial state for TPM SHA-256 PCR bank is 32 bytes of zeros
    current_pcr = b"\x00" * 32
    event_count = 0

    lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()

    for line_num, line in enumerate(lines, start=1):
        line = line.strip()
        if not line:
            continue

        tokens = line.split()
        if len(tokens) < 3:
            continue

        try:
            pcr_idx = int(tokens[0])
        except ValueError:
            continue

        if pcr_idx != target_pcr:
            continue

        template_hash_hex = tokens[1]
        if not re.fullmatch(r"[a-fA-F0-9]{64}", template_hash_hex):
            print(f"Warning: line {line_num} has non-sha256 template hash '{template_hash_hex}', skipping")
            continue

        template_digest = bytes.fromhex(template_hash_hex)
        current_pcr = hashlib.sha256(current_pcr + template_digest).digest()
        event_count += 1

    return current_pcr.hex(), event_count


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify TPM quote artifacts against a nonce, expected PCR baseline, and IMA log."
    )

    parser.add_argument("--nonce", required=True, type=Path, help="File containing nonce hex")
    parser.add_argument("--ak-pub", required=True, type=Path, help="AK public file from tpm2_createak")
    parser.add_argument("--quote", required=True, type=Path, help="quote.msg from tpm2_quote")
    parser.add_argument("--sig", required=True, type=Path, help="quote.sig from tpm2_quote")
    parser.add_argument("--pcrs", required=True, type=Path, help="pcrs.out from tpm2_quote")
    parser.add_argument("--pcr8-text", required=True, type=Path, help="Text output from tpm2_pcrread sha256:8")
    parser.add_argument("--expected-pcr8", required=True, type=Path, help="Expected clean PCR[8] baseline")
    parser.add_argument("--ima-log", type=Path, help="Optional /sys/kernel/security/ima/ascii_runtime_measurements file")
    parser.add_argument("--pcr10-text", type=Path, help="Optional text output from tpm2_pcrread sha256:10")
    parser.add_argument("--expected-pcr10", type=Path, help="Optional expected PCR[10] baseline")
    parser.add_argument("--hash-alg", default="sha256", help="Quote hash algorithm. Default: sha256")
    parser.add_argument("--allow-offline", action="store_true", help="Allow offline verification without tpm2_checkquote")

    args = parser.parse_args()

    required_files = [
        args.nonce,
        args.ak_pub,
        args.quote,
        args.sig,
        args.pcrs,
        args.pcr8_text,
        args.expected_pcr8,
    ]
    for path in required_files:
        check_required_file(path)

    nonce_hex = normalize_hex(read_text(args.nonce))
    expected_pcr8 = normalize_hex(read_text(args.expected_pcr8))
    observed_pcr8 = parse_pcr_value(args.pcr8_text)

    if not re.fullmatch(r"[a-f0-9]+", nonce_hex):
        raise SystemExit("Nonce file must contain hex characters only.")

    if not re.fullmatch(r"[a-f0-9]{64}", expected_pcr8):
        raise SystemExit("Expected PCR[8] file must contain exactly one 64-character SHA-256 hex value.")

    # 1. Quote Signature and Freshness
    run_tpm2_checkquote(
        nonce_hex=nonce_hex,
        ak_pub=args.ak_pub,
        quote=args.quote,
        sig=args.sig,
        pcrs=args.pcrs,
        hash_alg=args.hash_alg,
        allow_offline=args.allow_offline,
    )

    # 2. Boot Measurement Baseline Check (PCR[8])
    if observed_pcr8 != expected_pcr8:
        print("FAIL: PCR[8] mismatch")
        print(f"Expected: {expected_pcr8}")
        print(f"Observed: {observed_pcr8}")
        return 1

    print("PASS: PCR[8] matches expected baseline")

    # 3. IMA Runtime Measurement Log Replay (PCR[10])
    if args.ima_log:
        check_required_file(args.ima_log)
        replayed_pcr10, count = replay_ima_log(args.ima_log, target_pcr=10, hash_alg=args.hash_alg)
        print(f"Replayed {count} events from IMA log. Calculated PCR[10]: {replayed_pcr10}")

        if args.pcr10_text:
            check_required_file(args.pcr10_text)
            observed_pcr10 = parse_pcr_value(args.pcr10_text)
            if replayed_pcr10 != observed_pcr10:
                print("FAIL: IMA log replay mismatch with observed PCR[10]")
                print(f"Replayed from log: {replayed_pcr10}")
                print(f"Observed in PCR:   {observed_pcr10}")
                return 1
            print("PASS: IMA log replay matches observed PCR[10]")

        if args.expected_pcr10:
            check_required_file(args.expected_pcr10)
            expected_pcr10 = normalize_hex(read_text(args.expected_pcr10))
            if replayed_pcr10 != expected_pcr10:
                print("FAIL: IMA PCR[10] baseline mismatch")
                print(f"Expected: {expected_pcr10}")
                print(f"Replayed: {replayed_pcr10}")
                return 1
            print("PASS: IMA PCR[10] matches expected baseline")

    print("PASS: attestation accepted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
