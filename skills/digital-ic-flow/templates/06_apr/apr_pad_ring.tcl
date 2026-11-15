##############################################################################
# apr_pad_ring.tcl — USE_PAD=1 時由 apr_core.tcl source 的 PAD ring 程序
# 來源：geofence scripts/apr/floorplan.tcl + power.tcl（SAED32 io_std wire-bond）
#       → 改成不寫死座標：die 大小、PAD 位置、PAD 電源環到核心 ring 的接線都由
#         pad_plan.tcl（pad 階段產生）、IO LEF 與 ICC2 裡的 ring 形狀推算。
#
# 提供三個 proc，apr_core.tcl 依序呼叫：
#   pad_floorplan       決定 die → initialize_floorplan → 放 corner / PAD / IO filler
#   pad_pg_setup        四組 PG net、PAD 的 PG pin、bond terminal、IO 電壓
#   pad_ring_to_core    在 core ring 建好後，把 VDD/VSS PAD 的 M5 電源環接到 ring
#
# SAED32 io_std 已知限制（geofence 實測，library 本身的問題）：
#   PAD 的 PG pin 在 LEF 與 GDS 位置不一致（同層覆蓋率 0%），電源 PAD 的 GDS 沒有
#   LEF 宣告的 MRDL 打線金屬。ICC2 裡看起來接好了，全晶片 LVS 仍會有 VDD/VSS/VDDIO/VSSIO
#   open，DRC 也會有 IO cell 自己的錯誤（VDD_NS 單獨跑就有 14 個）。不要用假連線掩蓋。
##############################################################################

# ---------- 依設計修改 ----------
set PAD_W        40          ;# _NS PAD 寬度（um，沿 die 邊）
set PAD_DEPTH    300         ;# PAD 高度（um，垂直 die 邊）；CORNER 是 PAD_DEPTH × PAD_DEPTH
set PAD_GAP      40          ;# PAD 內緣到 core 邊界的距離，留給 core ring 與 PAD 接線
set MIN_SLOTS    0           ;# 每邊最少幾個 PAD 位置（0 = 自動）；想要 core 大一點就加大
set IO_FILLER    FILLER40    ;# 300×40 的 IO spacer，旋轉後填 PAD 之間的空位
# 四邊各放一對電源 PAD：上下邊放核心電源，左右邊放 IO 電源
set PG_PADS [dict create \
    bottom {pg_vdd_b VDD_NS pg_vss_b VSS_NS} \
    right  {pg_iovdd_r IOVDD_NS pg_iovss_r IOVSS_NS} \
    top    {pg_vdd_t VDD_NS pg_vss_t VSS_NS} \
    left   {pg_iovdd_l IOVDD_NS pg_iovss_l IOVSS_NS}]
# 每一邊 PAD 與 IO filler 的方向（_NS cell 原始方向是 40 寬 × 300 高、PAD 朝下）
set PAD_ORIENT    [dict create bottom R0   right R90 top R180 left R270]
set FILL_ORIENT   [dict create bottom R270 right R0  top R90  left R180]
set CORNER_ORIENT [dict create bl R270 br R0 tr R90 tl R180]
# --------------------------------

source $PAD_DIR/pad_plan.tcl        ;# SIGNAL_PADS / OUTPUT_PADS（pad_tools.py 產生）

# 讀 IO LEF，取出 <macro>/<pin> 在 <layer> 上的 RECT（PAD 本身座標）
proc lef_pin_rects {lef macro pin layer} {
    set fp [open $lef r]; set rects {}; set in_m 0; set in_p 0; set lay ""
    while {[gets $fp l] >= 0} {
        if {[regexp {^MACRO\s+(\S+)} $l -> m]} {set in_m [expr {$m eq $macro}]; continue}
        if {!$in_m} continue
        if {[regexp "^END\\s+$macro\\s*$" $l]} break
        if {[regexp {^\s+PIN\s+(\S+)} $l -> p]} {set in_p [expr {$p eq $pin}]; continue}
        if {!$in_p} continue
        if {[regexp {LAYER\s+(\S+)\s*;} $l -> lay]} continue
        if {$lay eq $layer && [regexp {RECT\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)} $l -> a b c d]} {
            lappend rects [list $a $b $c $d]
        }
    }
    close $fp
    return $rects
}

# PAD 座標 (x,y) → 晶片座標；(ox,oy) 是 set_cell_location 的左下角，w/h 是 cell 原始寬高
proc pad_xform {x y ox oy w h orient} {
    switch $orient {
        R0   {return [list [expr {$ox+$x}]      [expr {$oy+$y}]]}
        R90  {return [list [expr {$ox+$h-$y}]   [expr {$oy+$x}]]}
        R180 {return [list [expr {$ox+$w-$x}]   [expr {$oy+$h-$y}]]}
        R270 {return [list [expr {$ox+$y}]      [expr {$oy+$w-$x}]]}
    }
}

proc pad_place_cell {name ref x y orient} {
    if {[sizeof_collection [get_cells -quiet $name]] == 0} {
        create_cell $name [get_lib_cells */$ref]
    }
    set_cell_location [get_cells $name] -coordinates [list $x $y] -orientation $orient -fixed
}

# ===== 1. Floorplan：die 大小由 PAD 數量與核心面積決定 =====
proc pad_floorplan {core_area util} {
    global PAD_W PAD_DEPTH PAD_GAP MIN_SLOTS IN_PAD OUT_PAD IO_FILLER PG_PADS \
           PAD_ORIENT FILL_ORIENT CORNER_ORIENT SIGNAL_PADS OUTPUT_PADS PAD_SIDES PAD_LOC DIE_SIZE CORE_OFF
    # 訊號 PAD 依 port 順序平均分到四邊，每邊中間插入該邊的電源 PAD
    set n   [llength $SIGNAL_PADS]
    set per [expr {int(ceil($n/4.0))}]
    set PAD_SIDES [dict create]
    set i 0
    foreach side {bottom right top left} {
        set sig  [lrange $SIGNAL_PADS [expr {$i*$per}] [expr {($i+1)*$per-1}]]
        set half [expr {[llength $sig]/2}]
        set pg   {}
        foreach {inst ref} [dict get $PG_PADS $side] {lappend pg $inst}
        dict set PAD_SIDES $side [concat [lrange $sig 0 [expr {$half-1}]] $pg [lrange $sig $half end]]
        incr i
    }
    set need 0
    dict for {side l} $PAD_SIDES {set need [expr {max($need,[llength $l])}]}
    # core 邊長 = sqrt(面積 / utilization)；PAD 數少時 die 由 PAD 決定（pad-limited）
    set core_side [expr {sqrt($core_area/$util)}]
    set slots [expr {max($need, $MIN_SLOTS, int(ceil(($core_side + 2*$PAD_GAP)/double($PAD_W))))}]
    set DIE_SIZE [expr {2*$PAD_DEPTH + $slots*$PAD_W}]
    set CORE_OFF [expr {$PAD_DEPTH + $PAD_GAP}]
    puts "PAD_FLOORPLAN pads=[expr {$n+8}] slots/side=$slots die=${DIE_SIZE}um core=[expr {$DIE_SIZE-2*$CORE_OFF}]um (need ${core_side}um)"

    initialize_floorplan -control_type die -boundary [list {0 0} [list $DIE_SIZE $DIE_SIZE]] \
        -core_offset $CORE_OFF -site_def unit
    # DRC 分類（run_icv_drc.sh）要知道 PAD ring 的範圍：die 邊長與 PAD 高度
    set fp [open pad_geometry.txt w]; puts $fp "DIE $DIE_SIZE PAD_DEPTH $PAD_DEPTH CORE_OFF $CORE_OFF"; close $fp

    set far [expr {$DIE_SIZE - $PAD_DEPTH}]
    pad_place_cell corner_bl CORNER 0    0    [dict get $CORNER_ORIENT bl]
    pad_place_cell corner_br CORNER $far 0    [dict get $CORNER_ORIENT br]
    pad_place_cell corner_tr CORNER $far $far [dict get $CORNER_ORIENT tr]
    pad_place_cell corner_tl CORNER 0    $far [dict get $CORNER_ORIENT tl]

    # PAD 從 corner 旁邊開始連續排，剩下的位置放 IO filler，PAD ring 才會連續
    set refs [dict create]
    foreach side {bottom right top left} {
        foreach {inst ref} [dict get $PG_PADS $side] {dict set refs $inst $ref}
    }
    set PAD_LOC [dict create]
    dict for {side names} $PAD_SIDES {
        for {set k 0} {$k < $slots} {incr k} {
            set a [expr {$PAD_DEPTH + $PAD_W*$k}]
            switch $side {
                bottom {set xy [list $a 0]}
                top    {set xy [list $a $far]}
                left   {set xy [list 0 $a]}
                right  {set xy [list $far $a]}
            }
            if {$k < [llength $names]} {
                set inst [lindex $names $k]
                if {[dict exists $refs $inst]} {
                    set ref [dict get $refs $inst]
                } elseif {$inst in $OUTPUT_PADS} {
                    set ref $OUT_PAD
                } else {
                    set ref $IN_PAD
                }
                pad_place_cell $inst $ref {*}$xy [dict get $PAD_ORIENT $side]
                dict set PAD_LOC $inst [list $side $ref {*}$xy]
            } else {
                pad_place_cell iofill_${side}_$k $IO_FILLER {*}$xy [dict get $FILL_ORIENT $side]
            }
        }
    }
    redirect pad_locations.rpt {
        foreach_in_collection c [get_cells -filter "is_hierarchical == false && is_fixed == true"] {
            puts "[get_object_name $c] [get_attribute $c ref_name] [get_attribute $c bbox] [get_attribute $c orientation]"
        }
    }
}

# ===== 2. 四組 PG net、PAD PG pin、bond terminal =====
proc pad_pg_setup {} {
    global CORNERS
    foreach {net type} {VDD power VSS ground VDDIO power VSSIO ground} {
        create_net -$type $net
        create_port -direction inout -port_type $type $net
        connect_pg_net -net $net [get_ports $net]
        connect_pg_net -net $net [get_pins -hierarchical */$net]
    }
    # 電源 PAD 的打線 pin
    connect_pg_net -net VDD   [get_pins pg_vdd_*/VDDPAD]
    connect_pg_net -net VSS   [get_pins pg_vss_*/VSSPAD]
    connect_pg_net -net VDDIO [get_pins pg_iovdd_*/VDDIOPAD]
    connect_pg_net -net VSSIO [get_pins pg_iovss_*/VSSIOPAD]
    # 晶片 port 綁在 PAD 的打線金屬（MRDL）上：訊號 = PADIO，電源 = *PAD pin
    foreach_in_collection cell [get_cells pad_*] {
        set pin [get_pins [get_object_name $cell]/PADIO]
        create_terminal -port [get_ports -of_objects [get_nets -of_objects $pin]] \
            -boundary [get_attribute $pin bbox] -layer MRDL
    }
    foreach {net cells pin} {VDD pg_vdd_* VDDPAD VSS pg_vss_* VSSPAD VDDIO pg_iovdd_* VDDIOPAD VSSIO pg_iovss_* VSSIOPAD} {
        foreach_in_collection cell [get_cells $cells] {
            create_terminal -port [get_ports $net] -layer MRDL \
                -boundary [get_attribute [get_pins [get_object_name $cell]/$pin] bbox]
        }
    }
}

# 每個 scenario 都要設：IO 電壓（VDDIO）與 PAD 的 PG pin 電壓
proc pad_scenario_voltage {c} {
    set_voltage [dict get $c vio] -object_list VDDIO
    set_voltage 0 -object_list VSSIO
}
proc pad_cell_voltage {} {
    global CORNERS
    dict for {name c} $CORNERS {
        current_corner $name
        foreach_in_collection cell [get_cells -filter "is_hierarchical == false && ref_name !~ *_RVT && ref_name != CORNER && ref_name !~ FILLER*"] {
            set n [get_object_name $cell]
            catch {set_voltage [dict get $c v]   -cell $n -pg_pin_name VDD}
            catch {set_voltage [dict get $c vio] -cell $n -pg_pin_name VDDIO}
            catch {set_voltage 0 -cell $n -pg_pin_name VSS}
            catch {set_voltage 0 -cell $n -pg_pin_name VSSIO}
        }
    }
}

# ===== 3. PAD 電源環（M5，在 PAD 內緣）接到 core ring =====
# 每個 VDD_NS / VSS_NS PAD：在 PAD 右側接縫補一塊 M5（兩顆 PAD 的 0.19 um pin 併成 0.38 um），
# 打 via 上去，用一條 M6（上下邊）或 M7（左右邊）拉到同 net 的 core ring。
proc pad_ring_to_core {} {
    global IO_LEF PAD_W PAD_DEPTH PAD_LOC
    set n 0
    dict for {inst loc} $PAD_LOC {
        lassign $loc side ref ox oy
        if {$ref eq "VDD_NS"} {set net VDD} elseif {$ref eq "VSS_NS"} {set net VSS} else continue
        # 取 PAD 右側接縫（x = PAD_W）上、最靠近 PAD 內緣（y 最大）的 M5 pin
        set best ""
        foreach r [lef_pin_rects $IO_LEF $ref $net M5] {
            lassign $r x1 y1 x2 y2
            if {$x2 < $PAD_W - 0.001} continue
            if {$best eq "" || $y2 > [lindex $best 3]} {set best $r}
        }
        if {$best eq ""} {error "no M5 $net pin on seam of $ref"}
        lassign $best x1 y1 x2 y2
        set orient [dict get [dict create bottom R0 right R90 top R180 left R270] $side]
        lassign [pad_xform $PAD_W [expr {($y1+$y2)/2.0}] $ox $oy $PAD_W $PAD_DEPTH $orient] px py
        set hh [expr {($y2-$y1)/2.0 - 0.5}]
        # 同 net 的 ring：上下邊找 M7 水平段，左右邊找 M8 垂直段，取最靠近 PAD 的那一段
        set rings [get_shapes -of_objects [get_nets $net] -filter "shape_use == ring"]
        set target ""; set dist 1e9
        foreach_in_collection s $rings {
            set bb [get_attribute $s bbox]; set lay [get_attribute $s layer_name]
            lassign [concat {*}$bb] bx1 by1 bx2 by2
            if {$side in {bottom top} && $lay eq "M7" && $px > $bx1 && $px < $bx2} {
                set c [expr {($by1+$by2)/2.0}]; set d [expr {abs($c-$py)}]
            } elseif {$side in {left right} && $lay eq "M8" && $py > $by1 && $py < $by2} {
                set c [expr {($bx1+$bx2)/2.0}]; set d [expr {abs($c-$px)}]
            } else continue
            if {$d < $dist} {set dist $d; set target $c}
        }
        if {$target eq ""} {error "no $net ring segment facing $inst"}
        if {$side in {bottom top}} {
            # M5 補丁跨接縫 → VIA56 → M6 垂直線 → VIA67 落在 M7 ring
            create_shape -shape_type rect -layer M5 -net $net -shape_use stripe \
                -boundary [list [list [expr {$px-0.19}] [expr {$py-$hh}]] [list [expr {$px+0.19}] [expr {$py+$hh}]]]
            create_via -via_def VIA56SQ -size {4 2} -origin [list $px $py] -net $net -shape_use stripe
            create_shape -shape_type path -layer M6 -width 1 -net $net -shape_use stripe \
                -path [list [list $px $py] [list $px $target]]
            create_via -via_def VIA67SQ -size {4 4} -origin [list $px $target] -net $net -shape_use stripe
        } else {
            # 左右邊：M5 補丁 → VIA56 + VIA67 → M7 水平線 → VIA78 落在 M8 ring
            create_shape -shape_type rect -layer M5 -net $net -shape_use stripe \
                -boundary [list [list [expr {$px-$hh}] [expr {$py-0.19}]] [list [expr {$px+$hh}] [expr {$py+0.19}]]]
            create_via -via_def VIA56SQ -size {2 4} -origin [list $px $py] -net $net -shape_use stripe
            create_via -via_def VIA67SQ -size {2 4} -origin [list $px $py] -net $net -shape_use stripe
            create_shape -shape_type path -layer M7 -width 1 -net $net -shape_use stripe \
                -path [list [list $px $py] [list $target $py]]
            create_via -via_def VIA78SQ -size {4 4} -origin [list $target $py] -net $net -shape_use stripe
        }
        puts "PAD_PG_STITCH $inst $net side=$side at ($px,$py) -> ring $target"
        # 記下 PAD 端補丁的範圍：DRC 分類時，碰到這裡的錯誤另外列為 stitch（見 drc_pad_classify.py）
        set fp [open pad_geometry.txt a]
        puts $fp "STITCH $inst [expr {$px-$hh-0.5}] [expr {$py-$hh-0.5}] [expr {$px+$hh+0.5}] [expr {$py+$hh+0.5}]"
        close $fp
        incr n
    }
    return $n
}
