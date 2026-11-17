##############################################################################
# dc_syn.tcl — 階段 2：Design Compiler 邏輯合成
# 執行：cd runs/synthesis && dc_shell -f ../../scripts/dc_syn.tcl
# 結構：設定 library → 讀 RTL → 約束 → compile → 改名 → 報告 → 寫出 → 判定
# USE_PAD=1：讀 RTL＋pad 階段產生的 wrapper，top = ${DESIGN}_chip；PAD 實例 dont_touch，
#   link IO library，約束改用 constraints_chip.sdc（PAD 延遲在路徑內、1 pF 板級負載）
##############################################################################
source [file join [file dirname [info script]] flow_config.tcl]
file mkdir reports

# ---------- 依設計修改 ----------
# DC 一次只能用一個 corner 修 hold（SAED32 才有選擇；CBDK 只有 slow）：
#   slow：非同步 reset 的 removal 在 SS 最嚴，用 SS 修可避免佈局前 STA 的 slow／typical removal 違規；
#         代價是 fast corner 的一般 hold 不在 DC 檢查範圍，要看佈局前 STA 的 fast 結果
#   fast：一般 D 端 hold 在 FF 最嚴；設計沒有（或很少）非同步 reset 時可以用這個
#   例：約 600 個帶非同步 reset 的 DFF、reset 直接從 input port 進來的設計，用 fast 時
#       slow corner removal -0.20 ns；改 slow 後三個 corner 都通過，面積 +14%（多為延遲 buffer）
set DC_HOLD_CORNER slow
# max_capacitance 只在 DC 記憶體內收緊成 library 值的幾倍（PDK 檔案不動）。PT 檢查時 pin 電容取
# rise/fall 範圍的上限、DC 用標稱值，不收緊的話邊緣的 net 在 DC 過、PT 不過（例：DC 15.99 fF、
# PT 17.62 fF，上限 16 fF）。1.0 = 不收緊；越小餘裕越多、面積越大。
# 佈局前 STA 仍有 max_capacitance 違規時調低：用 PT 報告的「實際值／上限」估，例如 PT 35 fF、上限 32 fF、
# DC 當時算 26 fF → DC 要收到 32×26/35 ≈ 24 fF 以下，約 0.75 → 設 0.70。乘法器等 XNOR／XOR 很多的
# datapath 差距最大（例：XNOR2X2 輸入的 rise/fall 電容上限比標稱值高約 45%，0.85 不夠）
set MAXCAP_DERATE 0.85
# --------------------------------

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
    # SAED32：以 FF library 為 target，同時 link SS。
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
    # max_capacitance 收緊（MAXCAP_DERATE，見檔頭），讓其他 corner 與繞線後仍有電容餘裕
    foreach_in_collection pin [get_lib_pins $LIB_SLOW/*/*] {
        set cap [get_attribute -quiet $pin max_capacitance]
        if {$cap ne "" && $cap > 0} {set_attribute $pin max_capacitance [expr {$MAXCAP_DERATE*$cap}]}
    }
} else {
    # setup（max）用 FF 分析；hold／removal（min）用 DC_HOLD_CORNER 的 library（見檔頭）
    set HOLD_LIB [expr {$DC_HOLD_CORNER eq "slow" ? $LIB_SLOW : $LIB_FAST}]
    set_operating_conditions -max [string map {saed32rvt_ ""} $LIB_FAST] -max_library $LIB_FAST \
                             -min [string map {saed32rvt_ ""} $HOLD_LIB] -min_library $HOLD_LIB
    # wire-load 一律取 SS library 的 ForQA，mode top（整個設計用同一個模型）
    set_wire_load_model -name $WLM -library $LIB_SLOW
    set_wire_load_mode top
    source [file join [file dirname [info script]] $SDC_FILE]
    # 跨 corner 電容與驅動餘裕：max_capacitance 收緊（MAXCAP_DERATE）、排除最小的 X0/X1 cell、
    # 限制加權扇出（flow_config 的 MAX_FANOUT）
    foreach lib [list $LIB_FAST $LIB_SLOW] {
        foreach_in_collection pin [get_lib_pins $lib/*/*] {
            set cap [get_attribute -quiet $pin max_capacitance]
            if {$cap ne "" && $cap > 0} {set_attribute $pin max_capacitance [expr {$MAXCAP_DERATE*$cap}]}
        }
    }
    set_dont_use [get_lib_cells [list $LIB_FAST/*X0_RVT $LIB_FAST/*X1_RVT]]
    if {[info exists MAX_FANOUT] && $MAX_FANOUT ne ""} {set_max_fanout $MAX_FANOUT [current_design]}
}
# PAD 模式：晶片 port ↔ PAD PADIO 的 net 是打線，不是晶片內走線。PADIO 的 pin cap 約 2.4 pF，
# 套 wire-load 的電阻會算出幾十 ns 的假延遲（例：某設計 reset 路徑 -19 ns），所以電阻設 0。
# 只在佈局前（DC／佈局前 PT）需要；繞線後用 StarRC 的實際 RC。
# compile 會移除沒有 dont_touch 的 net 上的電阻設定（OPT-801），所以先 dont_touch。
# clock 經過 clock PAD 後才進核心：佈局前 clock net 要是 ideal（DC 預設已是，PT 要明講，
# 否則 PT 寫出的 SDF 會把 wire-load 估的高扇出 clock net 延遲寫進去，例：實測 2.3 us 的假延遲）
if {$USE_PAD} {
    set bond_nets [get_nets -of_objects [get_ports *]]
    set_dont_touch $bond_nets
    set_resistance 0 $bond_nets
}
# 非同步 reset 的 recovery／removal 檢查：DC 預設不分析（PT 預設會），不打開的話
# DC 看不到 reset 路徑，不會幫高扇出的 reset 建 buffer tree，也不修 removal；
# 到佈局前 STA 才失敗（例：約 600 個 DFF 的 reset 只有一顆 INVX8 推，
# fast corner recovery -3.26 ns，slow removal -0.20 ns）
set_app_var enable_recovery_removal_arcs true
set_fix_hold [get_clocks $CLK_PORT]
# 同一 net 接多個 output port 或常數時插 buffer，避免 netlist 出現 assign
set_fix_multiple_port_nets -all -buffer_constants [get_designs *]
redirect reports/check_design_pre.rpt {check_design}
redirect reports/check_timing_pre.rpt {check_timing}

# ---- 4. 合成 ----
# 預設 compile（實測：時序達標、Formality 很快通過）。
# compile_ultra 面積/時序通常更好，但會重組 datapath（乘法器等），
# Formality verify 可能跑很久（例：實測 >20 分鐘未結束）；
# 用 compile_ultra 時保留 SVF，必要時加 -no_autoungroup 或改回 compile。
compile
# compile 後若仍有電氣規則違規（max_capacitance／max_transition／max_fanout），補一輪只修 DRC 的
# incremental compile；不動時序，沒有違規就略過（例：某設計 PAD 版乘法器內 3 條 net 超過 max_cap）
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
