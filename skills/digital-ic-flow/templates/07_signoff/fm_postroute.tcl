##############################################################################
# fm_postroute.tcl — 階段 9b：Formality RTL vs 繞線後 netlist
# 來源：geofence scripts/apr/formal.tcl
# APR 會插 buffer、tie cell、改 clock tree；沿用 DC 的 SVF 讓 Formality 對上名字
##############################################################################
source [file join [file dirname [info script]] flow_config.tcl]
file mkdir reports

set synopsys_auto_setup true
if {![catch {exec which dc_shell} dc]} {set_app_var hdlin_dwroot [file dirname [file dirname $dc]]}
set_svf $SVF
read_db -technology_library [file join $LIB_DIR $LIB_SLOW.db]
if {$USE_PAD} {
    # 有 PAD：IO library 的 .db 也要讀；reference = RTL 核心 + pad 階段產生的 wrapper
    read_db -technology_library [file join $IO_DB_DIR [dict get $CORNERS slow io].db]
    read_verilog -r [concat $RTL_FILES [list $CHIP_V]]
} else {
    read_verilog -r $RTL_FILES
}
set_top r:/WORK/$TOP

# 用不含 PG / filler 的功能 netlist
read_verilog -i $ROUTED_V
set_top i:/WORK/$TOP

match
redirect reports/unmatched.rpt {report_unmatched_points}
if {[verify]} {
    redirect reports/passing.rpt {report_passing_points}
    puts "FM_POST_PASS"
    exit
} else {
    redirect reports/failing.rpt {report_failing_points}
    exit 1
}
