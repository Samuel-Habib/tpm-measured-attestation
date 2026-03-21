require recipes-core/images/core-image-minimal.bb

SUMMARY = "Minimal qemuarm64 image with TPM measured-boot attestation tools"

IMAGE_INSTALL:append = " \
    tpm2-tools \
    tpm2-tss \
    attestation-agent \
    ima-policy \
"
