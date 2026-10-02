#!/usr/bin/env bash
# Verilator -Wall lint, VOQ and FIFO builds, 4 and 8 ports.
set -e
source "$(dirname "$0")/env.sh"
cd "$(dirname "$0")/.."
for cfg in "4 1" "4 0" "8 1" "2 1"; do
    set -- $cfg
    echo "== lint N=$1 VOQ=$2"
    verilator --lint-only -Wall --top-module xb_switch -GN=$1 -GVOQ=$2 rtl/xb_fifo.sv rtl/xb_switch.sv
done
echo "lint clean"
