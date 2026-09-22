SUMMARY = "YU08 temperature sensor driver"
DESCRIPTION = "Linux hwmon driver for Sophgo YU08 temperature sensor chips"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://yu08.c;beginline=1;endline=2;md5=657d74fcbced6c83d92fc8b579438888"

inherit module

SRC_URI = " \
    file://yu08.c \
    file://Makefile \
"

S = "${WORKDIR}"

# The module will be automatically loaded when the kernel boots
# and will probe devices declared in the device tree
KERNEL_MODULE_AUTOLOAD += "yu08"

do_configure[noexec] = "1"

do_compile() {
    oe_runmake -C ${STAGING_KERNEL_DIR} M=${S} modules
}

do_install() {
    oe_runmake -C ${STAGING_KERNEL_DIR} M=${S} INSTALL_MOD_PATH=${D} modules_install
}
