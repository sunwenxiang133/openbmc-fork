#!/bin/bash
set -eu
ulimit -c 0
tests=$(cd "$(dirname "$0")" && pwd)
source_file=${1:-$tests/../files/yu08.c}
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
sed -n '/^static int yu08_read(/,/^}/p' "$source_file" > "$build/yu08-read.inc"
gcc -std=gnu11 -Wall -Wextra -Werror -Wno-unused-function \
    -I "$build" "$tests/read.test.c" -o "$build/read-test"
"$build/read-test"
