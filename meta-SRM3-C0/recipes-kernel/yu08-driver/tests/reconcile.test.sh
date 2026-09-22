#!/bin/bash
set -eu
source "$(dirname "$0")/../files/yu08-hwmon-reconcile.sh"

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
I2C_SYSFS_ROOT=$fixture
mkdir -p "$fixture/devices" "$fixture/drivers/pca954x" "$fixture/drivers/yu08"
touch "$fixture/drivers/pca954x/bind" "$fixture/drivers/yu08/bind"
running=0
restarts=0
binds=0
fail_restart=0
host_is_running() { (( running )); }
restart_sensors() {
    (( fail_restart == 0 )) || return 1
    restarts=$((restarts + 1))
}
bind_device() {
    binds=$((binds + 1))
    ln -s "$fixture/drivers/$1" "$fixture/devices/$2/driver"
}
for device in 5-0070 7-0073; do
    mkdir -p "$fixture/devices/$device"
done
for chip in {0..7}; do
    printf -v device '%d-%04x' "$((80 + chip))" "$((96 + chip))"
    mkdir -p "$fixture/devices/$device"
done

reconcile_once
[[ $binds == 0 && $restarts == 0 ]]
running=1
reconcile_once
[[ $binds == 10 && $restarts == 1 ]]
reconcile_once
[[ $binds == 10 && $restarts == 1 ]]

# A later unbound device is retried, with a sensor rescan on recovery.
rm "$fixture/devices/83-0063/driver"
reconcile_once
[[ $binds == 11 && $restarts == 2 ]]

running=0
reconcile_once
running=1
fail_restart=1
reconcile_once || true
[[ $restarts == 2 ]]
fail_restart=0
reconcile_once
[[ $restarts == 3 ]]

# A Host transition during binding cancels further binding and the rescan.
running=0
reconcile_once
running=1
rm "$fixture/devices/5-0070/driver"
bind_device() { running=0; }
reconcile_once || true
[[ $restarts == 3 ]]
echo 'PASS: Host gating, late binding, rescan retries and power transitions'
