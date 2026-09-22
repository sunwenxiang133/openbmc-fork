SUMMARY = "Fan control"
DESCRIPTION = ""

LICENSE = "CLOSED"
LIC_FILES_CHKSUM = ""
FILESPATH := "${THISDIR}/project/:"

SRC_URI = " \
    file://src/fan_control.cpp \
    file://src/fan_control.hpp \
    file://service_files/sophgo-fan-control.service \
    file://config/fan-config.json \
    file://meson_options.txt \
    file://meson.build \
"

S = "${WORKDIR}"


inherit meson systemd pkgconfig
inherit obmc-phosphor-dbus-service



SYSTEMD_AUTO_ENABLE = "enable"
SYSTEMD_SERVICE:${PN} = " \
    sophgo-fan-control.service \
"
FILES:${PN} += " \
    ${systemd_system_unitdir}/sophgo-fan-control.service \
"



DEPENDS += " \
    boost \
    libgpiod \
    nlohmann-json \
    sdbusplus \
    phosphor-logging \
  "
