#!/bin/bash
set -eu
ulimit -c 0
tests=$(cd "$(dirname "$0")" && pwd)
source_file=${1:-$tests/../../../recipes-sophgo/sophgo-fan-control/project/src/fan_control.cpp}
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
sed -n '/^void cycle_sensor_monitor(/,/^}/p' "$source_file" > "$build/fan-monitor.inc"
g++ -std=c++17 -Wall -Wextra -Wno-unused-but-set-variable \
    -I "$build" "$tests/fan.test.cpp" -o "$build/fan-test"
"$build/fan-test"
