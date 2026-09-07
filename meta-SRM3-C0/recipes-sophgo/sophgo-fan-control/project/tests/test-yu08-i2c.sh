#!/usr/bin/env bash
# Zero-dependency contract tests for YU08 dynamic I2C discovery, mux binding,
# and host/collector reconciliation.  Every hardware-facing path is redirected
# to a per-test temporary fixture before a production script is sourced.

set -uo pipefail

readonly TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly PROJECT_DIR=$(cd -- "$TEST_DIR/.." && pwd)
readonly COLLECTOR_SCRIPT="$PROJECT_DIR/shell/sophgo-yu08-temp-scan.sh"
readonly BINDER_SCRIPT="$PROJECT_DIR/shell/sophgo-nca9545-bind.sh"
readonly BINDER_SERVICE="$PROJECT_DIR/service_files/sophgo-nca9545-bind.service"
readonly RECONCILER_SCRIPT="$PROJECT_DIR/shell/sophgo-yu08-host-reconcile.sh"
readonly TEST_FILTER=${TEST_FILTER:-}

case $TEST_FILTER in
    '' | discover | bind | reconcile) ;;
    *)
        printf 'FAIL: invalid TEST_FILTER=%q; expected discover, bind, reconcile, or empty\n' \
            "$TEST_FILTER" >&2
        exit 2
        ;;
esac

# Keep the unfiltered suite's first failure deterministic while the production
# scripts are being developed in separate TDD steps.  Category filters allow
# each step to be driven independently (for example, TEST_FILTER=discover).
preflight_missing=0

require_script_file() {
    local script=$1

    if [[ ! -f $script ]]; then
        printf 'FAIL: required production script is missing: %s\n' "$script" >&2
        preflight_missing=1
    fi
}

filter_selects_category() {
    local category=$1

    [[ -z $TEST_FILTER || $TEST_FILTER == "$category" ]]
}

if filter_selects_category discover; then
    require_script_file "$COLLECTOR_SCRIPT"
fi
if filter_selects_category bind; then
    require_script_file "$BINDER_SCRIPT"
fi
if filter_selects_category reconcile; then
    require_script_file "$RECONCILER_SCRIPT"
fi

if (( preflight_missing != 0 )); then
    printf 'RED: production prerequisites are not implemented yet.\n' >&2
    exit 1
fi

verify_script_source_contract() {
    local label=$1
    local category=$2
    local script=$3
    shift 3

    local line
    local trimmed
    local has_source_guard=0
    local has_guarded_main=0
    local inside_source_guard=0
    local contract_missing=0
    local expected_function
    local -A api_found=()

    while IFS= read -r line || [[ -n $line ]]; do
        trimmed=${line#"${line%%[![:space:]]*}"}
        trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
        [[ $trimmed == \#* ]] && continue

        if [[ $trimmed == 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' ||
            $trimmed == 'if [[ ${BASH_SOURCE[0]} == "$0" ]]; then' ]]; then
            has_source_guard=1
            inside_source_guard=1
            continue
        fi
        if (( inside_source_guard != 0 )) && [[ $trimmed == 'main "$@"' ]]; then
            has_guarded_main=1
        fi
        if (( inside_source_guard != 0 )) && [[ $trimmed == fi ]]; then
            inside_source_guard=0
        fi

        for expected_function in "$@"; do
            if [[ $trimmed == "$expected_function() {"* ]]; then
                api_found[$expected_function]=1
            fi
        done
    done <"$script"

    for expected_function in "$@"; do
        if [[ ${api_found[$expected_function]-0} != 1 ]]; then
            printf 'FAIL: %s source contract is missing %s()\n' \
                "$label" "$expected_function" >&2
            contract_missing=1
        fi
    done
    if (( has_source_guard == 0 )); then
        printf 'FAIL: %s source contract is missing the exact BASH_SOURCE[0] guard\n' \
            "$label" >&2
        contract_missing=1
    fi
    if (( has_guarded_main == 0 )); then
        printf 'FAIL: %s source contract is missing guarded main "$@"\n' \
            "$label" >&2
        contract_missing=1
    fi

    if (( contract_missing != 0 )); then
        printf 'RED: %s is not safe to source for %s tests.\n' \
            "$label" "$category" >&2
        return 1
    fi
}

if filter_selects_category discover; then
    verify_script_source_contract \
        collector discover "$COLLECTOR_SCRIPT" \
        discover_device_bus ensure_device_bus smbus_read_chip \
        read_verified_board_type collect_once || exit 1
fi
if filter_selects_category bind; then
    verify_script_source_contract \
        binder bind "$BINDER_SCRIPT" \
        host_is_running mux_is_ready write_driver_bind retry_sleep bind_mux || exit 1
fi
if filter_selects_category reconcile; then
    verify_script_source_contract \
        reconciler reconcile "$RECONCILER_SCRIPT" \
        host_is_running collector_is_active start_collector stop_collector \
        reconcile_once || exit 1
fi

tests_run=0
tests_passed=0
tests_failed=0
fixture=
fixture_root=

fail() {
    printf '    assertion failed: %s\n' "$*" >&2
    return 1
}

assert_eq() {
    local expected=$1
    local actual=$2
    local context=${3:-values differ}

    if [[ $actual != "$expected" ]]; then
        fail "$context (expected '$expected', got '$actual')"
    fi
}

assert_numeric_eq() {
    local expected=$1
    local actual=$2
    local context=${3:-numeric values differ}

    if ! [[ $expected =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] ||
        ! [[ $actual =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]]; then
        fail "$context (expected and actual must both be numeric: '$expected', '$actual')"
        return
    fi

    if (( expected != actual )); then
        fail "$context (expected '$expected', got '$actual')"
    fi
}

require_functions() {
    local function_name

    for function_name in "$@"; do
        if ! declare -F "$function_name" >/dev/null; then
            fail "required function '$function_name' was not defined when the script was sourced"
            return 1
        fi
    done
}

cleanup_fixture() {
    local allowed_prefix="${TMPDIR:-/tmp}/sophgo-yu08-test."

    [[ -n ${fixture:-} && -n ${fixture_root:-} ]] || return 0
    if [[ $fixture != "$fixture_root" || $fixture != "$allowed_prefix"* ]]; then
        printf 'REFUSING unsafe fixture cleanup: fixture=%q fixture_root=%q prefix=%q\n' \
            "$fixture" "$fixture_root" "$allowed_prefix" >&2
        return 1
    fi

    [[ -d $fixture_root ]] || return 0
    rm -rf -- "$fixture_root"
}

new_fixture() {
    fixture=$(mktemp -d "${TMPDIR:-/tmp}/sophgo-yu08-test.XXXXXX") || return 1
    declare -gr fixture_root=$fixture
    trap cleanup_fixture EXIT

    export I2C_SYSFS_ROOT="$fixture/sys/bus/i2c"
    export FAKE_I2CGET_TABLE="$fixture/i2cget.table"
    export FAKE_I2CGET_LOG="$fixture/i2cget.log"
    export FAKE_BUSCTL_LOG="$fixture/busctl.log"
    export FAKE_SYSTEMCTL_LOG="$fixture/systemctl.log"
    export FAKE_BUSCTL_RC=1
    export FAKE_BUSCTL_OUTPUT=
    export FAKE_SYSTEMCTL_RC=1
    export FAKE_SYSTEMCTL_OUTPUT=
    export NCA9545_DEVICE=7-0073
    export BIND_MAX_ATTEMPTS=3
    export BIND_RETRY_DELAY=0
    unset BUSCTL_TIMEOUT
    unset RECONCILE_BUSCTL_TIMEOUT

    mkdir -p \
        "$I2C_SYSFS_ROOT/devices" \
        "$I2C_SYSFS_ROOT/drivers/pca954x" \
        "$fixture/bin" || return 1
    : >"$FAKE_I2CGET_TABLE"
    : >"$FAKE_I2CGET_LOG"
    : >"$FAKE_BUSCTL_LOG"
    : >"$FAKE_SYSTEMCTL_LOG"

    cat >"$fixture/bin/i2cget" <<'FAKE_I2CGET'
#!/usr/bin/env bash
set -u

table_file=${FAKE_I2CGET_TABLE:?}
log_file=${FAKE_I2CGET_LOG:?}

if (( $# != 5 )) || [[ $1 != -y || $5 != b ]]; then
    printf 'invalid invocation: %s\n' "$*" >>"$log_file"
    exit 64
fi

bus=$2
addr=$3
reg=$4
mode=$5
printf '%s|%s|%s|%s\n' "$bus" "$addr" "$reg" "$mode" >>"$log_file"

numeric_equal() {
    local left=$1
    local right=$2

    [[ $left =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] || return 1
    [[ $right =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] || return 1
    (( left == right ))
}

while IFS='|' read -r row_bus row_addr row_reg row_value row_rc; do
    [[ -n $row_bus ]] || continue
    if [[ $row_bus == "$bus" ]] &&
        numeric_equal "$row_addr" "$addr" &&
        numeric_equal "$row_reg" "$reg"; then
        row_rc=${row_rc:-0}
        if (( row_rc == 0 )); then
            printf '%s\n' "$row_value"
        fi
        exit "$row_rc"
    fi
done <"$table_file"

exit 1
FAKE_I2CGET

    cat >"$fixture/bin/busctl" <<'FAKE_BUSCTL'
#!/usr/bin/env bash
set -u

printf '%s\n' "$*" >>"${FAKE_BUSCTL_LOG:?}"
if [[ -n ${FAKE_BUSCTL_OUTPUT:-} ]]; then
    printf '%s\n' "$FAKE_BUSCTL_OUTPUT"
fi
exit "${FAKE_BUSCTL_RC:-1}"
FAKE_BUSCTL

    cat >"$fixture/bin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
set -u

printf '%s\n' "$*" >>"${FAKE_SYSTEMCTL_LOG:?}"
if [[ -n ${FAKE_SYSTEMCTL_OUTPUT:-} ]]; then
    printf '%s\n' "$FAKE_SYSTEMCTL_OUTPUT"
fi
exit "${FAKE_SYSTEMCTL_RC:-1}"
FAKE_SYSTEMCTL

    chmod +x "$fixture/bin/i2cget" || return 1
    chmod +x "$fixture/bin/busctl" "$fixture/bin/systemctl" || return 1
    export PATH="$fixture/bin:$PATH"
}

add_i2c_response() {
    local bus=$1
    local addr=$2
    local reg=$3
    local value=$4
    local rc=${5:-0}

    printf '%s|%s|%s|%s|%s\n' "$bus" "$addr" "$reg" "$value" "$rc" >>"$FAKE_I2CGET_TABLE"
}

numeric_equal() {
    local left=$1
    local right=$2

    [[ $left =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] || return 1
    [[ $right =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] || return 1
    (( left == right ))
}

i2c_call_was_logged() {
    local wanted_bus=$1
    local wanted_addr=$2
    local wanted_reg=$3
    local seen_bus seen_addr seen_reg seen_mode

    while IFS='|' read -r seen_bus seen_addr seen_reg seen_mode; do
        if [[ $seen_bus == "$wanted_bus" ]] &&
            numeric_equal "$seen_addr" "$wanted_addr" &&
            numeric_equal "$seen_reg" "$wanted_reg" &&
            [[ $seen_mode == b ]]; then
            return 0
        fi
    done <"$FAKE_I2CGET_LOG"
    return 1
}

assert_i2c_call_logged() {
    local bus=$1
    local addr=$2
    local reg=$3

    i2c_call_was_logged "$bus" "$addr" "$reg" ||
        fail "i2cget call bus=$bus addr=$addr reg=$reg was not recorded"
}

assert_bus_not_logged() {
    local unwanted_bus=$1
    local seen_bus rest

    while IFS='|' read -r seen_bus rest; do
        if [[ $seen_bus == "$unwanted_bus" ]]; then
            fail "unexpected i2cget access to parent/static bus $unwanted_bus"
            return
        fi
    done <"$FAKE_I2CGET_LOG"
}

count_i2c_calls() {
    local wanted_bus=$1
    local wanted_addr=$2
    local wanted_reg=$3
    local seen_bus seen_addr seen_reg seen_mode
    local count=0

    while IFS='|' read -r seen_bus seen_addr seen_reg seen_mode; do
        if [[ $seen_bus == "$wanted_bus" ]] &&
            numeric_equal "$seen_addr" "$wanted_addr" &&
            numeric_equal "$seen_reg" "$wanted_reg"; then
            (( count += 1 ))
        fi
    done <"$FAKE_I2CGET_LOG"
    printf '%s\n' "$count"
}

make_channel() {
    local switch_device=$1
    local channel=$2
    local bus=$3
    local physical_bus="$fixture/sys/devices/platform/fake-i2c/i2c-$bus"

    mkdir -p \
        "$I2C_SYSFS_ROOT/devices/$switch_device" \
        "$physical_bus" || return 1
    if [[ ! -e $I2C_SYSFS_ROOT/devices/i2c-$bus ]]; then
        ln -s "../../../devices/platform/fake-i2c/i2c-$bus" \
            "$I2C_SYSFS_ROOT/devices/i2c-$bus" || return 1
    fi
    ln -s "$physical_bus" \
        "$I2C_SYSFS_ROOT/devices/$switch_device/channel-$channel"
}

repoint_channel() {
    local switch_device=$1
    local channel=$2
    local bus=$3

    rm -f -- "$I2C_SYSFS_ROOT/devices/$switch_device/channel-$channel"
    make_channel "$switch_device" "$channel" "$bus"
}

make_dangling_channel() {
    local switch_device=$1
    local channel=$2
    local bus=$3

    mkdir -p "$I2C_SYSFS_ROOT/devices/$switch_device" || return 1
    ln -s "../i2c-$bus" "$I2C_SYSFS_ROOT/devices/$switch_device/channel-$channel"
}

make_invalid_channel_target() {
    local switch_device=$1
    local channel=$2

    mkdir -p \
        "$I2C_SYSFS_ROOT/devices/$switch_device" \
        "$I2C_SYSFS_ROOT/devices/i2c-invalid" || return 1
    ln -s ../i2c-invalid "$I2C_SYSFS_ROOT/devices/$switch_device/channel-$channel"
}

make_mux_driver_link() {
    mkdir -p "$I2C_SYSFS_ROOT/devices/$NCA9545_DEVICE" || return 1
    ln -s ../../drivers/pca954x "$I2C_SYSFS_ROOT/devices/$NCA9545_DEVICE/driver"
}

make_mux_ready() {
    local first_bus=${1:-80}
    local channel

    make_mux_driver_link || return 1
    for channel in 0 1 2 3; do
        make_channel "$NCA9545_DEVICE" "$channel" "$(( first_bus + channel ))" || return 1
    done
}

source_failed() {
    local script=$1
    local source_rc=$2

    if (( source_rc != 0 )); then
        fail "sourcing '$script' returned status $source_rc"
    fi
}

test_discover_finds_non_contiguous_child_buses() {
    new_fixture || return
    trap cleanup_fixture EXIT
    make_channel 5-0070 0 31 || return
    make_channel 7-0073 2 82 || return
    mkdir -p "$I2C_SYSFS_ROOT/devices/i2c-144" || return
    add_i2c_response 31 0x60 0x02 0xB6 0
    add_i2c_response 82 0x60 0x02 0xb6 0
    add_i2c_response 82 0x64 0x02 0xb6 0
    add_i2c_response 144 0x60 0x02 0xb6 0

    local source_rc=0
    source "$COLLECTOR_SCRIPT" || source_rc=$?
    set +e
    source_failed "$COLLECTOR_SCRIPT" "$source_rc" || return
    require_functions discover_device_bus ensure_device_bus smbus_read_chip || return

    discover_device_bus 5-0070 0x60
    local discover_rc=$?
    (( discover_rc == 0 )) || { fail "discover_device_bus rejected the unique i2c-31 match"; return; }
    assert_eq 31 "${discovered_bus-}" "discovered bus for 5-0070" || return

    discover_device_bus 7-0073 0x64
    discover_rc=$?
    (( discover_rc == 0 )) || { fail "discover_device_bus rejected the unique i2c-82 match"; return; }
    assert_eq 82 "${discovered_bus-}" "discovered bus for 7-0073" || return

    assert_i2c_call_logged 31 0x60 0x02 || return
    assert_i2c_call_logged 82 0x64 0x02 || return
    i2c_call_was_logged 82 0x60 0x02 && {
        fail "discovery probed the same address below a different switch"
        return
    }
    assert_bus_not_logged 144 || return
    assert_bus_not_logged 5 || return
    assert_bus_not_logged 7
}

test_discover_rejects_zero_matches() {
    new_fixture || return
    trap cleanup_fixture EXIT
    make_channel 5-0070 0 31 || return
    make_channel 5-0070 1 47 || return
    add_i2c_response 31 0x60 0x02 0xb5 0
    add_i2c_response 47 0x60 0x02 '' 1

    local source_rc=0
    source "$COLLECTOR_SCRIPT" || source_rc=$?
    set +e
    source_failed "$COLLECTOR_SCRIPT" "$source_rc" || return
    require_functions discover_device_bus || return

    discover_device_bus 5-0070 0x60
    local discover_rc=$?
    (( discover_rc != 0 )) || fail "zero valid board-type matches must fail discovery"
}

test_discover_rejects_two_matches() {
    new_fixture || return
    trap cleanup_fixture EXIT
    make_channel 5-0070 0 31 || return
    make_channel 5-0070 1 82 || return
    add_i2c_response 31 0x60 0x02 0xb6 0
    add_i2c_response 82 0x60 0x02 0xB6 0

    local source_rc=0
    source "$COLLECTOR_SCRIPT" || source_rc=$?
    set +e
    source_failed "$COLLECTOR_SCRIPT" "$source_rc" || return
    require_functions discover_device_bus || return

    discover_device_bus 5-0070 0x60
    local discover_rc=$?
    (( discover_rc != 0 )) || { fail "ambiguous discovery with two valid matches must fail"; return; }
    assert_i2c_call_logged 31 0x60 0x02 || return
    assert_i2c_call_logged 82 0x60 0x02
}

test_discover_ignores_dangling_and_invalid_targets() {
    new_fixture || return
    trap cleanup_fixture EXIT
    make_dangling_channel 5-0070 0 999 || return
    make_invalid_channel_target 5-0070 1 || return
    make_channel 5-0070 3 82 || return
    add_i2c_response 82 0x60 0x02 0xb6 0

    local source_rc=0
    source "$COLLECTOR_SCRIPT" || source_rc=$?
    set +e
    source_failed "$COLLECTOR_SCRIPT" "$source_rc" || return
    require_functions discover_device_bus || return

    discover_device_bus 5-0070 0x60
    local discover_rc=$?
    (( discover_rc == 0 )) || { fail "valid target was not found beside invalid channel links"; return; }
    assert_eq 82 "${discovered_bus-}" "bus selected after ignoring invalid targets" || return
    assert_bus_not_logged 999 || return
    assert_bus_not_logged invalid
}

test_discover_cache_maps_chip_to_switch() {
    new_fixture || return
    trap cleanup_fixture EXIT
    make_channel 7-0073 0 82 || return
    add_i2c_response 82 0x64 0x02 0xB6 0

    local source_rc=0
    source "$COLLECTOR_SCRIPT" || source_rc=$?
    set +e
    source_failed "$COLLECTOR_SCRIPT" "$source_rc" || return
    require_functions discover_device_bus ensure_device_bus smbus_read_chip || return

    local cache_declaration
    cache_declaration=$(declare -p YU08_BUS_CACHE 2>/dev/null) || {
        fail "YU08_BUS_CACHE was not declared"
        return
    }
    [[ $cache_declaration == 'declare -A '* ]] || {
        fail "YU08_BUS_CACHE must be an associative array"
        return
    }

    ensure_device_bus 4
    local ensure_rc=$?
    (( ensure_rc == 0 )) || { fail "ensure_device_bus could not resolve CHIP4"; return; }
    assert_eq 82 "${YU08_BUS_CACHE[4]-}" "cached child bus for CHIP4"
}

test_discover_cache_recovers_after_channel_moves() {
    new_fixture || return
    trap cleanup_fixture EXIT
    make_channel 5-0070 0 31 || return
    add_i2c_response 31 0x60 0x02 0xb6 0
    add_i2c_response 31 0x60 0x00 '' 1
    add_i2c_response 82 0x60 0x02 0xB6 0
    add_i2c_response 82 0x60 0x00 0x2a 0

    local source_rc=0
    source "$COLLECTOR_SCRIPT" || source_rc=$?
    set +e
    source_failed "$COLLECTOR_SCRIPT" "$source_rc" || return
    require_functions discover_device_bus ensure_device_bus smbus_read_chip || return

    ensure_device_bus 0
    local ensure_rc=$?
    (( ensure_rc == 0 )) || { fail "initial CHIP0 discovery failed"; return; }
    assert_eq 31 "${YU08_BUS_CACHE[0]-}" "initial cached bus" || return

    repoint_channel 5-0070 0 82 || return

    smbus_read_chip 0 0x00
    local read_rc=$?
    (( read_rc == 0 )) || { fail "stale cached bus was not recovered"; return; }
    assert_eq 82 "${YU08_BUS_CACHE[0]-}" "cache after rediscovery" || return
    assert_numeric_eq 0x2a "${smbus_value-}" "register value after rediscovery" || return
    assert_i2c_call_logged 31 0x60 0x00 || return
    assert_i2c_call_logged 82 0x60 0x02 || return
    assert_i2c_call_logged 82 0x60 0x00 || return

    local rediscovery_count
    rediscovery_count=$(count_i2c_calls 82 0x60 0x02)
    assert_eq 1 "$rediscovery_count" "number of immediate rediscovery probes"
}

test_discover_cache_recovers_after_board_type_mismatch() {
    new_fixture || return
    trap cleanup_fixture EXIT
    make_channel 5-0070 0 82 || return
    add_i2c_response 31 0x60 0x02 0xb5 0
    add_i2c_response 82 0x60 0x02 0xb6 0

    local source_rc=0
    source "$COLLECTOR_SCRIPT" || source_rc=$?
    set +e
    source_failed "$COLLECTOR_SCRIPT" "$source_rc" || return
    require_functions read_verified_board_type || return

    # Simulate a bus number that was cached before the mux was rebound, then
    # reused by a different device which still ACKs but is not a YU08.
    YU08_BUS_CACHE[0]=31
    YU08_BUS_CACHE[1]=99

    read_verified_board_type 0
    local read_rc=$?
    (( read_rc == 0 )) || {
        fail "board-type mismatch on a cached bus was not recovered"
        return
    }
    assert_eq 82 "${YU08_BUS_CACHE[0]-}" \
        "cache after board-type mismatch rediscovery" || return
    assert_numeric_eq 0xb6 "${smbus_value-}" \
        "board type after mismatch rediscovery" || return
    assert_eq 99 "${YU08_BUS_CACHE[1]-}" \
        "another chip's cache must remain untouched" || return

    local stale_read_count rediscovery_read_count
    stale_read_count=$(count_i2c_calls 31 0x60 0x02)
    rediscovery_read_count=$(count_i2c_calls 82 0x60 0x02)
    assert_eq 1 "$stale_read_count" \
        "reads from the stale cached bus" || return
    assert_eq 2 "$rediscovery_read_count" \
        "one discovery probe plus one verified re-read"
}

test_collect_max_write_failure_publishes_failed_state() {
    new_fixture || return
    trap cleanup_fixture EXIT

    local source_rc=0
    source "$COLLECTOR_SCRIPT" || source_rc=$?
    set +e
    source_failed "$COLLECTOR_SCRIPT" "$source_rc" || return
    require_functions collect_once || return

    local max_updates=
    smbus_read_chip() {
        local chip=$1
        local cmd=$2

        case $cmd in
            "$CMD_BOARD_TYPE") smbus_value=$EXPECTED_BOARD_TYPE ;;
            "$CMD_CHIP_TEMP") smbus_value=$((60 + chip)) ;;
            "$CMD_BOARD_TEMP") smbus_value=$((40 + chip)) ;;
            *) return 1 ;;
        esac
    }
    update_sensor() {
        local sensor_name=$1
        local value=$2

        if [[ $sensor_name == YU08_Max_Temp ]]; then
            max_updates="${max_updates:+$max_updates,}$value"
            [[ $value == -1 ]]
            return
        fi
        return 0
    }

    collect_once >"$fixture/collect.log" 2>&1
    local collect_rc=$?
    (( collect_rc != 0 )) || {
        fail "failed normal aggregate write must make collect_once fail"
        return
    }
    assert_eq '67,-1' "$max_updates" \
        "normal max write followed by failed-state fallback" || return
    if grep -Fq 'Scan complete' "$fixture/collect.log"; then
        fail "failed aggregate write must not log Scan complete"
        return
    fi
    grep -Fq 'fallback YU08_Max_Temp set to -1' "$fixture/collect.log" ||
        fail "successful failed-state fallback was not logged"
}

test_collect_incomplete_scan_publishes_failed_state_and_fails() {
    new_fixture || return
    trap cleanup_fixture EXIT

    local source_rc=0
    source "$COLLECTOR_SCRIPT" || source_rc=$?
    set +e
    source_failed "$COLLECTOR_SCRIPT" "$source_rc" || return
    require_functions collect_once || return

    local max_updates=
    smbus_read_chip() { return 1; }
    update_sensor() {
        local sensor_name=$1
        local value=$2

        [[ $sensor_name == YU08_Max_Temp ]] || return 1
        max_updates="${max_updates:+$max_updates,}$value"
        [[ $value == -1 ]]
    }

    collect_once >"$fixture/collect.log" 2>&1
    local collect_rc=$?
    (( collect_rc != 0 )) || {
        fail "an incomplete scan must make collect_once fail"
        return
    }
    assert_eq '-1' "$max_updates" \
        "failed-state update after incomplete scan" || return
    grep -Fq 'YU08_Max_Temp set to -1' "$fixture/collect.log" ||
        fail "successful incomplete-scan failed state was not logged"
}

test_collect_failed_state_write_failure_is_reported() {
    new_fixture || return
    trap cleanup_fixture EXIT

    local source_rc=0
    source "$COLLECTOR_SCRIPT" || source_rc=$?
    set +e
    source_failed "$COLLECTOR_SCRIPT" "$source_rc" || return
    require_functions collect_once || return

    local max_updates=
    smbus_read_chip() { return 1; }
    update_sensor() {
        local sensor_name=$1
        local value=$2

        if [[ $sensor_name == YU08_Max_Temp ]]; then
            max_updates="${max_updates:+$max_updates,}$value"
        fi
        return 1
    }

    collect_once >"$fixture/collect.log" 2>&1
    local collect_rc=$?
    (( collect_rc != 0 )) || {
        fail "failed failed-state write must make collect_once fail"
        return
    }
    assert_eq '-1' "$max_updates" \
        "failed aggregate failed-state write" || return
    if grep -Fq 'YU08_Max_Temp set to -1' "$fixture/collect.log"; then
        fail "failed -1 write must not be logged as successful"
        return
    fi
    grep -Fq 'Failed to publish YU08_Max_Temp=-1' "$fixture/collect.log" ||
        fail "failed aggregate failed-state write was not reported"
}

test_bind_ready_mux_does_not_write() {
    new_fixture || return
    trap cleanup_fixture EXIT
    make_mux_ready 80 || return

    local source_rc=0
    source "$BINDER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$BINDER_SCRIPT" "$source_rc" || return
    require_functions host_is_running mux_is_ready write_driver_bind retry_sleep bind_mux || return

    local bind_writes=0
    local sleeps=0
    host_is_running() { return 0; }
    write_driver_bind() { (( bind_writes += 1 )); return 0; }
    retry_sleep() { (( sleeps += 1 )); return 0; }

    bind_mux
    local bind_rc=$?
    (( bind_rc == 0 )) || { fail "already-ready mux should succeed"; return; }
    assert_eq 0 "$bind_writes" "bind writes for an already-ready mux" || return
    assert_eq 0 "$sleeps" "retry sleeps for an already-ready mux"
}

test_bind_ready_mux_requires_host_running() {
    new_fixture || return
    trap cleanup_fixture EXIT
    make_mux_ready 85 || return

    local source_rc=0
    source "$BINDER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$BINDER_SCRIPT" "$source_rc" || return
    require_functions host_is_running mux_is_ready write_driver_bind retry_sleep bind_mux || return

    local bind_writes=0
    local sleeps=0
    host_is_running() { return 1; }
    write_driver_bind() { (( bind_writes += 1 )); return 0; }
    retry_sleep() { (( sleeps += 1 )); return 0; }

    bind_mux
    local bind_rc=$?
    (( bind_rc != 0 )) || {
        fail "already-ready mux must not succeed while Host is not Running"
        return
    }
    assert_eq 0 "$bind_writes" "bind writes for ready mux while Host is not Running" || return
    assert_eq 0 "$sleeps" "retry sleeps for ready mux while Host is not Running"
}

test_bind_production_host_running_uses_exact_busctl_call() {
    new_fixture || return
    trap cleanup_fixture EXIT
    export FAKE_BUSCTL_RC=0
    export FAKE_BUSCTL_OUTPUT='s "xyz.openbmc_project.State.Host.HostState.Running"'

    local source_rc=0
    source "$BINDER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$BINDER_SCRIPT" "$source_rc" || return

    host_is_running
    local host_rc=$?
    (( host_rc == 0 )) || { fail "production host_is_running rejected exact Running"; return; }

    local expected_call='--timeout=2 get-property xyz.openbmc_project.State.Host /xyz/openbmc_project/state/host0 xyz.openbmc_project.State.Host CurrentHostState'
    local actual_call
    actual_call=$(<"$FAKE_BUSCTL_LOG")
    assert_eq "$expected_call" "$actual_call" "production busctl invocation"
}

test_bind_production_host_running_rejects_off() {
    new_fixture || return
    trap cleanup_fixture EXIT
    export FAKE_BUSCTL_RC=0
    export FAKE_BUSCTL_OUTPUT='s "xyz.openbmc_project.State.Host.HostState.Off"'

    local source_rc=0
    source "$BINDER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$BINDER_SCRIPT" "$source_rc" || return

    host_is_running
    local host_rc=$?
    (( host_rc != 0 )) || fail "production host_is_running accepted exact Off"
}

test_bind_production_host_running_rejects_busctl_failure() {
    new_fixture || return
    trap cleanup_fixture EXIT
    export FAKE_BUSCTL_RC=1
    export FAKE_BUSCTL_OUTPUT='s "xyz.openbmc_project.State.Host.HostState.Running"'

    local source_rc=0
    source "$BINDER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$BINDER_SCRIPT" "$source_rc" || return

    host_is_running
    local host_rc=$?
    (( host_rc != 0 )) || fail "production host_is_running accepted failed busctl output"
}

test_bind_production_write_targets_exact_sysfs_file() {
    new_fixture || return
    trap cleanup_fixture EXIT

    local source_rc=0
    source "$BINDER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$BINDER_SCRIPT" "$source_rc" || return

    write_driver_bind
    local write_rc=$?
    (( write_rc == 0 )) || { fail "production write_driver_bind returned failure"; return; }

    local bind_path="$I2C_SYSFS_ROOT/drivers/pca954x/bind"
    [[ -f $bind_path ]] || { fail "production write_driver_bind did not create $bind_path"; return; }
    local bind_content
    bind_content=$(<"$bind_path")
    assert_eq '7-0073' "$bind_content" "production bind file content"
}

exercise_invalid_bind_retry_delay() {
    local invalid_delay=$1

    new_fixture || return
    trap cleanup_fixture EXIT
    export BIND_RETRY_DELAY=$invalid_delay

    local source_rc=0
    source "$BINDER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$BINDER_SCRIPT" "$source_rc" || return

    local bind_writes=0
    host_is_running() { return 0; }
    write_driver_bind() { (( bind_writes += 1 )); return 1; }
    retry_sleep() { return 0; }

    bind_mux
    local bind_rc=$?
    (( bind_rc != 0 )) || { fail "bind_mux accepted BIND_RETRY_DELAY=$invalid_delay"; return; }
    assert_eq 0 "$bind_writes" "bind writes for invalid BIND_RETRY_DELAY=$invalid_delay"
}

test_bind_rejects_negative_retry_delay() {
    exercise_invalid_bind_retry_delay -1
}

test_bind_rejects_nonnumeric_retry_delay() {
    exercise_invalid_bind_retry_delay nonsense
}

test_bind_service_timeout_covers_default_retry_budget() {
    local timeout_lines=0
    local timeout_value=
    local line

    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == TimeoutStartSec=* ]]; then
            (( timeout_lines += 1 ))
            timeout_value=${line#TimeoutStartSec=}
        fi
    done <"$BINDER_SERVICE"

    assert_eq 1 "$timeout_lines" "binder service TimeoutStartSec declarations" || return
    assert_eq 120 "$timeout_value" "binder service timeout for the 89-second default budget"
}

test_bind_succeeds_when_third_attempt_becomes_ready() {
    new_fixture || return
    trap cleanup_fixture EXIT

    local source_rc=0
    source "$BINDER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$BINDER_SCRIPT" "$source_rc" || return
    require_functions host_is_running mux_is_ready write_driver_bind retry_sleep bind_mux || return

    local bind_writes=0
    host_is_running() { return 0; }
    write_driver_bind() {
        (( bind_writes += 1 ))
        if (( bind_writes == 3 )); then
            make_mux_ready 90 || return 1
        fi
        return 0
    }
    retry_sleep() { return 0; }

    bind_mux
    local bind_rc=$?
    (( bind_rc == 0 )) || { fail "bind_mux did not accept readiness created on the third attempt"; return; }
    assert_eq 3 "$bind_writes" "bind attempts before readiness" || return
    mux_is_ready || fail "mux_is_ready rejected pca954x with four valid channels"
}

test_bind_exhaustion_fails() {
    new_fixture || return
    trap cleanup_fixture EXIT

    local source_rc=0
    source "$BINDER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$BINDER_SCRIPT" "$source_rc" || return
    require_functions host_is_running mux_is_ready write_driver_bind retry_sleep bind_mux || return

    local bind_writes=0
    host_is_running() { return 0; }
    write_driver_bind() { (( bind_writes += 1 )); return 1; }
    retry_sleep() { return 0; }

    bind_mux
    local bind_rc=$?
    (( bind_rc != 0 )) || { fail "bind_mux must fail after exhausting all attempts"; return; }
    assert_eq "$BIND_MAX_ATTEMPTS" "$bind_writes" "write attempts before exhaustion"
}

test_bind_incomplete_channels_never_count_as_ready() {
    new_fixture || return
    trap cleanup_fixture EXIT

    local source_rc=0
    source "$BINDER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$BINDER_SCRIPT" "$source_rc" || return
    require_functions host_is_running mux_is_ready write_driver_bind retry_sleep bind_mux || return

    local bind_writes=0
    host_is_running() { return 0; }
    write_driver_bind() {
        (( bind_writes += 1 ))
        if (( bind_writes == 1 )); then
            make_mux_driver_link || return 1
            make_channel "$NCA9545_DEVICE" 0 90 || return 1
            make_channel "$NCA9545_DEVICE" 1 91 || return 1
            make_channel "$NCA9545_DEVICE" 2 92 || return 1
        fi
        return 0
    }
    retry_sleep() { return 0; }

    bind_mux
    local bind_rc=$?
    (( bind_rc != 0 )) || { fail "driver link plus only three channels must not be ready"; return; }
    mux_is_ready && { fail "mux_is_ready accepted an incomplete channel set"; return; }
    assert_eq "$BIND_MAX_ATTEMPTS" "$bind_writes" \
        "bind attempts while channels remained incomplete"
}

test_bind_four_channels_without_driver_never_count_as_ready() {
    new_fixture || return
    trap cleanup_fixture EXIT
    local channel
    for channel in 0 1 2 3; do
        make_channel "$NCA9545_DEVICE" "$channel" "$(( 100 + channel ))" || return
    done

    local source_rc=0
    source "$BINDER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$BINDER_SCRIPT" "$source_rc" || return
    require_functions host_is_running mux_is_ready write_driver_bind retry_sleep bind_mux || return

    local bind_writes=0
    host_is_running() { return 0; }
    write_driver_bind() { (( bind_writes += 1 )); return 0; }
    retry_sleep() { return 0; }

    bind_mux
    local bind_rc=$?
    (( bind_rc != 0 )) || { fail "four channels without a driver link must not be ready"; return; }
    assert_eq "$BIND_MAX_ATTEMPTS" "$bind_writes" \
        "bind attempts with four channels but no driver"
}

test_bind_wrong_driver_never_counts_as_ready() {
    new_fixture || return
    trap cleanup_fixture EXIT
    mkdir -p \
        "$I2C_SYSFS_ROOT/drivers/not-pca954x" \
        "$I2C_SYSFS_ROOT/devices/$NCA9545_DEVICE" || return
    ln -s ../../drivers/not-pca954x \
        "$I2C_SYSFS_ROOT/devices/$NCA9545_DEVICE/driver" || return
    local channel
    for channel in 0 1 2 3; do
        make_channel "$NCA9545_DEVICE" "$channel" "$(( 110 + channel ))" || return
    done

    local source_rc=0
    source "$BINDER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$BINDER_SCRIPT" "$source_rc" || return
    require_functions host_is_running mux_is_ready write_driver_bind retry_sleep bind_mux || return

    local bind_writes=0
    host_is_running() { return 0; }
    write_driver_bind() { (( bind_writes += 1 )); return 0; }
    retry_sleep() { return 0; }

    bind_mux
    local bind_rc=$?
    (( bind_rc != 0 )) || { fail "four channels under the wrong driver must not be ready"; return; }
    assert_eq "$BIND_MAX_ATTEMPTS" "$bind_writes" \
        "bind attempts while driver remained incorrect"
}

test_bind_channel_target_must_be_directory() {
    new_fixture || return
    trap cleanup_fixture EXIT
    make_mux_ready 120 || return
    rm -f -- \
        "$I2C_SYSFS_ROOT/devices/$NCA9545_DEVICE/channel-3" || return
    rm -f -- "$I2C_SYSFS_ROOT/devices/i2c-123" || return
    : >"$I2C_SYSFS_ROOT/devices/i2c-123" || return
    ln -s ../i2c-123 \
        "$I2C_SYSFS_ROOT/devices/$NCA9545_DEVICE/channel-3" || return

    local source_rc=0
    source "$BINDER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$BINDER_SCRIPT" "$source_rc" || return

    mux_is_ready
    local ready_rc=$?
    (( ready_rc != 0 )) ||
        fail "mux_is_ready accepted a channel symlink to an ordinary file"
}

test_bind_channel_target_must_stay_in_i2c_devices_tree() {
    new_fixture || return
    trap cleanup_fixture EXIT
    make_mux_ready 130 || return
    rm -f -- \
        "$I2C_SYSFS_ROOT/devices/$NCA9545_DEVICE/channel-3" || return
    mkdir -p "$fixture/outside/i2c-133" || return
    ln -s "$fixture/outside/i2c-133" \
        "$I2C_SYSFS_ROOT/devices/$NCA9545_DEVICE/channel-3" || return

    local source_rc=0
    source "$BINDER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$BINDER_SCRIPT" "$source_rc" || return

    mux_is_ready
    local ready_rc=$?
    (( ready_rc != 0 )) ||
        fail "mux_is_ready accepted an out-of-tree directory with an i2c-N basename"
}

test_bind_channels_must_resolve_to_unique_buses() {
    new_fixture || return
    trap cleanup_fixture EXIT
    make_mux_ready 140 || return
    rm -f -- \
        "$I2C_SYSFS_ROOT/devices/$NCA9545_DEVICE/channel-3" || return
    ln -s ../i2c-142 \
        "$I2C_SYSFS_ROOT/devices/$NCA9545_DEVICE/channel-3" || return

    local source_rc=0
    source "$BINDER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$BINDER_SCRIPT" "$source_rc" || return

    mux_is_ready
    local ready_rc=$?
    (( ready_rc != 0 )) ||
        fail "mux_is_ready accepted two channels resolving to the same bus"
}

test_bind_host_not_running_fails_without_write() {
    new_fixture || return
    trap cleanup_fixture EXIT

    local source_rc=0
    source "$BINDER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$BINDER_SCRIPT" "$source_rc" || return
    require_functions host_is_running mux_is_ready write_driver_bind retry_sleep bind_mux || return

    local bind_writes=0
    local sleeps=0
    host_is_running() { return 1; }
    write_driver_bind() { (( bind_writes += 1 )); return 0; }
    retry_sleep() { (( sleeps += 1 )); return 0; }

    bind_mux
    local bind_rc=$?
    (( bind_rc != 0 )) || { fail "bind_mux must fail immediately while Host is not Running"; return; }
    assert_eq 0 "$bind_writes" "bind writes while Host is not Running" || return
    assert_eq 0 "$sleeps" "retry sleeps while Host is not Running"
}

test_bind_stops_when_host_leaves_running_state() {
    new_fixture || return
    trap cleanup_fixture EXIT

    local source_rc=0
    source "$BINDER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$BINDER_SCRIPT" "$source_rc" || return
    require_functions host_is_running mux_is_ready write_driver_bind retry_sleep bind_mux || return

    local bind_writes=0
    host_is_running() { (( bind_writes == 0 )); }
    write_driver_bind() { (( bind_writes += 1 )); return 1; }
    retry_sleep() { return 0; }

    bind_mux
    local bind_rc=$?
    (( bind_rc != 0 )) || { fail "bind_mux must fail after Host leaves Running"; return; }
    assert_eq 1 "$bind_writes" "bind writes after Host state changed"
}

test_bind_ready_after_write_rechecks_host() {
    new_fixture || return
    trap cleanup_fixture EXIT

    local source_rc=0
    source "$BINDER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$BINDER_SCRIPT" "$source_rc" || return

    local bind_writes=0
    host_is_running() { (( bind_writes == 0 )); }
    write_driver_bind() {
        (( bind_writes += 1 ))
        make_mux_ready 150 || return 1
        return 0
    }
    retry_sleep() { return 0; }

    bind_mux
    local bind_rc=$?
    (( bind_rc != 0 )) || {
        fail "bind_mux succeeded after its write made the mux ready while Host left Running"
        return
    }
    assert_eq 1 "$bind_writes" "bind writes before final Host-state rejection"
}

test_bind_sleep_concurrent_ready_avoids_another_write() {
    new_fixture || return
    trap cleanup_fixture EXIT

    local source_rc=0
    source "$BINDER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$BINDER_SCRIPT" "$source_rc" || return

    local bind_writes=0
    local sleeps=0
    host_is_running() { return 0; }
    write_driver_bind() { (( bind_writes += 1 )); return 1; }
    retry_sleep() {
        (( sleeps += 1 ))
        make_mux_ready 160 || return 1
        return 0
    }

    bind_mux
    local bind_rc=$?
    (( bind_rc == 0 )) ||
        { fail "bind_mux rejected readiness completed concurrently during sleep"; return; }
    assert_eq 1 "$bind_writes" "bind writes after concurrent readiness" || return
    assert_eq 1 "$sleeps" "sleeps before concurrent readiness"
}

exercise_reconcile_case() {
    local host_running=$1
    local collector_active=$2
    local expected_actions=$3

    new_fixture || return
    trap cleanup_fixture EXIT

    local source_rc=0
    source "$RECONCILER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$RECONCILER_SCRIPT" "$source_rc" || return
    require_functions host_is_running collector_is_active start_collector stop_collector reconcile_once || return

    local actions=
    host_is_running() { (( host_running != 0 )); }
    collector_is_active() { (( collector_active != 0 )); }
    start_collector() { actions="${actions:+$actions,}start"; return 0; }
    stop_collector() { actions="${actions:+$actions,}stop"; return 0; }

    reconcile_once >/dev/null 2>&1
    local reconcile_rc=$?
    (( reconcile_rc == 0 )) || {
        fail "reconcile_once returned status $reconcile_rc"
        return
    }
    assert_eq "$expected_actions" "$actions" \
        "reconcile actions for host_running=$host_running collector_active=$collector_active"
}

test_reconcile_running_inactive_starts() {
    exercise_reconcile_case 1 0 start
}

test_reconcile_off_active_stops() {
    exercise_reconcile_case 0 1 stop
}

test_reconcile_running_active_is_idempotent() {
    exercise_reconcile_case 1 1 ''
}

test_reconcile_off_inactive_is_idempotent() {
    exercise_reconcile_case 0 0 ''
}

test_reconcile_production_host_running_uses_exact_busctl_call() {
    new_fixture || return
    trap cleanup_fixture EXIT
    export FAKE_BUSCTL_RC=0
    export FAKE_BUSCTL_OUTPUT='s "xyz.openbmc_project.State.Host.HostState.Running"'

    local source_rc=0
    source "$RECONCILER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$RECONCILER_SCRIPT" "$source_rc" || return

    host_is_running
    local host_rc=$?
    (( host_rc == 0 )) || { fail "production host_is_running rejected exact Running"; return; }

    local expected_call='--timeout=2 get-property xyz.openbmc_project.State.Host /xyz/openbmc_project/state/host0 xyz.openbmc_project.State.Host CurrentHostState'
    local actual_call
    actual_call=$(<"$FAKE_BUSCTL_LOG")
    assert_eq "$expected_call" "$actual_call" "reconciler production busctl invocation"
}

test_reconcile_production_host_running_rejects_off() {
    new_fixture || return
    trap cleanup_fixture EXIT
    export FAKE_BUSCTL_RC=0
    export FAKE_BUSCTL_OUTPUT='s "xyz.openbmc_project.State.Host.HostState.Off"'

    local source_rc=0
    source "$RECONCILER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$RECONCILER_SCRIPT" "$source_rc" || return

    host_is_running
    local host_rc=$?
    (( host_rc != 0 )) || fail "production host_is_running accepted exact Off"
}

test_reconcile_production_host_running_rejects_busctl_failure() {
    new_fixture || return
    trap cleanup_fixture EXIT
    export FAKE_BUSCTL_RC=1
    export FAKE_BUSCTL_OUTPUT='s "xyz.openbmc_project.State.Host.HostState.Running"'

    local source_rc=0
    source "$RECONCILER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$RECONCILER_SCRIPT" "$source_rc" || return

    host_is_running
    local host_rc=$?
    (( host_rc != 0 )) || fail "production host_is_running accepted failed busctl output"
}

test_reconcile_host_leaving_running_during_start_stops_collector() {
    new_fixture || return
    trap cleanup_fixture EXIT

    local source_rc=0
    source "$RECONCILER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$RECONCILER_SCRIPT" "$source_rc" || return

    local host_checks=0
    local actions=
    host_is_running() {
        (( host_checks += 1 ))
        (( host_checks == 1 ))
    }
    collector_is_active() { return 1; }
    start_collector() { actions="${actions:+$actions,}start"; return 0; }
    stop_collector() { actions="${actions:+$actions,}stop"; return 0; }

    reconcile_once >/dev/null 2>&1
    local reconcile_rc=$?
    (( reconcile_rc == 0 )) || {
        fail "reconcile_once returned status $reconcile_rc after compensating stop"
        return
    }
    assert_eq 'start,stop' "$actions" \
        "collector actions when Host leaves Running during start" || return
    assert_eq 2 "$host_checks" "Host checks around collector start"
}

test_reconcile_start_failure_is_propagated_without_recheck() {
    new_fixture || return
    trap cleanup_fixture EXIT

    local source_rc=0
    source "$RECONCILER_SCRIPT" || source_rc=$?
    set +e
    source_failed "$RECONCILER_SCRIPT" "$source_rc" || return

    local host_checks=0
    local actions=
    host_is_running() { (( host_checks += 1 )); return 0; }
    collector_is_active() { return 1; }
    start_collector() { actions="${actions:+$actions,}start"; return 23; }
    stop_collector() { actions="${actions:+$actions,}stop"; return 0; }

    reconcile_once >/dev/null 2>&1
    local reconcile_rc=$?
    assert_eq 23 "$reconcile_rc" "failed start status from reconcile_once" || return
    assert_eq start "$actions" "actions after failed collector start" || return
    assert_eq 1 "$host_checks" "Host checks after failed collector start"
}

run_test() {
    local name=$1
    local test_function=$2

    if [[ -n $TEST_FILTER && $name != *"$TEST_FILTER"* ]]; then
        return 0
    fi

    (( tests_run += 1 ))
    if ( "$test_function" ); then
        (( tests_passed += 1 ))
        printf 'ok %d - %s\n' "$tests_run" "$name"
    else
        (( tests_failed += 1 ))
        printf 'not ok %d - %s\n' "$tests_run" "$name"
    fi
}

run_test 'discover: unique non-contiguous child buses and numeric 0xB6' test_discover_finds_non_contiguous_child_buses
run_test 'discover: zero matching child buses fails' test_discover_rejects_zero_matches
run_test 'discover: two matching child buses is rejected' test_discover_rejects_two_matches
run_test 'discover: dangling and invalid channel targets are ignored' test_discover_ignores_dangling_and_invalid_targets
run_test 'discover/cache: ensure_device_bus maps CHIP4 to 7-0073 child bus' test_discover_cache_maps_chip_to_switch
run_test 'discover/cache: stale cached bus is cleared and rediscovered once' test_discover_cache_recovers_after_channel_moves
run_test 'discover/cache: board-type mismatch clears only this cache and rediscovers once' test_discover_cache_recovers_after_board_type_mismatch
run_test 'discover/collect: failed normal max write falls back to failed state' test_collect_max_write_failure_publishes_failed_state
run_test 'discover/collect: incomplete scan publishes failed state and returns failure' test_collect_incomplete_scan_publishes_failed_state_and_fails
run_test 'discover/collect: failed-state write failure is reported' test_collect_failed_state_write_failure_is_reported
run_test 'bind: already-ready mux causes zero bind writes' test_bind_ready_mux_does_not_write
run_test 'bind: already-ready mux still requires Host Running' test_bind_ready_mux_requires_host_running
run_test 'bind: production host check uses exact timed busctl call and Running value' test_bind_production_host_running_uses_exact_busctl_call
run_test 'bind: production host check rejects Off' test_bind_production_host_running_rejects_off
run_test 'bind: production host check rejects busctl failure' test_bind_production_host_running_rejects_busctl_failure
run_test 'bind: production bind write targets exact sysfs path and device' test_bind_production_write_targets_exact_sysfs_file
run_test 'bind: negative retry delay is rejected before writes' test_bind_rejects_negative_retry_delay
run_test 'bind: nonnumeric retry delay is rejected before writes' test_bind_rejects_nonnumeric_retry_delay
run_test 'bind: service timeout covers default retry budget' test_bind_service_timeout_covers_default_retry_budget
run_test 'bind: third attempt can create driver and four channels' test_bind_succeeds_when_third_attempt_becomes_ready
run_test 'bind: exhausted attempts fail' test_bind_exhaustion_fails
run_test 'bind: successful write with incomplete channels still fails' test_bind_incomplete_channels_never_count_as_ready
run_test 'bind: four channels without driver still fails' test_bind_four_channels_without_driver_never_count_as_ready
run_test 'bind: wrong driver with four channels still fails' test_bind_wrong_driver_never_counts_as_ready
run_test 'bind: channel target must be a directory' test_bind_channel_target_must_be_directory
run_test 'bind: channel target must stay in the I2C devices tree' test_bind_channel_target_must_stay_in_i2c_devices_tree
run_test 'bind: four channels must resolve to four unique buses' test_bind_channels_must_resolve_to_unique_buses
run_test 'bind: Host not Running fails immediately without a write' test_bind_host_not_running_fails_without_write
run_test 'bind: Host leaving Running stops later attempts' test_bind_stops_when_host_leaves_running_state
run_test 'bind: readiness after a write requires Host still Running' test_bind_ready_after_write_rechecks_host
run_test 'bind: readiness completed during sleep prevents another write' test_bind_sleep_concurrent_ready_avoids_another_write
run_test 'reconcile: Running plus inactive starts collector' test_reconcile_running_inactive_starts
run_test 'reconcile: Off plus active stops collector' test_reconcile_off_active_stops
run_test 'reconcile: Running plus active does nothing' test_reconcile_running_active_is_idempotent
run_test 'reconcile: Off plus inactive does nothing' test_reconcile_off_inactive_is_idempotent
run_test 'reconcile: production host check uses exact timed busctl call and Running value' test_reconcile_production_host_running_uses_exact_busctl_call
run_test 'reconcile: production host check rejects Off' test_reconcile_production_host_running_rejects_off
run_test 'reconcile: production host check rejects busctl failure' test_reconcile_production_host_running_rejects_busctl_failure
run_test 'reconcile: Host leaving Running during start stops collector' test_reconcile_host_leaving_running_during_start_stops_collector
run_test 'reconcile: failed collector start is propagated without Host recheck' test_reconcile_start_failure_is_propagated_without_recheck

if (( tests_run == 0 )); then
    printf 'FAIL: TEST_FILTER=%q selected no tests\n' "$TEST_FILTER" >&2
    exit 2
fi

printf '%d tests, %d passed, %d failed\n' "$tests_run" "$tests_passed" "$tests_failed"
(( tests_failed == 0 ))
