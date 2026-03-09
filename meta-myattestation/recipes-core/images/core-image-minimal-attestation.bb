inherit core-image

IMAGE_FEATURES += "ssh-server-dropbear"

IMAGE_INSTALL:append = " \
    packagegroup-core-boot \
    tpm2-tools \
    tpm2-tss \
    attestation-agent \
"
