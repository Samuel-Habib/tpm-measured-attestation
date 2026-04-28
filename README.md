# TPM 2.0 Measured Boot & Remote Attestation Prototype

An end-to-end trusted computing testbed on emulated ARM64 (`qemuarm64`) demonstrating **Hardware-Backed Measured Boot**, **Linux Kernel IMA Runtime Integrity**, **PCR-Bound Sealed Storage**, and **Host-Side Remote Attestation**.

Built with a custom **Yocto Project / Poky** layer (`meta-myattestation`), **U-Boot** measured bootloader scripts, **Linux IMA**, and an emulated **TPM 2.0** device (`swtpm`).

---

## Background & Design Goals

Embedded Linux devices deployed in unattended environments (e.g., IoT gateways, automotive telematics, industrial controllers) face physical and remote integrity threats. 

While **Secure Boot** halts the bootloader if a signature check fails, **Measured Boot** takes a complementary approach: it cryptographically records every stage of the boot sequence into tamper-proof Platform Configuration Registers (PCRs). This allows:
1. **Remote Attestation**: A remote challenger can cryptographically verify what exact binaries ran before granting network access or dispatching sensitive credentials.
2. **Sealed Storage**: Encryption keys or sensitive configurations can be locked to the hardware TPM such that the TPM will only unseal them if the platform is in an authorized, known-good measurement state.

### Design Scope
* **Target Platform**: 64-bit ARM (`qemu-system-aarch64`, Cortex-A57, virt machine).
* **Root of Trust**: Emulated TPM 2.0 via `swtpm` using the standard TCG TIS interface.
* **Boot Chain**: U-Boot firmware hashing `/boot/Image` into **PCR[8]**.
* **Runtime Auditing**: Linux Integrity Measurement Architecture (IMA) logging executed binaries and dynamic libraries into **PCR[10]**.
* **Secret Protection**: Hardware-enforced TPM 2.0 sealed storage bound to the clean PCR[8] baseline.
* **Verification Engine**: Host-side Python verifier with RSASSA signature validation, nonce freshness checks, and cumulative IMA event log replay.

---

## System Architecture

```text
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │                         EMULATED DEVICE (GUEST)                             │
 │                                                                             │
 │   1. BOOT PHASE                   2. RUNTIME PHASE                          │
 │  ┌───────────────────────┐       ┌────────────────────────┐                 │
 │  │    U-Boot Firmware    │       │   Linux Kernel & IMA   │                 │
 │  │                       │       │                        │                 │
 │  │  • Hash /boot/Image   │       │  • Monitor execve()    │                 │
 │  │  • Extend PCR[8]      │       │  • Monitor mmap(EXEC)  │                 │
 │  └───────────┬───────────┘       │  • Extend PCR[10]      │                 │
 │              │                   └───────────┬────────────┘                 │
 │              ▼                               ▼                              │
 │  ┌────────────────────────────────────────────────────────┐                 │
 │  │                    TPM 2.0 HARDWARE                    │                 │
 │  │                                                        │                 │
 │  │   PCR[8] : Bootloader & Kernel Integrity               │                 │
 │  │   PCR[10]: Runtime Application & Library Integrity     │                 │
 │  │   Sealed Secret: Decryptable ONLY if PCR[8] is clean   │                 │
 │  └───────────────────────────┬────────────────────────────┘                 │
 │                              │                                              │
 └──────────────────────────────┼──────────────────────────────────────────────┘
                                │
               TPM Quote (PCRs + Signature + Nonce)
               + IMA Runtime Event Log
                                │
                                ▼
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │                         REMOTE VERIFIER (HOST)                              │
 │                                                                             │
 │  1. Verify Nonce Freshness         --> Proves quote is not replayed         │
 │  2. Verify TPM AK Signature        --> Proves quote came from genuine TPM   │
 │  3. Assert PCR[8] Clean Baseline   --> Detects any boot-stage tampering     │
 │  4. Replay Linux IMA Event Log     --> Mathematically recalculates PCR[10]  │
 └─────────────────────────────────────────────────────────────────────────────┘
```

---

## How It Works

### 1. Boot-Stage Measurement (PCR[8])
During initialization, the U-Boot boot script (`boot.cmd`) loads the kernel image from virtio storage and extends its SHA-256 digest into **PCR[8]**:
$$\text{PCR[8]}_{\text{new}} = \text{SHA256}(\text{PCR[8]}_{\text{old}} \parallel \text{Digest}(\text{Image}))$$
If an attacker modifies `/boot/Image` on flash, the resulting PCR[8] value differs from the baseline, signaling compromise to external verifiers.

> **Engineering Note**: Standard TCG PC-Client profiles reserve PCR[0–7] for platform firmware / CRTM. For custom embedded OS measurement, PCR[8] is the standard designated register.

### 2. Post-Boot Runtime Monitoring (Linux IMA & PCR[10])
Boot measurement only proves what initialized the kernel. To track runtime activity, the kernel's **Integrity Measurement Architecture (IMA)** is configured (`ima.cfg`) with a custom policy (`/etc/ima/ima-policy`):
* Audits binary executions (`BPRM_CHECK`) and memory-mapped libraries (`MMAP_CHECK`).
* Excludes pseudo-filesystems (sysfs, procfs, debugfs) to avoid log noise.
* Logs each measurement in `/sys/kernel/security/ima/ascii_runtime_measurements` and extends **PCR[10]**.

### 3. Hardware-Enforced Sealed Storage
Sensitive device secrets (private keys, tokens) are sealed to the TPM using a policy session (`tpm2_createpolicy --policy-pcr`):
* **Clean System**: PCR[8] matches the authorized policy baseline $\rightarrow$ secret is released.
* **Tampered System**: PCR[8] was altered $\rightarrow$ TPM hardware refuses to unseal the secret.

### 4. Remote Attestation & Log Replay
A remote challenger sends a 32-byte cryptographic nonce. The guest Attestation Key (AK) signs the current PCR state alongside the nonce into a binary TPM Quote. 

The host verifier (`verify_quote.py`):
1. Confirms the quote was signed with the genuine Attestation Key.
2. Checks that the nonce in the quote matches the challenger's fresh challenge (preventing replay attacks).
3. Compares PCR[8] against the expected clean baseline.
4. **Log Replay**: Parses the ASCII IMA measurement log, recalculates the cumulative hash chain starting from $00^{32}$, and asserts that the computed digest matches the quoted PCR[10].

---

## Automated Test Harness

The repository includes an end-to-end verification harness that tests the full lifecycle:

```sh
make test-all
```

### Verified Terminal Output

```text
==========================================================
 Starting End-to-End Measured Boot & Attestation Test Run
==========================================================
[1/7] Initializing virtual TPM 2.0 via swtpm...
[2/7] Measuring clean boot artifact into PCR[8]...
      Clean Expected PCR[8]: d3581b367c19a274cefa5425e6d335df47cf6d9caa0d8948b751aebdc166e085
[3/7] Generating Linux IMA runtime measurement log and extending PCR[10]...
      Clean Expected PCR[10]: 4a5afe0ddca2fc918eadf2fa8a6010f66c73ffb085b0bd38e014f71c87f01797
[4/7] Generating Clean TPM Quote Artifacts with Fresh Nonce...
      PASS: quote signature check completed
      PASS: PCR[8] matches expected baseline
      PASS: IMA log replay matches observed PCR[10]
      PASS: attestation accepted
[5/7] Testing TPM Sealed Storage bound to PCR[8]...
      PASS: Sealed storage unseal succeeded on clean system.
      PASS: Unseal correctly denied by TPM policy on tampered state.
[6/7] Generating Tampered Quote Artifacts...
      PASS: Verifier correctly detected and rejected tampered PCR[8] quote.
[7/7] Testing Replay Attack Detection with Stale Quote...
      PASS: Verifier correctly rejected replayed quote with fresh nonce.
==========================================================
 ALL TEST SUITES PASSED SUCCESSFULLY!
==========================================================
```

---

## Command Reference

### Guest Agent (`attestation-agent`)
Installed in the target image at `/usr/bin/attestation-agent`:

```sh
# Measure a file and extend digest into PCR[8]
attestation-agent measure /boot/Image 8

# Generate quote artifacts against challenger nonce
attestation-agent quote /tmp/nonce.hex /tmp/quote-output sha256:8,10

# Seal a sensitive file bound to PCR[8] baseline
attestation-agent seal /etc/secret.key /tmp/sealed-object o sha256:8

# Unseal the file (denied by hardware if PCR[8] changed)
attestation-agent unseal /tmp/sealed-object /tmp/recovered.key
```

### Host Remote Verifier (`verify_quote.py`)
Run on the host / verification server:

```sh
# Full attestation check (signature, PCR[8] baseline, and IMA PCR[10] log replay)
make verify-ima

# Test rejection of tampered boot measurements
make verify-tampered
```

---

## Repository Structure

```text
.
├── Makefile                      # Automated test & verification entrypoints
├── requirements-host.txt         # Host dependencies
├── scripts/
│   ├── start-swtpm.sh            # Launch local TPM 2.0 daemon
│   ├── run-qemu.sh               # Boot QEMU with virtio drive & TPM TIS interface
│   └── test-offline.sh           # End-to-end automated testing harness
├── guest/
│   └── attestation-agent.sh      # Modular agent: measure, quote, seal, unseal, ima-log
├── verifier/
│   └── verify_quote.py           # Verification engine: signature check & IMA math replay
├── results/                      # Cryptographic artifacts
│   ├── expected_pcr8.txt         # Known-good PCR[8] baseline
│   ├── expected_pcr10.txt        # Known-good PCR[10] baseline
│   ├── clean/                    # Authentic clean quote, keys & sealed object
│   └── tampered/                 # Tampered artifacts proving detection
├── docs/
│   ├── evaluation-notes.md       # Recorded experimental metrics & test logs
│   └── report-source-code-section.md
└── meta-myattestation/           # Custom Yocto / Poky Layer
    ├── recipes-kernel/linux/     # Kernel config fragments for Linux IMA & TPM TIS
    ├── recipes-security/         # Focused IMA measurement policy and early init script
    ├── recipes-bsp/u-boot/       # U-Boot TPM 2.0 configuration & boot scripts
    └── recipes-attestation/      # Target package recipe for attestation-agent
```

---

## Security Analysis & Known Limitations

An honest security audit of what this prototype accomplishes and its design boundaries:

* **Measured Boot vs. Secure Boot**: Measured boot provides *detection* and *auditing*, not *execution prevention*. Untrusted binaries will still execute; however, the state change will be recorded in PCRs, preventing subsequent secret unsealing and failing remote attestation.
* **PKI Identity Binding**: In this prototype, the host verifier validates that the quote is signed by the provided Attestation Key (`ak.pub`). In a commercial deployment, the Endorsement Key (EK) must be bound to a certificate signed by the TPM manufacturer's Certificate Authority (CA) to prevent synthetic software TPM impersonation.
* **RAM TOCTOU**: Once a secret is successfully unsealed by the TPM into volatile RAM, it relies on kernel memory isolation. A compromised kernel could expose unsealed secrets in memory.
* **Physical Bus Interception**: Hardware TPMs communicate with the SoC over SPI or I2C. A physical attacker with a logic analyzer could sniff unsealed secrets off the bus unless TPM 2.0 parameterized session encryption is used.

---

## Build Environment

* **Target Hardware**: ARM64 Virt Platform (`cortex-a57`)
* **Host Requirements**: `qemu-system-aarch64`, `swtpm`, `tpm2-tools`, `python3` (3.10+)
* **Yocto Compatibility**: Built for Yocto releases (`scarthgap`, `styhead`)
* **License**: MIT
