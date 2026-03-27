# Guest Attestation Agent

`attestation-agent.sh` runs inside the Yocto QEMU guest to interface with the emulated TPM 2.0 device.

Install location in the Yocto rootfs:
```text
/usr/bin/attestation-agent
```

---

## Usage & Commands

### 1. Measure Boot Artifact into PCR[8]
Computes the SHA-256 digest of an executable or image and extends it into PCR[8]:
```sh
attestation-agent measure /boot/Image 8
```

### 2. Generate Attestation Quote
Creates/loads an Endorsement Key (EK) and Attestation Key (AK), signs the selected PCR state against a challenger nonce, and produces quote artifacts:
```sh
attestation-agent quote /tmp/nonce.hex /tmp/quote-artifacts sha256:8,10
```

Generated artifacts written to the output directory:
* `ak.pub` / `ak.name`: Public identity of the Attestation Key.
* `quote.msg`: Binary `TPM2B_ATTEST` quote structure containing PCR digests and challenger nonce.
* `quote.sig`: Digital signature over `quote.msg` signed by the AK.
* `pcrs.out`: Binary PCR composite values at quote time.
* `pcr8.txt` / `pcr10.txt`: Text readouts of discrete PCR states.
* `ima_measurements.txt`: Copy of Linux IMA runtime measurement log (if securityfs is active).
* `nonce.hex`: Copy of the input challenge nonce.

### 3. Sealed Storage (PCR Policy Binding)
Locks a sensitive file to the current PCR[8] baseline:
```sh
attestation-agent seal /etc/secret.key /tmp/sealed-object o sha256:8
```

### 4. Unseal Secret
Authorizes with the TPM via a trial PCR policy session to unseal the secret:
```sh
attestation-agent unseal /tmp/sealed-object /tmp/recovered.key
```
If PCR[8] does not match the clean baseline policy, the TPM hardware denies the unseal request.

### 5. Extract IMA Runtime Measurement Log
Exports `/sys/kernel/security/ima/ascii_runtime_measurements` for host verification:
```sh
attestation-agent ima-log /tmp/ima_log.txt
```
