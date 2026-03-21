SUMMARY = "Custom focused Linux IMA measurement policy"
DESCRIPTION = "Installs /etc/ima/ima-policy and an init script to load the policy into securityfs at boot"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://ima-policy \
    file://ima-policy.sh \
"

inherit update-rc.d

INITSCRIPT_NAME = "ima-policy"
INITSCRIPT_PARAMS = "start 02 S ."

do_install() {
    install -d ${D}${sysconfdir}/ima
    install -m 0644 ${WORKDIR}/ima-policy ${D}${sysconfdir}/ima/ima-policy

    install -d ${D}${sysconfdir}/init.d
    install -m 0755 ${WORKDIR}/ima-policy.sh ${D}${sysconfdir}/init.d/ima-policy
}

FILES:${PN} += " \
    ${sysconfdir}/ima/ima-policy \
    ${sysconfdir}/init.d/ima-policy \
"
