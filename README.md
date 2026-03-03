# TPM-Based Measured Boot and Remote Attestation on Emulated ARM Hardware

Development project for demonstrating TPM-backed measured boot and remote attestation on an emulated ARM Linux system.

This repository contains a reproducible project scaffold for:

- building a minimal Yocto `qemuarm64` Linux image,
- connecting QEMU to a software TPM 2.0 emulator through `swtpm`,
- measuring a selected boot artifact into TPM PCR[8],
- generating TPM quotes with a nonce,
- verifying quote freshness and PCR baseline matching from the host.

## Project summary

The project demonstrates measured boot rather than secure boot.

Secure boot blocks unauthorized code from running. Measured boot records what ran by hashing software artifacts and extending those hashes into TPM PCRs. A remote verifier can later request a TPM quote and compare the signed PCR state against a known-good baseline.

In this prototype:

- The QEMU guest acts as the attester.
- The host machine acts as the verifier.
- `swtpm` emulates a TPM 2.0 device.
- PCR[8] stores the prototype boot measurement.
- SHA-256 is used for measurement and PCR extension.
- A nonce is used to prevent replayed quotes.
