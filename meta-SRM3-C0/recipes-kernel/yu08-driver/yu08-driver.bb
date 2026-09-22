SUMMARY = "YU08 temperature sensor driver"
DESCRIPTION = "Linux hwmon driver for Sophgo YU08 temperature sensor chips"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://yu08.c;beginline=1;endline=2;md5=657d74fcbced6c83d92fc8b579438888"

inherit module systemd

SRC_URI = " \
    file://yu08.c \
    file://Makefile \
    file://yu08-hwmon-reconcile.sh \
    file://yu08-hwmon-reconcile.service \
"

S = "${WORKDIR}"

# The module will be automatically loaded when the kernel boots
# and will probe devices declared in the device tree
KERNEL_MODULE_AUTOLOAD += "yu08"

SYSTEMD_SERVICE:${PN} = "yu08-hwmon-reconcile.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"
RDEPENDS:${PN} += "kernel-module-yu08 bash systemd dbus-sensors entity-manager"
FILES:${PN} += "${sbindir}/yu08-hwmon-reconcile.sh"

do_configure[noexec] = "1"

do_compile() {
    oe_runmake -C ${STAGING_KERNEL_DIR} M=${S} modules
}

do_install() {
    oe_runmake -C ${STAGING_KERNEL_DIR} M=${S} INSTALL_MOD_PATH=${D} modules_install
    install -d ${D}${sbindir} ${D}${systemd_system_unitdir}
    install -m 0755 ${WORKDIR}/yu08-hwmon-reconcile.sh ${D}${sbindir}/
    install -m 0644 ${WORKDIR}/yu08-hwmon-reconcile.service ${D}${systemd_system_unitdir}/
}
