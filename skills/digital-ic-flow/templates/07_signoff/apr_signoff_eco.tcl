##############################################################################
# apr_signoff_eco.tcl — 階段 9 回圈：用 StarRC + PT 的結果回頭修 max_cap / max_transition
# 來源：REFRACT apr_starrc_eco_50ff.tcl（手動列 12 個 size_cell＋4 個 buffer）
#       → 改成讀 PT post-route 報告自動處理。
# 為什麼需要：ICC2 用 TLU+ 估計 RC，StarRC 的 Cmax 通常多幾 %，
#   繞線後 PT 會出現 8.35 fF > 8 fF 這種小幅超標（geofence smoke test 實測 9 個 pin）。
# 做法：違規 driver 的 cell 升一級驅動（X1→X2→X4…）；沒有更大尺寸就插 buffer。
# 執行：cd runs/apr && icc2_shell -f ../../scripts/apr_signoff_eco.tcl
# 之後重跑：finish → drc（必要時 drc_patch → finish → drc）→ lvs → starrc → pt_post
##############################################################################
source [file join [file dirname [info script]] flow_config.tcl]

# ---------- 依設計修改 ----------
set PT_REPORTS [glob -nocomplain $RUNS/pt_post/reports_*/constraints.rpt]
set SIZES      {0 1 2 4 8 16 32}
set FALLBACK_BUF NBUFFX8_RVT
# --------------------------------

# 解析 PT 的 report_constraint：只看 max_capacitance / max_transition 段落，
# pin 名稱可能和數字在同一行，也可能在上一行（名稱太長時 PT 會換行）
set pins {}
foreach f $PT_REPORTS {
    set fp [open $f r]; set lines [split [read $fp] \n]; close $fp
    set section ""; set prev ""
    foreach l $lines {
        if {[regexp {^\s+(max_capacitance|max_transition|max_delay|min_delay|max_leakage_power)\s*$} $l -> section]} continue
        if {$section in {max_capacitance max_transition} && [string match *(VIOLATED)* $l]} {
            set first [lindex $l 0]
            set pin [expr {[string is double -strict $first] ? [lindex $prev 0] : $first}]
            if {$pin ni $pins} {lappend pins $pin}
        }
        if {[string trim $l] ne ""} {set prev $l}
    }
}
puts "SIGNOFF_ECO: [llength $pins] violating pins from [llength $PT_REPORTS] PT reports"
if {[llength $pins] == 0} {puts "SIGNOFF_ECO_PASS (nothing to do)"; exit}

open_lib $NDM_LIB
open_block routed
save_block -as routed_before_signoff_eco -force
open_block routed
link_block

# 升級驅動：找下一個「輸出 max_capacitance 真的變大」的 X 尺寸。
# SAED32 的 X0 與 X1 max_cap 一樣（NAND2X0/X1、INVX0/X1 都是 8 fF），只升一級會白跑一整輪
# finish→drc→lvs→starrc→pt_post（geofence USE_PAD=1 實測）。
proc out_maxcap {lib_cell} {
    set m 0
    foreach_in_collection p [get_lib_pins -quiet [get_object_name $lib_cell]/* -filter "direction == out"] {
        set c [get_attribute -quiet $p max_capacitance]
        if {$c ne "" && $c > $m} {set m $c}
    }
    return $m
}
proc next_size {ref} {
    global SIZES
    if {![regexp {^(.*X)(\d+)(_[A-Z]+)$} $ref -> base cur suf]} {return ""}
    set now [out_maxcap [index_collection [get_lib_cells */$ref] 0]]
    foreach s $SIZES {
        if {$s <= $cur} continue
        set lc [get_lib_cells -quiet */$base$s$suf]
        if {[sizeof_collection $lc] == 0} continue
        if {[out_maxcap [index_collection $lc 0]] > $now} {return $base$s$suf}
    }
    return ""
}

# filler 會擋住變大的 cell，先拿掉；apr_finish.tcl 會重新補
set fillers [get_cells -hierarchical -quiet -filter {ref_name =~ SHFILL*}]
if {[sizeof_collection $fillers] > 0} {remove_cells $fillers}

set n 0
foreach pin $pins {
    set p [get_pins -quiet $pin]
    if {[sizeof_collection $p] == 0} {puts "skip $pin (not found)"; continue}
    set cell [get_cells -of_objects $p]
    set ref  [get_attribute $cell ref_name]
    set up   [next_size $ref]
    if {$up ne ""} {
        size_cell $cell [get_lib_cells */$up]
        puts "SIZE [get_object_name $cell] $ref -> $up"
    } else {
        insert_buffer $p [get_lib_cells */$FALLBACK_BUF] -new_cell_names signoff_buf_$n -new_net_names signoff_net_$n
        puts "BUFFER $pin ($ref has no larger size)"
    }
    incr n
}
legalize_placement -incremental
foreach net $PG_NETS {connect_pg_net -net $net [get_pins -hierarchical */$net]}
route_eco -reroute modified_nets_first_then_others
route_detail -incremental true -initial_drc_from_input true -max_number_iterations 30
# 增量繞線偶爾留下 diff-net spacing 之類的 DRC：再跑幾次 detail route 直到乾淨
for {set i 0} {$i < 3} {incr i} {
    redirect -variable rr {check_routes}
    if {[regexp {Total number of DRCs = 0} $rr]} break
    puts "ROUTE_RETRY [expr {$i+1}]"
    route_detail -incremental true -initial_drc_from_input true -max_number_iterations 50
}
redirect signoff_eco_routes.rpt {check_routes}
redirect signoff_eco_legality.rpt {check_legality}
save_block
save_lib

set fp [open signoff_eco_routes.rpt r]; set r [read $fp]; close $fp
if {![regexp {Total number of DRCs = 0} $r] || ![regexp {Total number of open nets = 0} $r]} {
    puts "SIGNOFF_ECO_FAIL: routing not clean"; exit 1
}
puts "SIGNOFF_ECO: changed $n cells"
puts "SIGNOFF_ECO_PASS"
exit
