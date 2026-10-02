#!/usr/bin/env bash
# Regression + performance sweep, in parallel.  Exit code 0 only if all pass.
#   functional : N = 2, 4, 8  x  VOQ and single FIFO  x  3 seeds
#   sweep      : 4x4 throughput vs queue depth, VOQ vs FIFO
cd "$(dirname "$0")/.."
LOG="$HOME/.xb_sim/regress"; rm -rf "$LOG"; mkdir -p "$LOG"

jobs=()
for n in 2 4 8; do for voq in 1 0; do for seed in 1 2 3; do jobs+=("$n $voq $seed 4"); done; done; done
for d in 2 8 16 32 64 128; do jobs+=("4 1 7 $d" "4 0 7 $d"); done

i=0
for j in "${jobs[@]}"; do
    ( bash scripts/sim.sh $j > "$LOG/$i.log" 2>&1; echo $? > "$LOG/$i.rc" ) &
    i=$((i + 1))
    (( i % 12 == 0 )) && wait
done
wait

fail=0; i=0
echo "functional:"
for j in "${jobs[@]}"; do
    set -- $j
    if [ "$(cat "$LOG/$i.rc")" = 0 ] && grep -q '^PASS' "$LOG/$i.log"; then
        [ "$4" = 4 ] && printf "  N=%s %-5s seed %s  %s\n" "$1" "$([ $2 = 1 ] && echo VOQ || echo FIFO)" "$3" \
                        "$(grep '^PASS' "$LOG/$i.log" | cut -c7-)"
    else
        printf "  N=%s VOQ=%s seed %s depth %s  FAIL\n" "$1" "$2" "$3" "$4"
        grep -E 'ERROR|FAIL' "$LOG/$i.log" | head -3
        fail=1
    fi
    i=$((i + 1))
done
echo "throughput, 4x4, uniform saturated 1-beat packets:"
i=0
for j in "${jobs[@]}"; do
    set -- $j
    if [ "$3" = 7 ]; then
        printf "  %-5s depth %4s : %s\n" "$([ $2 = 1 ] && echo VOQ || echo FIFO)" "$4" \
            "$(grep -oE '[0-9.]+ % of' "$LOG/$i.log" | head -1 | cut -d' ' -f1-2)"
    fi
    i=$((i + 1))
done
[ $fail = 0 ] && echo "REGRESSION PASSED (${#jobs[@]} runs)" || { echo "REGRESSION FAILED"; exit 1; }
