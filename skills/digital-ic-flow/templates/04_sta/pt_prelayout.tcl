##############################################################################
# pt_prelayout.tcl — 階段 4：PrimeTime 佈局前 STA（每個 corner 跑一次）
# 執行：FLOW_CORNER=slow pt_shell -f pt_prelayout.tcl
# 會另外寫出該 corner 的 SDF，給階段 5 的閘級模擬使用
##############################################################################
source [file join [file dirname [info script]] flow_config.tcl]

set corner $::env(FLOW_CORNER)
if {![dict exists $CORNERS $corner]} {error "unknown corner $corner"}
set lib [dict get $CORNERS $corner lib]
set R reports_$corner          ;# 每個 corner 各自的報告目錄
file mkdir $R

set_app_var search_path [concat [list $LIB_DIR] $search_path]
# 一定要同時載入 slow library：下面的 wire-load 模型取自 slow 庫。
# 少了它 set_wire_load_model 會報 SEL-005，PT 退回 fast 庫預設的
# worst_case_tree 模型，fast corner 會出現假的大負 slack（實測 -6.47 ns）。
set link [list * $lib.db]            ;# 要分析的 corner 放第一個，cell 會先連到它
if {$lib ne $LIB_SLOW} {lappend link $LIB_SLOW.db}
# USE_PAD=1：同 corner 的 IO library 也要 link，top 是晶片 wrapper（PAD 延遲算進路徑）
if {$USE_PAD} {
    set_app_var search_path [concat [list $IO_DB_DIR] $search_path]
    lappend link [dict get $CORNERS $corner io].db
}
set_app_var link_path $link

read_verilog $NETLIST
current_design $TOP
if {![link_design $TOP]} {error "link failed"}

# 佈局前沒有實際繞線：沿用合成用的 wire-load 估計
set_wire_load_model -name $WLM -library $LIB_SLOW
set_wire_load_mode top
source [file join [file dirname [info script]] \
    [expr {$USE_PAD ? "constraints_chip.sdc" : ($PROCESS eq "cbdk" ? "constraints.sdc" : "constraints_saed32.sdc")}]]
# PAD 模式：晶片 port ↔ PAD PADIO 的 net 是打線，不是晶片內走線。PADIO 的 pin cap 約 2.4 pF，
# 套 wire-load 的電阻會算出幾十 ns 的假延遲（例：某設計 reset 路徑 -19 ns），所以電阻設 0。
# 只在佈局前（DC／佈局前 PT）需要；繞線後用 StarRC 的實際 RC。
# clock 經過 clock PAD 後才進核心：佈局前 clock net 設成 ideal。沒有這行，PT 寫出的 SDF
# 會把 wire-load 估的高扇出 clock net 延遲寫進去（例：實測 2.3 us，fast 閘級模擬失敗）
if {$USE_PAD} {
    set_resistance 0 [get_nets -of_objects [get_ports *]]
    set_ideal_network [get_pins pad_${CLK_PORT}/DOUT]
}
update_timing

redirect $R/units.rpt        {report_units}
redirect $R/check_timing.rpt {check_timing -verbose}
redirect $R/setup.rpt   {report_timing -delay_type max -max_paths 20 -slack_lesser_than 1e9 -significant_digits 5}
redirect $R/hold.rpt    {report_timing -delay_type min -max_paths 20 -slack_lesser_than 1e9 -significant_digits 5}
redirect $R/constraints.rpt {report_constraint -all_violators -significant_digits 5}
# 列出沒被檢查到的項目（例如非週期 reset 的 pulse width），回報時要說明
redirect $R/coverage.rpt {report_analysis_coverage}
# PAD 模式：列出 PAD 本身的延遲（回報時說明 PAD 佔了多少 timing budget）
if {$USE_PAD} {
    redirect $R/pad_delay_in.rpt  {report_timing -through [get_pins pad_*/DOUT] -max_paths 1}
    redirect $R/pad_delay_out.rpt {report_timing -through [get_pins pad_*/DIN]  -max_paths 1}
}
write_sdf -version 3.0 ${DESIGN}_${corner}.sdf

set setup [get_attribute [get_timing_paths -delay_type max -max_paths 1] slack]
set hold  [get_attribute [get_timing_paths -delay_type min -max_paths 1] slack]
puts "STA_SLACK $corner setup=$setup hold=$hold"
set fp [open $R/constraints.rpt r]; set rc [read $fp]; close $fp
if {$setup < 0 || $hold < 0 || [string match *VIOLATED* $rc]} {
    puts "STA_FAIL $corner"
    exit 1
}
puts "STA_PASS $corner"
exit
