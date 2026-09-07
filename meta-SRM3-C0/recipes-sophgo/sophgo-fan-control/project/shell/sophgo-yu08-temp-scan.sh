#!/bin/bash
# SRM3-C0 YU08 Temperature Collector
# Reads temperature from 8 YU08 chips via SMBus and updates ExternalSensor D-Bus objects

# Configuration (may be overridden by the service environment)
I2C_SYSFS_ROOT=${I2C_SYSFS_ROOT:-/sys/bus/i2c}
SCAN_INTERVAL=${SCAN_INTERVAL:-3}
MAX_RETRIES=${MAX_RETRIES:-3}
RETRY_DELAY=${RETRY_DELAY:-0.1}
readonly I2C_SYSFS_ROOT SCAN_INTERVAL MAX_RETRIES RETRY_DELAY
readonly EXPECTED_BOARD_TYPE=0xb6

readonly DBUS_SERVICE="xyz.openbmc_project.ExternalSensor"
readonly DBUS_INTERFACE="xyz.openbmc_project.Sensor.Value"
readonly SENSOR_BASE="/xyz/openbmc_project/sensors/temperature"

# YU08 device table: index -> (switch device, address)
# IIC5 switch: CHIP0-3 (0x60-0x63)
# IIC7 switch: CHIP4-7 (0x64-0x67)
declare -A YU08_DEVICES=(
    [0]="5-0070 0x60"
    [1]="5-0070 0x61"
    [2]="5-0070 0x62"
    [3]="5-0070 0x63"
    [4]="7-0073 0x64"
    [5]="7-0073 0x65"
    [6]="7-0073 0x66"
    [7]="7-0073 0x67"
)
declare -A YU08_BUS_CACHE=()

# Function results are returned through globals so cache updates are not lost
# in command-substitution subshells.
discovered_bus=
smbus_value=

# SMBus commands
readonly CMD_CHIP_TEMP=0x00
readonly CMD_BOARD_TEMP=0x01
readonly CMD_BOARD_TYPE=0x02

# Logging helper
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Read an SMBus register with retry, without logging per-attempt failures.
# Args: bus, addr, command
# Returns: 0 on success (decimal value in $smbus_value), 1 on failure
read_bus() {
    local bus=$1
    local addr=$2
    local cmd=$3
    local attempt
    local raw_value

    smbus_value=
    for (( attempt = 1; attempt <= MAX_RETRIES; attempt++ )); do
        if raw_value=$(i2cget -y "$bus" "$addr" "$cmd" b 2>/dev/null); then
            if [[ $raw_value =~ ^0[xX]([0-9a-fA-F]+)$ ]]; then
                smbus_value=$((16#${BASH_REMATCH[1]}))
                return 0
            fi
            if [[ $raw_value =~ ^[0-9]+$ ]]; then
                smbus_value=$((10#$raw_value))
                return 0
            fi
        fi

        if (( attempt < MAX_RETRIES )); then
            sleep "$RETRY_DELAY"
        fi
    done

    return 1
}

# Find the unique child bus below a switch on which ADDR identifies as YU08.
# Args: switch device (for example 5-0070), address
# Returns: 0 on a unique match (numeric bus in $discovered_bus), 1 otherwise
discover_device_bus() {
    local switch_device=$1
    local addr=$2
    local channel_link
    local target
    local target_name
    local bus
    local -a matches=()

    discovered_bus=
    for channel_link in "$I2C_SYSFS_ROOT/devices/$switch_device"/channel-*; do
        [[ -L $channel_link ]] || continue
        target=$(readlink -f -- "$channel_link" 2>/dev/null) || continue
        [[ -d $target ]] || continue

        target_name=${target##*/}
        [[ $target_name =~ ^i2c-([0-9]+)$ ]] || continue
        bus=${BASH_REMATCH[1]}

        if read_bus "$bus" "$addr" "$CMD_BOARD_TYPE" &&
            (( smbus_value == EXPECTED_BOARD_TYPE )); then
            matches+=("$bus")
        fi
    done

    if (( ${#matches[@]} == 1 )); then
        discovered_bus=${matches[0]}
        return 0
    fi

    log "ERROR: Expected exactly one YU08 child bus for switch=$switch_device addr=$addr, found ${#matches[@]}" >&2
    return 1
}

# Populate the per-chip child-bus cache when needed.
# Args: chip index
ensure_device_bus() {
    local chip=$1
    local device=${YU08_DEVICES[$chip]-}
    local switch_device
    local addr

    if [[ -n ${YU08_BUS_CACHE[$chip]+present} ]]; then
        return 0
    fi
    if [[ -z $device ]]; then
        log "ERROR: No YU08 device mapping for chip=$chip" >&2
        return 1
    fi

    read -r switch_device addr <<<"$device"
    if ! discover_device_bus "$switch_device" "$addr"; then
        return 1
    fi

    YU08_BUS_CACHE[$chip]=$discovered_bus
    return 0
}

# Read one register using a chip's cached child bus. A failed cached read
# invalidates only that chip, then performs one immediate rediscovery/read.
# Args: chip index, command
# Returns: 0 on success (decimal value in $smbus_value), 1 on failure
smbus_read_chip() {
    local chip=$1
    local cmd=$2
    local device=${YU08_DEVICES[$chip]-}
    local switch_device
    local addr
    local bus

    if [[ -z $device ]]; then
        log "ERROR: Failed YU08 read chip=$chip switch=unknown bus=unknown addr=unknown cmd=$cmd" >&2
        return 1
    fi
    read -r switch_device addr <<<"$device"

    if ! ensure_device_bus "$chip"; then
        log "ERROR: Failed YU08 read chip=$chip switch=$switch_device bus=unknown addr=$addr cmd=$cmd" >&2
        return 1
    fi

    bus=${YU08_BUS_CACHE[$chip]}
    if read_bus "$bus" "$addr" "$cmd"; then
        return 0
    fi

    unset 'YU08_BUS_CACHE[$chip]'
    if ! ensure_device_bus "$chip"; then
        log "ERROR: Failed YU08 read chip=$chip switch=$switch_device bus=$bus addr=$addr cmd=$cmd" >&2
        return 1
    fi

    bus=${YU08_BUS_CACHE[$chip]}
    if read_bus "$bus" "$addr" "$cmd"; then
        return 0
    fi

    log "ERROR: Failed YU08 read chip=$chip switch=$switch_device bus=$bus addr=$addr cmd=$cmd" >&2
    return 1
}

# Read and verify a chip's board type. A cached bus that still ACKs but no
# longer identifies as YU08 is stale too (for example after mux bus-number
# reuse), so invalidate only this chip and perform one rediscovery/re-read.
# Args: chip index
# Returns: 0 only when register 0x02 is exactly EXPECTED_BOARD_TYPE
read_verified_board_type() {
    local chip=$1
    local device=${YU08_DEVICES[$chip]-}
    local switch_device
    local addr
    local stale_bus
    local bus

    if ! smbus_read_chip "$chip" "$CMD_BOARD_TYPE"; then
        return 1
    fi
    if (( smbus_value == EXPECTED_BOARD_TYPE )); then
        return 0
    fi

    if [[ -z $device ]]; then
        return 1
    fi
    read -r switch_device addr <<<"$device"
    stale_bus=${YU08_BUS_CACHE[$chip]-unknown}
    log "WARN: CHIP${chip} board type mismatch on cached bus: switch=$switch_device bus=$stale_bus addr=$addr expected=$EXPECTED_BOARD_TYPE got=0x$(printf '%x' "$smbus_value"); rediscovering"

    unset 'YU08_BUS_CACHE[$chip]'
    if ! ensure_device_bus "$chip"; then
        return 1
    fi

    bus=${YU08_BUS_CACHE[$chip]}
    if ! read_bus "$bus" "$addr" "$CMD_BOARD_TYPE"; then
        unset 'YU08_BUS_CACHE[$chip]'
        log "ERROR: Failed YU08 board-type re-read chip=$chip switch=$switch_device bus=$bus addr=$addr" >&2
        return 1
    fi
    if (( smbus_value != EXPECTED_BOARD_TYPE )); then
        log "ERROR: CHIP${chip} board type mismatch after rediscovery: switch=$switch_device bus=$bus addr=$addr expected=$EXPECTED_BOARD_TYPE got=0x$(printf '%x' "$smbus_value")" >&2
        unset 'YU08_BUS_CACHE[$chip]'
        return 1
    fi

    return 0
}

# Update D-Bus sensor value
# Args: sensor_name, value
update_sensor() {
    local sensor_name=$1
    local value=$2
    local path="${SENSOR_BASE}/${sensor_name}"

    if ! busctl set-property \
        "$DBUS_SERVICE" \
        "$path" \
        "$DBUS_INTERFACE" \
        Value d "$value" 2>/dev/null; then
        log "ERROR: Failed to update D-Bus sensor: $sensor_name"
        return 1
    fi
    return 0
}

# Perform one complete collection pass.
collect_once() {
    local all_valid=true
    local max_temp=0
    local chip_idx
    local chip_temp
    local board_temp

    for chip_idx in {0..7}; do
        # Read board type for validation, including stale-cache recovery when
        # an old bus still ACKs but no longer identifies as YU08.
        if ! read_verified_board_type "$chip_idx"; then
            all_valid=false
            continue
        fi

        # Read chip temperature.
        if ! smbus_read_chip "$chip_idx" "$CMD_CHIP_TEMP"; then
            all_valid=false
            continue
        fi
        chip_temp=$smbus_value

        # Read board temperature.
        if ! smbus_read_chip "$chip_idx" "$CMD_BOARD_TEMP"; then
            all_valid=false
            continue
        fi
        board_temp=$smbus_value

        # Update individual sensors.
        if ! update_sensor "YU08_Chip${chip_idx}_Temp" "$chip_temp"; then
            all_valid=false
        fi

        if ! update_sensor "YU08_Board${chip_idx}_Temp" "$board_temp"; then
            all_valid=false
        fi

        # Track maximum temperature.
        if (( chip_temp > max_temp )); then
            max_temp=$chip_temp
        fi
        if (( board_temp > max_temp )); then
            max_temp=$board_temp
        fi
    done

    # Update aggregate temperature.
    if [[ $all_valid == true ]]; then
        if update_sensor "YU08_Max_Temp" "$max_temp"; then
            log "INFO: Scan complete, max_temp=${max_temp}°C"
            return 0
        fi

        if update_sensor "YU08_Max_Temp" "-1"; then
            log "WARN: Failed to publish max_temp=${max_temp}°C; fallback YU08_Max_Temp set to -1"
        else
            log "ERROR: Failed to publish YU08_Max_Temp=-1 after max temperature update failure" >&2
        fi
    else
        # Mark as failed: sophgo-fan-control will trigger full speed.
        if update_sensor "YU08_Max_Temp" "-1"; then
            log "WARN: Scan incomplete, YU08_Max_Temp set to -1 (failed state)"
        else
            log "ERROR: Failed to publish YU08_Max_Temp=-1 after incomplete scan" >&2
        fi
    fi

    return 1
}

# Main collection loop
main() {
    log "YU08 temperature collector started"
    log "Scan interval: ${SCAN_INTERVAL}s, Timeout: 10s, Devices: 8"

    while true; do
        collect_once || true
        sleep "$SCAN_INTERVAL"
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
