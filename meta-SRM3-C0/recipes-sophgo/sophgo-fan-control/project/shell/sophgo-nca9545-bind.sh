#!/bin/bash

I2C_SYSFS_ROOT=${I2C_SYSFS_ROOT:-/sys/bus/i2c}
NCA9545_DEVICE=${NCA9545_DEVICE:-7-0073}
BIND_MAX_ATTEMPTS=${BIND_MAX_ATTEMPTS:-30}
BIND_RETRY_DELAY=${BIND_RETRY_DELAY:-1}
BUSCTL_TIMEOUT=${BUSCTL_TIMEOUT:-2}

host_is_running() {
    local state

    if ! state=$(busctl --timeout="$BUSCTL_TIMEOUT" get-property \
        xyz.openbmc_project.State.Host \
        /xyz/openbmc_project/state/host0 \
        xyz.openbmc_project.State.Host \
        CurrentHostState 2>/dev/null); then
        printf 'Failed to read CurrentHostState\n' >&2
        return 1
    fi

    [[ $state == 's "xyz.openbmc_project.State.Host.HostState.Running"' ]]
}

mux_is_ready() {
    local device_root="$I2C_SYSFS_ROOT/devices/$NCA9545_DEVICE"
    local driver_link="$device_root/driver"
    local expected_driver="$I2C_SYSFS_ROOT/drivers/pca954x"
    local resolved_driver
    local channel
    local channel_link
    local channel_name
    local class_channel
    local expected_channel
    local resolved_channel
    local -A seen_buses=()

    [[ -L $driver_link && -e $driver_link ]] || return 1
    resolved_driver=$(readlink -f -- "$driver_link") || return 1
    expected_driver=$(readlink -f -- "$expected_driver") || return 1
    [[ $resolved_driver == "$expected_driver" ]] || return 1

    for channel in 0 1 2 3; do
        channel_link="$device_root/channel-$channel"
        [[ -L $channel_link && -e $channel_link ]] || return 1
        resolved_channel=$(readlink -f -- "$channel_link") || return 1
        [[ -d $resolved_channel ]] || return 1
        channel_name=${resolved_channel##*/}
        [[ $channel_name =~ ^i2c-[0-9]+$ ]] || return 1
        class_channel="$I2C_SYSFS_ROOT/devices/$channel_name"
        [[ -e $class_channel ]] || return 1
        expected_channel=$(readlink -f -- "$class_channel") || return 1
        [[ -d $expected_channel ]] || return 1
        [[ $resolved_channel == "$expected_channel" ]] || return 1
        [[ -z ${seen_buses[$channel_name]+present} ]] || return 1
        seen_buses[$channel_name]=1
    done
}

write_driver_bind() {
    if ! printf '%s' "$NCA9545_DEVICE" >"$I2C_SYSFS_ROOT/drivers/pca954x/bind"; then
        printf 'Failed to bind NCA9545 device %s\n' "$NCA9545_DEVICE" >&2
        return 1
    fi
}

retry_sleep() {
    sleep "$BIND_RETRY_DELAY"
}

bind_mux() {
    local attempt

    if ! [[ $BIND_MAX_ATTEMPTS =~ ^[1-9][0-9]*$ ]]; then
        printf 'BIND_MAX_ATTEMPTS must be a positive integer: %s\n' \
            "$BIND_MAX_ATTEMPTS" >&2
        return 1
    fi

    if ! [[ $BIND_RETRY_DELAY =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]]; then
        printf 'BIND_RETRY_DELAY must be a non-negative number: %s\n' \
            "$BIND_RETRY_DELAY" >&2
        return 1
    fi

    if mux_is_ready; then
        if ! host_is_running; then
            printf 'Host is not Running; refusing ready NCA9545 device %s\n' \
                "$NCA9545_DEVICE" >&2
            return 1
        fi
        printf 'NCA9545 mux %s is already ready\n' "$NCA9545_DEVICE" >&2
        return 0
    fi

    for (( attempt = 1; attempt <= BIND_MAX_ATTEMPTS; attempt += 1 )); do
        if mux_is_ready; then
            if ! host_is_running; then
                printf 'Host left Running after NCA9545 device %s became ready\n' \
                    "$NCA9545_DEVICE" >&2
                return 1
            fi
            printf 'NCA9545 mux %s became ready before attempt %d\n' \
                "$NCA9545_DEVICE" "$attempt" >&2
            return 0
        fi

        if ! host_is_running; then
            printf 'Host is not Running; refusing to bind NCA9545 device %s\n' \
                "$NCA9545_DEVICE" >&2
            return 1
        fi

        if ! write_driver_bind; then
            printf 'Bind attempt %d/%d did not complete successfully\n' \
                "$attempt" "$BIND_MAX_ATTEMPTS" >&2
        fi

        if mux_is_ready; then
            if ! host_is_running; then
                printf 'Host left Running after NCA9545 device %s became ready\n' \
                    "$NCA9545_DEVICE" >&2
                return 1
            fi
            printf 'NCA9545 mux %s became ready on attempt %d\n' \
                "$NCA9545_DEVICE" "$attempt" >&2
            return 0
        fi

        if (( attempt < BIND_MAX_ATTEMPTS )); then
            if ! retry_sleep; then
                printf 'Retry delay failed after bind attempt %d\n' "$attempt" >&2
                return 1
            fi
        fi
    done

    printf 'NCA9545 mux %s was not ready after %d bind attempts\n' \
        "$NCA9545_DEVICE" "$BIND_MAX_ATTEMPTS" >&2
    return 1
}

main() {
    bind_mux
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
