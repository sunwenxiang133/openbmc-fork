#!/bin/bash
# Retry DT device probes after Host power becomes available.
I2C_SYSFS_ROOT=${I2C_SYSFS_ROOT:-/sys/bus/i2c}
was_running=0
rescan_pending=0

host_is_running() {
    local state
    state=$(busctl --timeout=2 get-property \
        xyz.openbmc_project.State.Host /xyz/openbmc_project/state/host0 \
        xyz.openbmc_project.State.Host CurrentHostState 2>/dev/null) || return 1
    [[ $state == 's "xyz.openbmc_project.State.Host.HostState.Running"' ]]
}

bind_device() {
    printf '%s' "$2" > "$I2C_SYSFS_ROOT/drivers/$1/bind"
}

restart_sensors() {
    systemctl restart xyz.openbmc_project.hwmontempsensor.service
}

ensure_bound() {
    local driver=$1 device=$2 actual
    host_is_running || return 1
    [[ -d $I2C_SYSFS_ROOT/devices/$device ]] || return 1
    if [[ -L $I2C_SYSFS_ROOT/devices/$device/driver ]]; then
        actual=$(readlink -f "$I2C_SYSFS_ROOT/devices/$device/driver") || return 1
        [[ $actual == "$(readlink -f "$I2C_SYSFS_ROOT/drivers/$driver")" ]]
        return $?
    fi
    [[ -e $I2C_SYSFS_ROOT/drivers/$driver/bind ]] || return 1
    if bind_device "$driver" "$device"; then
        rescan_pending=1
    else
        printf 'Probe retry failed: %s (%s)\n' "$device" "$driver" >&2
        return 1
    fi
}

reconcile_once() {
    local chip device
    if ! host_is_running; then
        was_running=0
        rescan_pending=0
        return 0
    fi
    if (( was_running == 0 )); then
        rescan_pending=1
        was_running=1
    fi

    ensure_bound pca954x 5-0070 || true
    ensure_bound pca954x 7-0073 || true
    for chip in {0..7}; do
        printf -v device '%d-%04x' "$((80 + chip))" "$((96 + chip))"
        ensure_bound yu08 "$device" || true
    done

    if ! host_is_running; then
        was_running=0
        rescan_pending=0
        return 0
    fi
    if (( rescan_pending )); then
        if restart_sensors; then
            rescan_pending=0
        else
            return 1
        fi
    fi
}

main() {
    while true; do
        reconcile_once || true
        sleep 3
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
