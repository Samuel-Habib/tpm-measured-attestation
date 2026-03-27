SUMMARY = "Guest attestation helper for TPM measured boot prototype"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://attestation-agent.sh"

S = "${WORKDIR}"

RDEPENDS:${PN} += "bash tpm2-tools coreutils"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/attestation-agent.sh ${D}${bindir}/attestation-agent
}
