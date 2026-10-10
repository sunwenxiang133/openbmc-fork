SUMMARY = "YU08 userspace temperature sensor service"
DESCRIPTION = "Read YU08 temperatures and publish standard D-Bus sensors"

LICENSE = "CLOSED"
PV = "0.1"

SRC_URI = " \
    file://main.cpp \
    file://yu08-config.hpp \
    file://yu08-config.cpp \
    file://yu08-config-dbus.cpp \
    file://yu08-reader.hpp \
    file://yu08-reader.cpp \
    file://meson.build \
    file://yu08-temp-sensor.service \
"

S = "${WORKDIR}"

DEPENDS = " \
    boost \
    i2c-tools \
    sdbusplus \
    systemd \
"

inherit pkgconfig meson systemd

SYSTEMD_SERVICE:${PN} = "yu08-temp-sensor.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install:append() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/yu08-temp-sensor.service \
        ${D}${systemd_system_unitdir}/yu08-temp-sensor.service
}
