# https://www.coder.work/article/6433710

SUMMARY = "Fan control"
DESCRIPTION = ""

LICENSE = "CLOSED"
LIC_FILES_CHKSUM = ""
FILESPATH := "${THISDIR}/project/:"

SRC_URI = " \
    file://src/fan_control.cpp \
    file://src/fan_control.hpp \
    file://service_files/sophgo-fan-control.service \
    file://service_files/sophgo-riser-i2c-ctr.service \
    file://service_files/sophgo-nca9545-bind.service \
    file://service_files/sophgo-yu08-host-reconcile.service \
    file://service_files/sophgo-yu08-temp-scan.service \
    file://config/fan-config.json \
    file://meson_options.txt \
    file://meson.build \
    file://shell/sophgo-riser-i2c-function.sh \
    file://shell/sophgo-riser-i2c-scan.sh \
    file://shell/sophgo-nca9545-bind.sh \
    file://shell/sophgo-yu08-host-reconcile.sh \
    file://shell/sophgo-yu08-temp-scan.sh \
"

S = "${WORKDIR}"

RDEPENDS:${PN} += "bash i2c-tools"

inherit meson systemd pkgconfig
inherit obmc-phosphor-dbus-service



SYSTEMD_AUTO_ENABLE = "enable"
SYSTEMD_SERVICE:${PN} = " \
    sophgo-fan-control.service \
    sophgo-riser-i2c-ctr.service \
    sophgo-yu08-host-reconcile.service \
"
FILES:${PN} += " \
    ${systemd_system_unitdir}/sophgo-fan-control.service \
    ${systemd_system_unitdir}/sophgo-riser-i2c-ctr.service \
    ${systemd_system_unitdir}/sophgo-nca9545-bind.service \
    ${systemd_system_unitdir}/sophgo-yu08-host-reconcile.service \
    ${systemd_system_unitdir}/sophgo-yu08-temp-scan.service \
    ${sbindir}/sophgo-riser-i2c-function.sh \
    ${sbindir}/sophgo-riser-i2c-scan.sh \
    ${sbindir}/sophgo-nca9545-bind.sh \
    ${sbindir}/sophgo-yu08-host-reconcile.sh \
    ${sbindir}/sophgo-yu08-temp-scan.sh \
"



DEPENDS += " \
    boost \
    i2c-tools \
    libgpiod \
    nlohmann-json \
    sdbusplus \
    phosphor-logging \
  "


do_install:append() {

    install -d ${D}/${sbindir}
    install -m 0755 ${WORKDIR}/shell/sophgo-riser-i2c-function.sh ${D}/${sbindir}
    install -m 0755 ${WORKDIR}/shell/sophgo-riser-i2c-scan.sh ${D}/${sbindir}
    install -m 0755 ${WORKDIR}/shell/sophgo-nca9545-bind.sh ${D}/${sbindir}
    install -m 0755 ${WORKDIR}/shell/sophgo-yu08-host-reconcile.sh ${D}/${sbindir}
    install -m 0755 ${WORKDIR}/shell/sophgo-yu08-temp-scan.sh ${D}/${sbindir}
}
