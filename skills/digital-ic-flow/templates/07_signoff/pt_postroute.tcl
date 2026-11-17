##############################################################################
# pt_postroute.tcl — 階段 9a：繞線後 STA（routed netlist + StarRC SPEF）
# 執行：FLOW_CORNER=slow pt_shell -f pt_postroute.tcl
# 與佈局前的差別：propagated clock（真的 clock tree）、實際 RC、不用 wire-load
##############################################################################
source [file join [file dirname [info script]] flow_config.tcl]

set corner $::env(FLOW_CORNER)
set lib [dict get $CORNERS $corner lib]
set R reports_$corner
file mkdir $R

set_app_var search_path [concat [list $LIB_DIR] $search_path]
# USE_PAD=1：同一個 corner 的 IO library 也要 link，top 是晶片 wrapper
set link [list * $lib.db]
if {$USE_PAD} {
    set_app_var search_path [concat [list $IO_DB_DIR] $search_path]
    lappend link [dict get $CORNERS $corner io].db
}
set_app_var link_path $link
read_verilog $ROUTED_V
current_design $TOP
if {![link_design $TOP]} {error "link failed"}

source [file join [file dirname [info script]] [expr {$USE_PAD ? "constraints_chip.sdc" : "constraints_saed32.sdc"}]]
remove_ideal_network [get_ports $CLK_PORT]
set_propagated_clock [all_clocks]

read_parasitics $RUNS/starrc/$corner/$TOP.spef
update_timing

redirect $R/check_timing.rpt {check_timing -verbose}
# 確認每條有驅動與負載的 net 都有 RC，沒註入到的 net 會被當成理想線
redirect $R/parasitics.rpt   {report_annotated_parasitics -check}
redirect $R/setup.rpt   {report_timing -delay_type max -slack_lesser_than 1e9 -max_paths 10 -significant_digits 5}
redirect $R/hold.rpt    {report_timing -delay_type min -slack_lesser_than 1e9 -max_paths 10 -significant_digits 5}
redirect $R/constraints.rpt {report_constraint -all_violators -significant_digits 5}
redirect $R/coverage.rpt    {report_analysis_coverage}
# 給繞線後 Gate-level sim 用的 SDF
write_sdf -version 3.0 ${DESIGN}_postroute_${corner}.sdf

set setup [get_attribute [get_timing_paths -delay_type max -max_paths 1] slack]
set hold  [get_attribute [get_timing_paths -delay_type min -max_paths 1] slack]
puts "POSTROUTE_SLACK $corner setup=$setup hold=$hold"
set fp [open $R/constraints.rpt r]; set rc [read $fp]; close $fp
if {$setup < 0 || $hold < 0 || [string match *VIOLATED* $rc]} {
    puts "POSTROUTE_STA_FAIL $corner"
    exit 1
}
puts "POSTROUTE_STA_PASS $corner"
exit
