#!/bin/bash

readonly HOST_STATE_SERVICE="xyz.openbmc_project.State.Host"
readonly HOST_STATE_PATH="/xyz/openbmc_project/state/host0"
readonly HOST_STATE_INTERFACE="xyz.openbmc_project.State.Host"
readonly HOST_RUNNING_VALUE='s "xyz.openbmc_project.State.Host.HostState.Running"'
readonly COLLECTOR_SERVICE="sophgo-yu08-temp-scan.service"
readonly RECONCILE_BUSCTL_TIMEOUT=${RECONCILE_BUSCTL_TIMEOUT:-2}

host_is_running() {
    local state

    state=$(busctl "--timeout=$RECONCILE_BUSCTL_TIMEOUT" get-property \
        "$HOST_STATE_SERVICE" \
        "$HOST_STATE_PATH" \
        "$HOST_STATE_INTERFACE" \
        CurrentHostState 2>/dev/null) || return 1

    [[ $state == "$HOST_RUNNING_VALUE" ]]
}

collector_is_active() {
    systemctl is-active --quiet "$COLLECTOR_SERVICE"
}

start_collector() {
    systemctl start "$COLLECTOR_SERVICE"
}

stop_collector() {
    systemctl stop "$COLLECTOR_SERVICE"
}

reconcile_once() {
    local desired_running=0
    local observed_active=0

    if host_is_running; then
        desired_running=1
    fi
    if collector_is_active; then
        observed_active=1
    fi

    if (( desired_running != 0 && observed_active == 0 )); then
        start_collector || return $?
        if ! host_is_running; then
            stop_collector
        fi
    elif (( desired_running == 0 && observed_active != 0 )); then
        stop_collector
    fi
}

main() {
    while true; do
        reconcile_once || true
        sleep 1
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
