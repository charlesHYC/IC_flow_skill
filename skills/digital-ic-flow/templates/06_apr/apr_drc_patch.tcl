##############################################################################
# apr_drc_patch.tcl — ICV DRC 回報 M1 細小突出（例如 M1.W.2.1）時的修補
# 讀 ICV 錯誤檔自動找要補的位置，不必手列 cell 名稱
# 原理：繞線在 cell pin 旁留下 <0.06 um 的 M1 細條；在同一 net 上畫一塊 M1 矩形，
#       蓋住「pin 形狀 ∪ 錯誤區域」，細條就併成寬金屬。PDK 與規則都不改。
# 執行：cd runs/apr && icc2_shell -f ../../scripts/apr_drc_patch.tcl
# 之後重跑 apr_finish.tcl（重新匯出 GDS）與 run_icv_drc.sh 驗證。
##############################################################################
source [file join [file dirname [info script]] flow_config.tcl]

# ---------- 依設計修改 ----------
set ERR_FILE  $RUNS/drc/$TOP.LAYOUT_ERRORS
set RULE_GLOB {M1.*}          ;# 只處理 M1 規則
set MARGIN    0.01            ;# um；錯誤區常常只「貼著」pin 邊緣，搜尋時要放大一點
# --------------------------------

# 錯誤檔一定要是「目前這份 GDS」的 DRC 結果。用舊的錯誤檔會把補丁畫在錯的地方，
# 反而產生新的 M1.S.1／M1.S.9 spacing 錯誤（2026-11-12 實測：手動跳過 drc 直接跑 drc_patch）。
if {![file exists $ERR_FILE] || [file mtime $ERR_FILE] < [file mtime $ROUTED_GDS]} {
    puts "DRC_PATCH_FAIL: $ERR_FILE is older than $ROUTED_GDS — run the drc stage first"
    exit 1
}

# 解析 ICV 錯誤檔：規則名稱行之後的 "(llx, lly) (urx, ury)" 座標
set fp [open $ERR_FILE r]; set lines [split [read $fp] \n]; close $fp
set boxes {}
set rule ""
set details 0
foreach l $lines {
    if {[string match *ERROR\ DETAILS* $l]} {set details 1; continue}
    if {!$details} continue
    if {[regexp {^([A-Z0-9]+\.[A-Za-z0-9.]+):} $l -> r]} {set rule $r; continue}
    if {[string match $RULE_GLOB $rule] &&
        [regexp {\(\s*([-0-9.]+),\s*([-0-9.]+)\)\s*\(\s*([-0-9.]+),\s*([-0-9.]+)\)} $l -> x1 y1 x2 y2]} {
        lappend boxes [list $rule [list [list $x1 $y1] [list $x2 $y2]]]
    }
}
puts "DRC_PATCH: [llength $boxes] M1 error boxes"
if {[llength $boxes] == 0} {puts "DRC_PATCH_PASS (nothing to do)"; exit}

open_lib $NDM_LIB
open_block routed
save_block -as routed_before_drc_patch -force
open_block routed
link_block

set patched 0
foreach b $boxes {
    lassign $b rule box
    # 找與錯誤區域相交的 M1 pin（cell 的 pin 形狀）
    set sbox [list [list [expr {[lindex $box 0 0]-$MARGIN}] [expr {[lindex $box 0 1]-$MARGIN}]] \
                   [list [expr {[lindex $box 1 0]+$MARGIN}] [expr {[lindex $box 1 1]+$MARGIN}]]]
    set pins [get_objects_by_location -classes pin -intersect $sbox -quiet]
    set done 0
    foreach_in_collection p $pins {
        set net [get_nets -quiet -of_objects $p]
        if {[sizeof_collection $net] == 0} continue
        set pb [get_attribute $p bbox]
        set llx [expr {min([lindex $pb 0 0],[lindex $box 0 0])}]
        set lly [expr {min([lindex $pb 0 1],[lindex $box 0 1])}]
        set urx [expr {max([lindex $pb 1 0],[lindex $box 1 0])}]
        set ury [expr {max([lindex $pb 1 1],[lindex $box 1 1])}]
        create_shape -shape_type rect -layer M1 -net $net -boundary [list [list $llx $lly] [list $urx $ury]]
        puts "PATCH $rule [get_object_name $p] net=[get_object_name $net] box={{$llx $lly} {$urx $ury}}"
        incr patched; set done 1
        break
    }
    if {!$done} {puts "UNPATCHED $rule $box — no pin here, inspect in GUI"}
}
redirect patched_routes.rpt {check_routes}
save_block
save_lib
puts "DRC_PATCH: patched $patched / [llength $boxes]"
if {$patched < [llength $boxes]} {exit 1}
puts "DRC_PATCH_PASS"
exit
