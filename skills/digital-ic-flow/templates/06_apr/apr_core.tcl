##############################################################################
# apr_core.tcl — 階段 6：ICC2 APR（USE_PAD=0 核心；USE_PAD=1 加 IO PAD ring 的全晶片）
#   floorplan → power plan → place_opt → clock_opt(CTS) → route_auto/route_opt
# 來源：REFRACT apr_50ff.tcl（已通過 DRC/LVS/PEX），階段切分與檢查沿用 geofence apr/*.tcl
# 執行：cd runs/apr && icc2_shell -f ../../scripts/apr_core.tcl
# 每個階段 save_block -as <name>，出錯可以從上一個 block 重跑。
# USE_PAD=1：floorplan／PG／terminal 改由 apr_pad_ring.tcl 的 proc 處理，place 之後流程相同。
##############################################################################
source [file join [file dirname [info script]] flow_config.tcl]

# ---------- 依設計修改 ----------
set DIE        {{0 0} {240 240}}   ;# um，依面積與 utilization 調整（geofence 核心約 5800 um^2）
set CORE_OFF   20                  ;# die 邊到 core 的距離，用來放 power ring
set MIN_LAYER  M2
set MAX_LAYER  M6                  ;# M7/M8 留給 power ring / mesh
set PIN_SIDE_IN  1                 ;# 1=左 2=上 3=右 4=下
set PIN_SIDE_OUT 3
set CORE_UTIL  0.15                ;# USE_PAD=1 時用來估 core 邊長（PAD 少時 die 由 PAD 數決定）
# --------------------------------
set SCRIPTS [file dirname [info script]]
set SDC [expr {$USE_PAD ? "constraints_chip.sdc" : "constraints_saed32.sdc"}]

# ===== 1. 建立 design library 並讀 netlist =====
set refs [list $APR_DIR/libs/stdcell_rvt.ndm]
if {$USE_PAD} {lappend refs $APR_DIR/libs/io.ndm}
# 重跑 APR 時先刪掉上一次的 design library，否則 create_lib 報 LIB-009（已存在）
file delete -force $NDM_LIB
create_lib $NDM_LIB -technology $TECH_TF -ref_libs $refs
# USE_PAD=1：合成 netlist 已經是晶片 top（wrapper＋PAD 實例＋核心）
read_verilog -top $TOP $NETLIST
link_block
# 確認單位，SDC 數值才會解讀正確
set_user_units -type capacitance -value 1fF
set_user_units -type resistance  -value 1MOhm
set_user_units -type time        -value 1ns
redirect units.rpt {report_units}

# ===== 2. Floorplan =====
set_attribute [get_site_defs unit] symmetry Y
set_attribute [get_site_defs unit] is_default true
if {$USE_PAD} {
    source $SCRIPTS/apr_pad_ring.tcl
    set fp [open $SYN_DIR/reports/area_core.rpt r]   ;# 只有核心，不含 PAD
    regexp {Total cell area:\s+([0-9.]+)} [read $fp] -> core_area; close $fp
    pad_floorplan $core_area $CORE_UTIL
} else {
    initialize_floorplan -control_type die -boundary $DIE -core_offset $CORE_OFF -site_def unit
}
# tech file 沒有 routing direction，要自己設
foreach n {1 3 5 7 9} {set_attribute [get_layers M$n] routing_direction horizontal}
foreach n {2 4 6 8}   {set_attribute [get_layers M$n] routing_direction vertical}
set_attribute [get_layers MRDL] routing_direction vertical
set_ignored_layers -min_routing_layer $MIN_LAYER -max_routing_layer $MAX_LAYER

# PG net 與所有 cell 的 VDD/VSS pin 連起來
if {$USE_PAD} {
    pad_pg_setup        ;# VDD/VSS/VDDIO/VSSIO、電源 PAD 打線 pin、port terminal
} else {
    foreach {net type} {VDD power VSS ground} {
        create_net -$type $net
        create_port -direction inout -port_type $type $net
        connect_pg_net -net $net [get_ports $net]
        connect_pg_net -net $net [get_pins -hierarchical */$net]
    }
}

# ===== 3. MCMM：每個 corner 一個 scenario，各自綁 RC 模型 =====
foreach rc {Cmin nominal Cmax} {
    read_parasitic_tech -tlup $TLUP_DIR/saed32nm_1p9m_${rc}.tluplus -layermap $TLUP_MAP -name rc_$rc
}
remove_scenarios -all ; remove_modes -all ; remove_corners -all
create_mode functional
dict for {name c} $CORNERS {
    create_corner $name
    create_scenario -mode functional -corner $name -name functional_$name
    current_scenario functional_$name
    set_process_number [dict get $c p]
    set_temperature    [dict get $c t]
    set_voltage        [dict get $c v] -object_list VDD
    set_voltage 0 -object_list VSS
    if {$USE_PAD} {pad_scenario_voltage $c}
    set_parasitic_parameters -early_spec rc_[dict get $c rc] -late_spec rc_[dict get $c rc]
    source $SCRIPTS/$SDC
}
set_scenario_status [all_scenarios] -active true -setup true -hold true

if {$USE_PAD} {
    # PAD 的 PG pin 電壓（核心 VDD 與 IO VDDIO 不同）
    pad_cell_voltage
    redirect pvt.rpt {report_pvt}
} else {
    # I/O pin 擺放（有 PAD 時 port 在 PAD 上，不需要）
    set io_in [remove_from_collection [all_inputs] [get_ports {VDD VSS}]]
    set_individual_pin_constraints -ports $io_in        -sides $PIN_SIDE_IN  -allowed_layers {M3 M5}
    set_individual_pin_constraints -ports [all_outputs] -sides $PIN_SIDE_OUT -allowed_layers {M3 M5}
    place_pins -self
}

# ===== 4. Power plan：ring(M7/M8) + mesh(M6/M7) + std cell rail(M1) =====
set_pg_strategy_via_rule pg_join -via_rule {{intersection: all} {via_master: default}}
create_pg_ring_pattern ring -horizontal_layer M7 -vertical_layer M8 \
    -horizontal_width 4 -vertical_width 4 -horizontal_spacing 2 -vertical_spacing 2 -corner_bridge true
set_pg_strategy ring_s -core -pattern {{name: ring} {nets: {VDD VSS}} {offset: {4 4}}}
compile_pg -strategies ring_s -via_rule pg_join
# 有 PAD：把 VDD/VSS 電源 PAD 的 M5 電源環接到剛建好的 core ring
if {$USE_PAD} {puts "PAD_PG_STITCH total [pad_ring_to_core]"}
create_pg_mesh_pattern mesh -layers {{{vertical_layer: M6} {width: 2} {spacing: interleaving} {pitch: 40} {offset: 10}} {{horizontal_layer: M7} {width: 2} {spacing: interleaving} {pitch: 40} {offset: 10}}}
set_pg_strategy mesh_s -core -pattern {{name: mesh} {nets: {VDD VSS}}} -extension {{stop: outermost_ring}}
compile_pg -strategies mesh_s -via_rule pg_join
create_pg_std_cell_conn_pattern rails -layers M1
set_pg_strategy rail_s -core -pattern {{name: rails} {nets: {VDD VSS}}} -extension {{stop: outermost_ring}}
compile_pg -strategies rail_s -via_rule pg_join
# M1 rail 與 M6/M7/M8 之間的 via 不會自動產生（只會有 ring-mesh 交點的 via），
# 少了這一行：check_pg_connectivity 顯示 floating wires，LVS 的 VDD 斷成數十段。
# 用 tech file 的方形 *_C via（REFRACT apr_repair_50ff.tcl，ICV DRC CLEAN）。
create_pg_vias -nets {VDD VSS} -from_layers M1 -to_layers M6 -via_masters {VIA12SQ_C VIA23SQ_C VIA34SQ_C VIA45SQ_C VIA56SQ_C}
# （M6→M7、M7→M8 的 via 已由 compile_pg 的 via_rule 放好；再跑一次只會得到 PGR-050）
# 位在同 net 的 M7 mesh 正下方的 rail，M1→M6 via 會落在 M6×M7 交點的 VIA67 正下方，
# create_pg_vias 預設的 DRC 檢查會整條跳過 → rail 浮接（geofence smoke test：5 條 VDD rail）。
# 只對仍有浮接的 net 用 -drc no_check 補 via（堆疊 via 是否合法由 ICV DRC 決定）。
foreach net {VDD VSS} {
    redirect -variable r {check_pg_connectivity -nets $net}
    if {[regexp {floating wires:\s*([1-9]\d*)} $r -> fw]} {
        puts "PG_FIX $net: $fw floating rails, adding stacked vias"
        create_pg_vias -nets $net -from_layers M1 -to_layers M6 -drc no_check \
            -via_masters {VIA12SQ_C VIA23SQ_C VIA34SQ_C VIA45SQ_C VIA56SQ_C}
    }
}
redirect pg_connectivity_fp.rpt {check_pg_connectivity}
redirect pg_drc_fp.rpt {check_pg_drc -do_not_check_shapes_in_lib_cells}

# 常數 1/0 改用 tie cell，不直接接 PG
# （有 PAD 時，PAD 的 R_EN/EN=1'b1 也會接 tie cell）
add_tie_cells -tie_high_lib_cells [get_lib_cells */TIEH_RVT] -tie_low_lib_cells [get_lib_cells */TIEL_RVT]
foreach net $PG_NETS {connect_pg_net -net $net [get_pins -hierarchical */$net]}
if {$USE_PAD} {
    # PAD 位置固定、不讓最佳化動到；IO library 的 cell 不能拿來當 buffer
    set_dont_touch [get_cells pad_*] true
    set_dont_use [get_lib_cells io/*]
}
save_block -as floorplan

# ===== 5. Placement =====
place_opt
foreach net $PG_NETS {connect_pg_net -net $net [get_pins -hierarchical */$net]}
redirect placement.rpt  {check_legality}
redirect placed_qor.rpt {report_qor}
save_block -as placed

# ===== 6. CTS =====
# 合成時的 ideal / dont_touch clock 一定要先解除，否則 CTS 不會插 buffer
foreach_in_collection s [all_scenarios] {
    current_scenario $s
    set_dont_touch_network -clear [all_clocks]
    remove_ideal_network [get_ports $CLK_PORT]
    # I/O delay 以 root clock 為參考，跟 PrimeTime 的語意一致。
    # 每個值都只能比 signoff 的 SDC 嚴、不能比它鬆：input min 必須 <= SDC 的 -min（官方 0）。
    # REFRACT 實測：這裡原本是 0.2，ICC2 以為 RST 晚 0.2 ns 才到，沒修 removal；
    # 繞線後 PT 用 SDC 的 0 檢查，619 個 DFF removal 違規（fast -0.07 ns）。
    set io [remove_from_collection [all_inputs] [get_ports [concat $CLK_PORT $PG_NETS]]]
    set oo [remove_from_collection [all_outputs] [get_ports $PG_NETS]]
    set_input_delay  -max 2.0 -network_latency_included -clock $CLK_PORT $io
    set_input_delay  -min 0.0 -network_latency_included -clock $CLK_PORT $io
    set_output_delay -max 2.0 -network_latency_included -clock $CLK_PORT $oo
    set_output_delay -min 0.2 -network_latency_included -clock $CLK_PORT $oo
    set_max_transition 0.25 -clock_path [all_clocks]
}
set_lib_cell_purpose -include cts [get_lib_cells {*/NBUFFX*_RVT */INVX*_RVT}]
clock_opt
foreach net $PG_NETS {connect_pg_net -net $net [get_pins -hierarchical */$net]}
redirect cts_qor.rpt   {report_qor}
redirect clock_qor.rpt {report_clock_qor}
save_block -as cts

# ===== 7. Route =====
route_auto
route_opt
# route_opt 的 ECO route 有迭代上限，可能留下少數 short／spacing（REFRACT 實測 3 個，
# 訊號線在 M6 電源條下方的 via stack 旁短到 VSS，增量 route_detail 也清不掉）。
# 修正回圈：第 1 輪拆掉有違規的 net 重繞；之後還在的，把相連的 cell 往右移 2 um
# 離開電源條、legalize 後再重繞（DRC 與 open net 都要是 0）。最多 4 輪，結果仍由下面的 check_routes 判定。
proc route_drc_nets {} {
    redirect -variable r {check_routes}
    if {![regexp {Total number of DRCs = (\d+)} $r -> n]} {set n -1}
    if {![regexp {Total number of open nets = (\d+)} $r -> o]} {set o -1}
    set nets {}
    if {$n > 0} {
        open_drc_error_data zroute.err
        foreach_in_collection e [get_drc_errors -error_data zroute.err] {
            foreach x [get_object_name [get_attribute -quiet $e objects]] {
                if {$x ni $::PG_NETS && $x ni $nets} {lappend nets $x}
            }
        }
    }
    return [list $n $o $nets]
}
for {set i 1} {$i <= 4} {incr i} {
    lassign [route_drc_nets] n o nets
    puts "ROUTE_FIX iter $i DRCs=$n open=$o nets={$nets}"
    if {$n == 0 && $o == 0} break
    if {$nets eq ""} {route_eco; route_detail -incremental true -initial_drc_from_input true; continue}
    set nets [get_nets $nets]
    if {$i >= 2} {
        set cells [filter_collection [get_cells -of [get_pins -of $nets]] "is_hard_macro==false && physical_status!=fixed"]
        foreach_in_collection c $cells {
            lassign [lindex [get_attribute $c boundary_bbox] 0] x y
            set_cell_location -coordinates [list [expr {$x + 2.0}] $y] $c
        }
        legalize_placement -cells $cells
        set nets [add_to_collection -unique $nets [get_nets -of [get_pins -of $cells]]]
        # 移過的 cell 上所有非電源的 net 都要重繞（包括 clock net；只挑 signal 會讓 clock 斷開）
        set nets [filter_collection $nets "net_type!=power && net_type!=ground"]
    }
    remove_routes -nets $nets -detail_route -global_route
    route_eco -nets $nets
    route_detail -incremental true -initial_drc_from_input true
}
foreach net $PG_NETS {connect_pg_net -net $net [get_pins -hierarchical */$net]}
redirect routed_qor.rpt   {report_qor}
redirect routes.rpt       {check_routes}
redirect connectivity.rpt {check_lvs}
redirect pg_connectivity.rpt {check_pg_connectivity}
redirect pg_drc.rpt       {check_pg_drc -do_not_check_shapes_in_lib_cells}
redirect constraints.rpt  {report_constraints -all_violators}
dict for {name c} $CORNERS {
    # report_timing 要明確指定 scenario，否則會列出所有 active scenario
    redirect setup_$name.rpt {report_timing -scenarios [get_scenarios functional_$name] -delay_type max -max_paths 10}
    redirect hold_$name.rpt  {report_timing -scenarios [get_scenarios functional_$name] -delay_type min -max_paths 10}
}
save_block -as routed
save_lib

# ===== 8. 判定 =====
# 這裡只要求繞線乾淨；剩下的 max_cap / max_transition 交給 apr_eco.tcl 修，
# 由 ECO 階段做最後的 APR_PASS 判定。
set fp [open routes.rpt r]; set r [read $fp]; close $fp
if {![regexp {Total number of DRCs = 0} $r] || ![regexp {Total number of open nets = 0} $r]} {
    puts "APR_FAIL: routing DRC/open nets, see routes.rpt"
    exit 1
}
# 電源網路不能有浮接的線、via 或 cell
# USE_PAD=1：電源 PAD 打線 terminal 浮接是 SAED32 io_std 的已知限制（LEF 的 *PAD pin
# 與 PAD 內部電源環不相連），只排除「terminals」這一項，其餘一樣要是 0。
set fp [open pg_connectivity.rpt r]; set pg [read $fp]; close $fp
if {$USE_PAD} {
    set nterm [regexp -all {Number of floating terminals:\s*[1-9]} $pg]
    puts "PAD_LIMITED: $nterm PG net(s) with floating bond terminals (io_std LEF limitation)"
    regsub -all {Number of floating terminals:\s*\d+} $pg {} pg
}
if {[regexp {Number of floating [a-zA-Z /]+:\s*[1-9]} $pg]} {
    puts "APR_FAIL: floating PG objects, see pg_connectivity.rpt"
    exit 1
}
set fp [open constraints.rpt r]; set c [read $fp]; close $fp
puts "APR_ROUTED (constraint violations: [regexp -all VIOLATED $c]; run apr_eco.tcl next)"
exit
