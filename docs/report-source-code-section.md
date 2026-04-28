# Source Code Description

The source code for this project is available at:

```text
https://github.com/Samuel-Habib/tpm-measured-attestation
```

The repository is organized around the Yocto build workspace, a custom attestation layer, scripts for launching `swtpm` and QEMU, a guest-side attestation helper, and a host-side Python verifier.

The main components are:

- `meta-myattestation/`: custom Yocto layer that adds TPM userspace tools and installs the attestation helper into the image.
- `scripts/start-swtpm.sh`: initializes and launches the software TPM 2.0 emulator.
- `scripts/run-qemu.sh`: starts the `qemuarm64` guest and connects it to the `swtpm` socket.
- `guest/attestation-agent.sh`: guest-side script that measures a selected artifact into PCR[8] and generates TPM quote artifacts.
- `verifier/verify_quote.py`: host-side verifier that checks quote validity, nonce freshness, and PCR[8] baseline matching.
- `results/`: directory used to store clean and tampered quote artifacts during evaluation.

To reproduce the evaluation, first build the Yocto image with the custom layer enabled. Then start `swtpm`, boot the QEMU guest with TPM support, run the guest attestation helper on a clean image, record the PCR[8] value as the baseline, and run the host verifier. For the tamper test, modify the measured artifact, regenerate a quote, and verify that PCR[8] no longer matches the clean baseline. For the replay test, reuse an old quote with a new verifier nonce and confirm that the quote validation fails.
