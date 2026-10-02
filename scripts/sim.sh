#!/usr/bin/env bash
# Build and run tb_xb with Verilator.   scripts/sim.sh [N] [VOQ] [SEED] [DEPTH]
set -e
source "$(dirname "$0")/env.sh"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
N=${1:-4}; VOQ=${2:-1}; SEED=${3:-1}; DEPTH=${4:-4}
WORK="$HOME/.xb_sim/n${N}_voq${VOQ}_s${SEED}_d${DEPTH}"
mkdir -p "$WORK"; cp "$SRC"/rtl/*.sv "$SRC"/tb/*.sv "$WORK/"; cd "$WORK"
verilator --binary --timing --assert -Wno-fatal -Wno-lint -Wno-style -O2 \
    --top-module tb_xb -Mdir obj -DN=$N -DVOQ=$VOQ -DSEED=$SEED -DDEPTH=$DEPTH \
    xb_fifo.sv xb_switch.sv $(ls xb_props.sv 2>/dev/null) tb_xb.sv > build.log 2>&1 || { cat build.log; exit 1; }
./obj/Vtb_xb
