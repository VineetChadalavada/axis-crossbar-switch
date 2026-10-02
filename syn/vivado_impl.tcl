# =============================================================================
# vivado_impl.tcl -- out-of-context synthesis + place & route of xb_switch
#
#   vivado -mode batch -source syn/vivado_impl.tcl \
#          -tclargs <N> <VOQ 0|1> <PERIOD_NS> [DEPTH] [PART]
#
# Writes syn/reports/vivado_n<N>_voq<VOQ>_d<DEPTH>/ : utilisation, timing,
# critical path, power, summary.txt
# =============================================================================
set n      [lindex $argv 0]
set voq    [lindex $argv 1]
set period [lindex $argv 2]
set depth  [expr {[llength $argv] > 3 ? [lindex $argv 3] : 4}]
set part   [expr {[llength $argv] > 4 ? [lindex $argv 4] : "xc7a100tcsg324-1"}]

set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
set out  "$here/reports/vivado_n${n}_voq${voq}_d${depth}"
file mkdir $out

read_verilog -sv [list $root/rtl/xb_fifo.sv $root/rtl/xb_switch.sv]
synth_design -top xb_switch -part $part -mode out_of_context \
    -generic N=$n -generic VOQ=$voq -generic DEPTH=$depth -flatten_hierarchy rebuilt
create_clock -name clk -period $period [get_ports clk]
opt_design
place_design
route_design

report_utilization    -file $out/utilization.rpt
report_timing_summary -file $out/timing.rpt -max_paths 5
report_timing         -file $out/critical_path.rpt -max_paths 1
report_power          -file $out/power.rpt

set wns  [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set fmax [expr {1000.0 / ($period - $wns)}]
set luts [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
set ffs  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
set lram [llength [get_cells -hier -filter {PRIMITIVE_GROUP == DMEM}]]
set line [format "%s N=%d %s depth %d  period %.2f ns  WNS %.3f ns  Fmax %.0f MHz  LUT %d  FF %d  LUTRAM %d" \
              $part $n [expr {$voq ? "VOQ " : "FIFO"}] $depth $period $wns $fmax $luts $ffs $lram]
set fh [open "$out/summary.txt" w]
puts $fh $line
close $fh
puts "SUMMARY: $line"
