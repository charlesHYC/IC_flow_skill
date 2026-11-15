##############################################################################
# dc_syn.tcl — 階段 2：Design Compiler 邏輯合成
# 來源：geofence scripts/synthesize.tcl（CBDK）與 scripts/saed32/synthesize.tcl
# 執行：cd runs/synthesis && dc_shell -f ../../scripts/dc_syn.tcl
# 結構：設定 library → 讀 RTL → 約束 → compile → 改名 → 報告 → 寫出 → 判定
# USE_PAD=1：讀 RTL＋pad 階段產生的 wrapper，top = ${DESIGN}_chip；PAD 實例 dont_touch，
#   link IO library，約束改用 constraints_chip.sdc（PAD 延遲在路徑內、1 pF 板級負載）
##############################################################################
source [file join [file dirname [info script]] flow_config.tcl]
file mkdir reports

# ---- 1. Library ----
# target：合成時挑選的 cell；link：解析 netlist 用（* 代表記憶體中的 design）
set_app_var search_path       [concat [list $LIB_DIR] $search_path]
set_app_var synthetic_library [list dw_foundation.sldb]
set_app_var verilogout_no_tri true
# 讓 SVF 記錄 hierarchy 對應，Formality 比對 retime / ungroup 時需要
set_app_var hdlin_enable_hier_map true

if {$PROCESS eq "cbdk"} {
    # 比賽規定：slow library
    set TGT_LIB $LIB_SLOW
    set_app_var target_library [list $LIB_SLOW.db]
    set_app_var link_library   [list * $LIB_SLOW.db dw_foundation.sldb]
} else {
    # SAED32（geofence 實測可行的設定）：以 FF library 為 target，同時 link SS。
    # 原因：SAED32 的 wire-load 在 FF library 會讓高扇出 net 延遲暴增；只對 SS 合成時，
    # DC 看不到這個問題，PT fast corner 會出現 -6 ~ -15 ns 的假違規。
    set TGT_LIB $LIB_FAST
    set_app_var target_library [list $LIB_FAST.db]
    set_app_var link_library   [list * $LIB_SLOW.db $LIB_FAST.db dw_foundation.sldb]
}

if {$USE_PAD} {
    # 同 corner 的 IO library（PAD cell 只 link、不拿來合成）
    set_app_var search_path [concat [list $IO_DB_DIR] $search_path]
    foreach c [expr {$PROCESS eq "cbdk" ? {slow} : {slow fast}}] {
        set_app_var link_library [concat $link_library [list [dict get $CORNERS $c io].db]]
    }
}

# ---- 2. 讀入 RTL（SVF 要在讀檔前開始記錄） ----
set_svf $SVF
set src $RTL_FILES
if {$USE_PAD} {lappend src $CHIP_V}
analyze -format verilog $src           ;# SystemVerilog 用 -format sverilog
elaborate $TOP
current_design $TOP
set_verification_top
if {![link]} {error "link failed"}
uniquify

# PAD 不能被合成改動（DC 不會拿 IO cell 來 map，但會想 size／移除）
if {$USE_PAD} {set_dont_touch [get_cells pad_*]}

# ---- 3. 約束 ----
set SDC_FILE [expr {$USE_PAD ? "constraints_chip.sdc" : ($PROCESS eq "cbdk" ? "constraints.sdc" : "constraints_saed32.sdc")}]
if {$PROCESS eq "cbdk"} {
    source [file join [file dirname [info script]] $SDC_FILE]
    # 只在 DC 記憶體內把 library 的 max_capacitance 收緊到 85%（PDK 檔案不動），
    # 讓結果在其他 corner 與繞線後仍有電容餘裕（來源：REFRACT work/scripts/dc.tcl）
    foreach_in_collection pin [get_lib_pins $LIB_SLOW/*/*] {
        set cap [get_attribute -quiet $pin max_capacitance]
        if {$cap ne "" && $cap > 0} {set_attribute $pin max_capacitance [expr {0.85*$cap}]}
    }
} else {
    set_operating_conditions [string map {saed32rvt_ ""} $LIB_FAST] -library $LIB_FAST
    # wire-load 一律取 SS library 的 ForQA，mode top（整個設計用同一個模型）
    set_wire_load_model -name $WLM -library $LIB_SLOW
    set_wire_load_mode top
    source [file join [file dirname [info script]] $SDC_FILE]
    # 跨 corner 電容與驅動餘裕：排除最小的 X0/X1 cell、限制加權扇出
    set_dont_use [get_lib_cells [list $LIB_FAST/*X0_RVT $LIB_FAST/*X1_RVT]]
    # 加權扇出上限是設計相依的餘裕設定（geofence 用 1.0）；REFRACT 這類大型 datapath 達不到，預設不設
    if {[info exists MAX_FANOUT] && $MAX_FANOUT ne ""} {set_max_fanout $MAX_FANOUT [current_design]}
}
# PAD 模式：晶片 port ↔ PAD PADIO 的 net 是打線，不是晶片內走線。PADIO 的 pin cap 約 2.4 pF，
# 套 wire-load 的電阻會算出幾十 ns 的假延遲（geofence 實測 reset 路徑 -19 ns），所以電阻設 0。
# 只在佈局前（DC／佈局前 PT）需要；繞線後用 StarRC 的實際 RC。
# compile 會移除沒有 dont_touch 的 net 上的電阻設定（OPT-801），所以先 dont_touch。
# clock 經過 clock PAD 後才進核心：佈局前 clock net 要是 ideal（DC 預設已是，PT 要明講，
# 否則 PT 寫出的 SDF 會把 wire-load 估的高扇出 clock net 延遲寫進去，geofence 實測 2.3 us）
if {$USE_PAD} {
    set bond_nets [get_nets -of_objects [get_ports *]]
    set_dont_touch $bond_nets
    set_resistance 0 $bond_nets
}
set_fix_hold [get_clocks $CLK_PORT]
# 同一 net 接多個 output port 或常數時插 buffer，避免 netlist 出現 assign
set_fix_multiple_port_nets -all -buffer_constants [get_designs *]
redirect reports/check_design_pre.rpt {check_design}
redirect reports/check_timing_pre.rpt {check_timing}

# ---- 4. 合成 ----
# 預設 compile（geofence 實測：時序達標、Formality 很快通過）。
# compile_ultra 面積/時序通常更好，但會重組 datapath（乘法器等），
# Formality verify 可能跑很久（geofence 實測 >20 分鐘未結束）；
# 用 compile_ultra 時保留 SVF，必要時加 -no_autoungroup 或改回 compile。
compile
# compile 後若仍有電氣規則違規（max_capacitance／max_transition／max_fanout），補一輪只修 DRC 的
# incremental compile；不動時序，沒有違規就略過（REFRACT PAD 版：乘法器內 3 條 net 超過 max_cap）
redirect -variable drc_left {report_constraint -all_violators -max_capacitance -max_transition -max_fanout}
if {[string match *VIOLATED* $drc_left]} {
    puts "DC_DRC_FIX: design-rule violations left after compile, running incremental DRC fix"
    compile -incremental_mapping -only_design_rule
}
# compile -map_effort high -area_effort high      ;# 比賽壓面積
# compile_ultra                                   ;# 需要更好 QoR 時
# compile_ultra -retime -scan                     ;# retime＋test-ready（Lab 5）

# ---- 5. 命名清理（避免 UCN-4，與 Verilog 模擬器相容） ----
define_name_rules verilog -replacement_char x
change_names -rules verilog -hierarchy

# ---- 6. 報告 ----
redirect reports/check_design.rpt {check_design}
redirect reports/check_timing.rpt {check_timing}
redirect reports/area.rpt         {report_area -hierarchy}
# 核心面積（PAD 模式的 area.rpt 含 PAD；APR 用 area_core.rpt 估 core 大小）
current_design $DESIGN
redirect reports/area_core.rpt    {report_area}
current_design $TOP
redirect reports/setup.rpt        {report_timing -delay_type max -max_paths 10}
redirect reports/hold.rpt         {report_timing -delay_type min -max_paths 10}
redirect reports/constraints.rpt  {report_constraint -all_violators}
redirect reports/qor.rpt          {report_qor}
redirect reports/references.rpt   {report_reference -hierarchy}
redirect reports/units.rpt        {report_units}

# ---- 7. 寫出（比賽繳交：*_syn.v / *_syn.sdf / *_syn.ddc） ----
# PAD 模式檔名是 ${DESIGN}_chip_syn.*（$NETLIST 指向它）
write -format ddc     -hierarchy -output ${TOP}_syn.ddc
write -format verilog -hierarchy -output $NETLIST
write_sdc ${TOP}_syn.sdc
write_sdf -version [expr {$PROCESS eq "cbdk" ? "1.0" : "3.0"}] ${TOP}_syn.sdf
set_svf -off

# ---- 8. 判定：slack 與 constraint 報告都要乾淨 ----
set wns [get_attribute [get_timing_paths -delay_type max -max_paths 1] slack]
set fp [open reports/area_core.rpt r]; regexp {Total cell area:\s+([0-9.]+)} [read $fp] -> cell_area; close $fp
puts "DC_SLACK setup=$wns cell_area=$cell_area"
set fp [open reports/constraints.rpt r]; set rc [read $fp]; close $fp
# max_leakage_power 在預設 0 限制下必定 VIOLATED，不算時序問題
regsub -all {max_leakage_power.*} $rc {} rc_timing
if {$wns < 0 || [string match *VIOLATED* $rc_timing]} {
    puts "DC_FAIL: timing or DRC violations, see reports/constraints.rpt"
    exit 1
}
puts "DC_PASS"
exit
