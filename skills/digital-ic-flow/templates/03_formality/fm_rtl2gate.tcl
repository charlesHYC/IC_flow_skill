##############################################################################
# fm_rtl2gate.tcl — 階段 3：Formality 等價驗證（RTL vs 合成 netlist）
# reference (r:) = RTL；implementation (i:) = netlist；SVF 提供 DC 的轉換指引
# USE_PAD=1：兩邊的 top 都是 ${DESIGN}_chip（含 PAD）
##############################################################################
source [file join [file dirname [info script]] flow_config.tcl]
file mkdir reports

# 依 DC 的設定自動推導 RTL 解讀方式（DesignWare、同步/非同步行為等）
set synopsys_auto_setup true
# DesignWare 元件需要 DC 安裝路徑才能在 reference 端展開
if {![catch {exec which dc_shell} dc]} {set_app_var hdlin_dwroot [file dirname [file dirname $dc]]}

set_svf $SVF
read_db -technology_library [file join $LIB_DIR $LIB_SLOW.db]

if {$USE_PAD} {
    # PAD 模式：reference = RTL 核心＋wrapper；PAD cell 的功能來自 IO library .db
    read_db -technology_library [file join $IO_DB_DIR [dict get $CORNERS slow io].db]
    read_verilog -r [concat $RTL_FILES [list $CHIP_V]]
} else {
    read_verilog -r $RTL_FILES
}
set_top r:/WORK/$TOP

read_verilog -i $NETLIST          ;# 或 read_ddc -i $SYN_DIR/${TOP}_syn.ddc
set_top i:/WORK/$TOP

match
redirect reports/unmatched.rpt {report_unmatched_points}
redirect reports/guidance.rpt  {report_guidance -summary}

if {[verify]} {
    redirect reports/passing.rpt {report_passing_points}
    puts "FM_PASS"
    exit
} else {
    redirect reports/failing.rpt {report_failing_points}
    redirect reports/aborted.rpt {report_aborted_points}
    puts "FM_FAIL: see reports/failing.rpt"
    exit 1
}
