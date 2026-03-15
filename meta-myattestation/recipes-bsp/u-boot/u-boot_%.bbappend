FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += " \
    file://u-boot-tpm.cfg \
    file://boot.cmd \
"

DEPENDS += "u-boot-mkimage-native"

do_compile:append() {
    if [ -f "${WORKDIR}/boot.cmd" ]; then
        mkimage -A arm64 -T script -C none -d ${WORKDIR}/boot.cmd ${WORKDIR}/boot.scr
    fi
}

do_install:append() {
    if [ -f "${WORKDIR}/boot.scr" ]; then
        install -d ${D}/boot
        install -m 0644 ${WORKDIR}/boot.scr ${D}/boot/boot.scr
    fi
}

FILES:${PN} += "/boot/boot.scr"
