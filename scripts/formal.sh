#!/usr/bin/env bash
# Run the SymbiYosys tasks in a copy on the native Linux filesystem.
source "$(dirname "$0")/env.sh"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$HOME/.xb_formal"; rm -rf "$WORK"; mkdir -p "$WORK"
cp -r "$SRC/rtl" "$SRC/tb" "$SRC/formal" "$WORK/"
cd "$WORK/formal"
sby -f xb_switch.sby "$@" 2>&1 | grep -E "DONE|summary: (engine|successful|reached|failed|counter)|Assert failed|ERROR" | grep -v "^$" || true
mkdir -p "$SRC/formal/results"
for d in xb_switch_*; do
    [ -f "$d/status" ] && cp "$d/status" "$SRC/formal/results/$d.status"
done
