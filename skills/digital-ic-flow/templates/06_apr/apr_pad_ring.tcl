##############################################################################
# apr_pad_ring.tcl — USE_PAD=1 時由 apr_core.tcl source 的 PAD ring 程序
# 適用 SAED32 io_std wire-bond PAD
#       → 改成不寫死座標：die 大小、PAD 位置、PAD 電源環到核心 ring 的接線都由
#         pad_plan.tcl（pad 階段產生）、IO LEF 與 ICC2 裡的 ring 形狀推算。
#
# 提供三個 proc，apr_core.tcl 依序呼叫：
#   pad_floorplan       決定 die → initialize_floorplan → 放 corner / PAD / IO filler
#   pad_pg_setup        四組 PG net、PAD 的 PG pin、bond terminal、IO 電壓
#   pad_ring_to_core    在 core ring 建好後，把 VDD/VSS PAD 的 M4 電源條接到 ring
#   pad_pg_terminals    在 core ring 建好後，放電源 port 的 terminal（GDS 的 port 文字跟著它）
#
# SAED32 io_std 原檔的問題由 pad 階段的 fix_io_lib.py 修正（runs/iofix/）；這裡另外處理兩件
# LEF 和 GDS 不一致、只能在擺放時解決的事：PAD 電源條接到 core ring（pad_ring_to_core）、
# port terminal 放在 GDS 裡真的有金屬的地方（pad_pg_setup、pad_pg_terminals）。
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
    right  {pg_iovdd_r IOVDD_EW pg_iovss_r IOVSS_EW} \
    top    {pg_vdd_t VDD_NS pg_vss_t VSS_NS} \
    left   {pg_iovdd_l IOVDD_EW pg_iovss_l IOVSS_EW}]
# 每一邊 PAD 與 IO filler 的方向
#   上下邊用 _NS cell（原始 40 寬 × 300 高、PAD 朝下）：bottom R0、top R180
#   左右邊用 _EW cell（原始 300 寬 × 40 高、PAD 朝右）：right R0、left R180
#   不要把 _NS 轉 90 度放在左右邊：cell 裡的 PO 方向會轉錯，DRC 的 PO.W／PO.S／CO.S
#   這類有方向的規則會報幾千個錯（單獨把 I1025_NS 轉 90 度跑 DRC 就有上百個）
set PAD_ORIENT    [dict create bottom R0   right R0  top R180 left R180]
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

# 左右邊（right／left）用 _EW 版本
proc pad_side_ref {ref side} {
    if {$side in {left right}} {regsub {_NS$} $ref _EW ref}
    return $ref
}

proc pad_place_cell {name ref x y orient} {
    if {[sizeof_collection [get_cells -quiet $name]] == 0} {
        create_cell $name [get_lib_cells */$ref]
    } elseif {[get_attribute [get_cells $name] ref_name] ne $ref} {
        # netlist 裡的 PAD 是 _NS；放到左右邊時換成同功能、同 pin 的 _EW
        set_reference -block [get_lib_cells */$ref] [get_cells $name]
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
                set ref [pad_side_ref $ref $side]
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
    # 晶片訊號 port 綁在 PAD 的打線 pin（LEF：MRDL）上。terminal 一定要和 pin 重疊，否則 router
    # 會把它當成要接過去的點、拉線過去（實測 107 個繞線 DRC）。GDS 的打線區其實是 M9
    # （gen_BONDPAD，沒有 MRDL／VIARDL），所以 apr_finish.tcl 寫 GDS 時把 MRDL 上的 port 文字
    # 改寫到 M9 的 pin 文字層；terminal 中心 (20,36) 正好壓在打線區中間那條 M9 上。
    foreach_in_collection cell [get_cells pad_*] {
        set pin [get_pins [get_object_name $cell]/PADIO]
        create_terminal -port [get_ports -of_objects [get_nets -of_objects $pin]] \
            -boundary [get_attribute $pin bbox] -layer MRDL
    }
    # 電源 port 的 terminal 在 core ring 建好後才放（pad_pg_terminals）：電源 PAD 的 GDS 根本沒有
    # 打線金屬（VDD_NS／VSS_NS／IOVDD_EW／IOVSS_EW 都沒有 gen_BONDPAD），*PAD pin 下面是空的。
}

# 電源 port 的 terminal 放在真正的電源金屬上（GDS port 文字也會寫在這裡，LVS 靠它認出 VDD/VSS…）：
#   VDD／VSS    → core ring 的 M7 水平段
#   VDDIO／VSSIO → IO 電源 PAD 的 M4 電源條（修正版 LEF 從 GDS 補的 PORT）
proc pad_pg_terminals {} {
    global IO_LEF_FIXED PAD_LOC
    foreach net {VDD VSS} {
        set seg ""
        foreach_in_collection s [get_shapes -of_objects [get_nets $net] -filter "shape_use == ring && layer_name == M7"] {
            set seg $s; break
        }
        if {$seg eq ""} {error "no $net M7 ring segment for the port terminal"}
        lassign [concat {*}[get_attribute $seg bbox]] x1 y1 x2 y2
        # terminal 會寫進 GDS，座標要在格點上（layout_grid off_grid_boundary）
        set cx [expr {round(($x1+$x2)*50)/100.0}]; set cy [expr {($y1+$y2)/2.0}]
        create_terminal -port [get_ports $net] -layer M7 \
            -boundary [list [list [expr {$cx-1}] $y1] [list [expr {$cx+1}] $y2]]
        puts "PG_TERMINAL $net M7 ring at ([format %.3f $cx], [format %.3f $cy])"
    }
    foreach {net pfx} {VDDIO pg_iovdd_ VSSIO pg_iovss_} {
        set done 0
        dict for {inst loc} $PAD_LOC {
            if {$done || ![string match ${pfx}* $inst]} continue
            lassign $loc side ref ox oy
            set c [get_cells $inst]
            set w [get_attribute [get_lib_cells */$ref] width]
            set h [get_attribute [get_lib_cells */$ref] height]
            set strap ""
            foreach r [lef_pin_rects $IO_LEF_FIXED $ref $net M4] {
                lassign $r a b cc d
                if {max($cc-$a, $d-$b) > 100} {set strap $r}
            }
            if {$strap eq ""} {error "no M4 $net strap in $ref (IO_LEF_FIXED)"}
            lassign $strap a b cc d
            # 電源條中點取 1.8x1.8 的框（2 um 寬的電源條內，對齊格點後也不會凸出去）
            set mx [expr {($a+$cc)/2.0}]; set my [expr {($b+$d)/2.0}]
            lassign [pad_xform $mx $my $ox $oy $w $h [get_attribute $c orientation]] px py
            set px [expr {round($px*100)/100.0}]; set py [expr {round($py*100)/100.0}]   ;# 對齊格點
            create_terminal -port [get_ports $net] -layer M4 \
                -boundary [list [list [expr {$px-0.9}] [expr {$py-0.9}]] [list [expr {$px+0.9}] [expr {$py+0.9}]]]
            puts "PG_TERMINAL $net M4 strap of $inst at ([format %.3f $px], [format %.3f $py])"
            set done 1
        }
        if {!$done} {error "no ${pfx}* PAD for the $net port terminal"}
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

# ===== 3. 電源 PAD 接到 core ring =====
# 每個 PAD 的 GDS 裡，VDD／VDDIO／VSS／VSSIO 各有一條 2 um 寬的 M4 垂直線（gen_Buses），
# 從 PAD 內部的電源環拉到 PAD 靠 core 的那一邊。原廠 LEF 沒有寫這四條線；fix_io_lib.py
# 已把它們加進修正版 LEF（IO_LEF_FIXED）。這裡從 VDD_NS／VSS_NS PAD 自己那條線的末端，
# 用同寬的 M4 直接拉到同 net 的 core ring（M7 水平段），再疊 via 上去。
# M4 只穿過 PAD 與 core 之間的空隙，不會碰到 PAD 內其他 net 的電源環。
# （舊作法照 LEF 接縫上的 M5 pin 補一塊 M5 再用 M6 往上拉；GDS 在那裡沒有金屬，
#   M6 線還穿過 PAD 內別的 net 的 M6 電源環 → LVS VDD／VSS／VSSIO 短路、DRC M5.S.3.3）
proc pad_ring_to_core {} {
    global IO_LEF_FIXED PAD_W PAD_DEPTH PAD_LOC PAD_ORIENT
    set n 0
    dict for {inst loc} $PAD_LOC {
        lassign $loc side ref ox oy
        if {$ref eq "VDD_NS"} {set net VDD} elseif {$ref eq "VSS_NS"} {set net VSS} else continue
        if {$side ni {bottom top}} {error "$inst: core power PADs must be on the top/bottom side"}
        # 這個 PAD 自己 net 的 M4 電源線（高度超過 100 um 的那一塊）
        set strap ""
        foreach r [lef_pin_rects $IO_LEF_FIXED $ref $net M4] {
            lassign $r x1 y1 x2 y2
            if {$y2 - $y1 > 100} {set strap $r}
        }
        if {$strap eq ""} {error "no M4 power strap for $net in $ref (IO_LEF_FIXED)"}
        lassign $strap x1 y1 x2 y2
        set w  [expr {$x2 - $x1}]
        set orient [dict get $PAD_ORIENT $side]
        lassign [pad_xform [expr {($x1+$x2)/2.0}] $y2 $ox $oy $PAD_W $PAD_DEPTH $orient] px py
        # 同 net 的 ring：M7 水平段，取離 PAD 最近的一段
        set target ""; set dist 1e9
        foreach_in_collection s [get_shapes -of_objects [get_nets $net] -filter "shape_use == ring"] {
            lassign [concat {*}[get_attribute $s bbox]] bx1 by1 bx2 by2
            if {[get_attribute $s layer_name] ne "M7" || $px <= $bx1 || $px >= $bx2} continue
            set c [expr {($by1+$by2)/2.0}]; set d [expr {abs($c-$py)}]
            if {$d < $dist} {set dist $d; set target $c}
        }
        if {$target eq ""} {error "no $net M7 ring segment facing $inst"}
        create_shape -shape_type path -layer M4 -width $w -net $net -shape_use stripe \
            -path [list [list $px $py] [list $px $target]]
        foreach v {VIA45SQ VIA56SQ VIA67SQ} {
            create_via -via_def $v -size {4 4} -origin [list $px $target] -net $net -shape_use stripe
        }
        puts "PAD_PG_STITCH $inst $net side=$side M4 x=$px from y=$py -> ring y=$target"
        incr n
    }
    return $n
}
