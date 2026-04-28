# Evaluation Notes

## Clean-image test

- Date: 2026-04-28
- Yocto image: `core-image-minimal-attestation` (`qemuarm64`)
- Measured artifact: Kernel Image (`/boot/Image`)
- PCR bank: `sha256`
- PCR index: `8` (Boot measurement) and `10` (IMA runtime)
- Observed PCR[8]: `d3581b367c19a274cefa5425e6d335df47cf6d9caa0d8948b751aebdc166e085`
- Observed PCR[10]: `4a5afe0ddca2fc918eadf2fa8a6010f66c73ffb085b0bd38e014f71c87f01797`

Verifier command:
```sh
make verify-clean
# or
make verify-ima
```

Observed verifier result:

```text
PASS: quote signature check completed
PASS: PCR[8] matches expected baseline
Replayed 3 events from IMA log. Calculated PCR[10]: 4a5afe0ddca2fc918eadf2fa8a6010f66c73ffb085b0bd38e014f71c87f01797
PASS: IMA log replay matches observed PCR[10]
PASS: IMA PCR[10] matches expected baseline
PASS: attestation accepted
```

## Tampered-image test

- Date: 2026-04-28
- Tamper method: Modified kernel artifact hash extended into PCR[8]
- Measured artifact: Tampered boot image / unauthorized executable
- Observed PCR[8]: `bb8efeeabfaeca473ff74142cfcb0e340062da804289408f4c8b5bc363cd7fa3`

Verifier command:
```sh
make verify-tampered
```

Observed verifier result:

```text
PASS: quote signature check completed
FAIL: PCR[8] mismatch
Expected: d3581b367c19a274cefa5425e6d335df47cf6d9caa0d8948b751aebdc166e085
Observed: bb8efeeabfaeca473ff74142cfcb0e340062da804289408f4c8b5bc363cd7fa3
```

## Replay test

- Original quote nonce: Recorded in `results/clean/nonce.hex`
- New verifier nonce: Stale fresh challenge
- Reused quote artifacts: `results/clean/quote.msg`, `quote.sig`, `pcrs.out`

Observed verifier result:

```text
FAIL: quote check failed
```

## Linux IMA Runtime Measurement & Log Replay

- IMA Policy: Focused policy (`/etc/ima/ima-policy`) measuring `BPRM_CHECK` and `MMAP_CHECK`
- Log: `/sys/kernel/security/ima/ascii_runtime_measurements` (saved to `results/clean/ima_measurements.txt`)
- Cumulative replay: Calculated in Python from raw ASCII event digests starting from $00^{32}$
- Verified: Event replay matches quoted PCR[10] and expected baseline `4a5afe0ddca2fc918eadf2fa8a6010f66c73ffb085b0bd38e014f71c87f01797`

## TPM Sealed Storage (PCR Policy Binding)

- Sealed secret file: `results/clean/sealed/secret.data` ("TOP_SECRET_PASSPHRASE_MEASURED_BOOT_2026")
- Target hierarchy: Owner (`o`) via Storage Primary Key
- PCR policy: Bound to `sha256:8` baseline digest (`pcr.policy`)
- Clean state test: `attestation-agent unseal` -> **SUCCESS**, secret recovered cleanly.
- Tampered state test: PCR[8] extended with unauthorized value -> **FAIL** (TPM denies unseal, authorization policy failure).
