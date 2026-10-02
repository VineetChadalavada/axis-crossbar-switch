#!/usr/bin/env bash
# Sanity check for the proof: re-insert plausible bugs into a copy of the RTL
# and make sure the VOQ proof FAILS for every one.  A proof that cannot fail
# proves nothing.
source "$(dirname "$0")/env.sh"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
ok=1
mutate() {   # name, file, python replace (old, new)
    W="$HOME/.xb_mut_$1"; rm -rf "$W"; mkdir -p "$W"
    cp -r "$SRC/rtl" "$SRC/tb" "$SRC/formal" "$W/"
    python3 - "$W/$2" "$3" "$4" <<'PY'
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
if old not in s: sys.exit("mutation did not apply: " + old)
open(p, "w").write(s.replace(old, new, 1))
PY
    [ $? = 0 ] || { ok=0; return; }
    (cd "$W/formal" && sby -f xb_switch.sby prove_voq >/dev/null 2>&1)
    st=$(cut -d' ' -f1 "$W/formal/xb_switch_prove_voq/status" 2>/dev/null)
    if [ "$st" = "FAIL" ] || [ "$st" = "UNKNOWN" ]; then
        printf "  %-36s caught (%s)\n" "$1" "$st"
    else
        printf "  %-36s NOT CAUGHT (%s)\n" "$1" "$st"; ok=0
    fi
}
mutate input_in_two_matches  rtl/xb_switch.sv "req_col[j][i] = q_ne[i][j] && in_free[i] && out_free[j];" "req_col[j][i] = q_ne[i][j] && out_free[j];"
mutate release_before_tlast  rtl/xb_switch.sv "out_busy[j] <= src_valid[j] && !(m_fire[j] && m_tlast[j]);" "out_busy[j] <= src_valid[j] && !m_fire[j];"
mutate lock_only_on_transfer rtl/xb_switch.sv "out_busy[j] <= src_valid[j] && !(m_fire[j] && m_tlast[j]);" "out_busy[j] <= src_valid[j] && m_fire[j] && !m_tlast[j];"
mutate pointer_on_grant      rtl/xb_switch.sv "if (match_col[j] != '0)
                    gptr[j] <= next_ptr(onehot_idx(match_col[j]));" "if (grant[j] != '0)
                    gptr[j] <= next_ptr(onehot_idx(grant[j]));"
mutate pointer_never_moves   rtl/xb_switch.sv "gptr[j] <= next_ptr(onehot_idx(match_col[j]));" "gptr[j] <= gptr[j];"
mutate push_ignores_full     rtl/xb_switch.sv "assign s_tready[gi] = !full[dest_now[gi]];" "assign s_tready[gi] = 1'b1;"
[ $ok = 1 ] && echo "every mutant was caught" || { echo "SOME MUTANTS SURVIVED"; exit 1; }
