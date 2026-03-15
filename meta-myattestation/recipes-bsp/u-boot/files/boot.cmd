# U-Boot boot script with TPM 2.0 measured boot
# Measures kernel and device tree into TPM PCRs prior to execution

echo "=== U-Boot Measured Boot Initializing ==="
tpm2 autostart
if test $? -ne 0; then
    echo "TPM2 autostart failed, attempting manual startup..."
    tpm2 init
    tpm2 startup TPM_SU_CLEAR
fi

echo "Loading kernel Image from virtio storage..."
load virtio 0:1 ${kernel_addr_r} /boot/Image

echo "Extending PCR[8] with Kernel Image digest..."
tpm2 pcr_extend 8 ${kernel_addr_r} ${filesize}

if test -n "${fdt_addr}"; then
    echo "Extending PCR[1] with FDT digest..."
    tpm2 pcr_extend 1 ${fdt_addr} 0x1000
fi

echo "Booting measured kernel..."
booti ${kernel_addr_r} - ${fdt_addr}
