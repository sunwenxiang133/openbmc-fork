SUMMARY = "YU08 temperature sensor driver"
DESCRIPTION = "External Linux hwmon module for YU08 temperature sensors"

LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://yu08.c;beginline=1;endline=2;md5=657d74fcbced6c83d92fc8b579438888"

inherit module

SRC_URI = " \
    file://yu08.c \
    file://Makefile \
"

S = "${WORKDIR}"

KERNEL_MODULE_AUTOLOAD += "yu08"
