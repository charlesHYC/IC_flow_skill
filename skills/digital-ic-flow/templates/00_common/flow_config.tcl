##############################################################################
# flow_config.tcl — 全流程共用設定（每個階段的 tcl 第一行都 source 這個檔）
# 換一個設計時先改這個檔的「設計資訊」與「I/O 約束」；各階段腳本檔頭的
# 「依設計修改」區塊再依需要調整。標 ← 的值一定要換成你自己的設計。
##############################################################################

# ---- 專案路徑（以本檔位置推算，腳本放在 <proj>/scripts/ 下） ----
set PROJ   [file normalize [file join [file dirname [info script]] ..]]
set RUNS   $PROJ/runs

# ---- 設計資訊 ----
set DESIGN     MY_TOP            ;# ← RTL 的 top module 名稱（.sh 腳本也從這裡讀）
set RTL_FILES  [list $PROJ/rtl/$DESIGN.v]   ;# ← RTL 檔案清單，多個檔案就列多個
set CLK_PORT   clk               ;# ← clock port 名稱
set PERIOD     30.0              ;# ← clock 週期（ns），照題目規定
set MAX_FANOUT ""                ;# DC 加權扇出上限；空 = 不設。小設計可設 1.0 多留電容餘裕，
                                  #   大型 datapath（乘法器等）設了常常達不到，合成會失敗

# ---- I/O 約束（照題目給的 SDC 填；SDC、APR 都讀這組，只在這裡改） ----
# 相對於 clock 的外部延遲（ns）。APR 階段直接沿用，不能另外寫一組比較鬆的值：
# APR 用比 signoff 鬆的 min delay，會以為 hold／removal 沒問題而不修，繞線後 PT 才失敗。
set IN_DELAY_MAX   1.0           ;# ← input 最晚到達（setup 用）
set IN_DELAY_MIN   0.0           ;# ← input 最早到達（hold／removal 用；越小越嚴格）
set OUT_DELAY_MAX  1.0           ;# ← output 要求提早多久穩定（setup 用）
set OUT_DELAY_MIN  0.0           ;# ← output 的 hold 要求

# ---- 要不要上 PAD：0 = 只做核心（core-only），1 = 加 IO PAD 做全晶片 ----
# **設計一開始就要決定**（開專案、寫 RTL 之前先問使用者）：PAD 的延遲會影響 RTL 模擬、
# 合成、STA 與閘級模擬，不是 APR 才加的東西。環境變數 USE_PAD 可暫時覆蓋。
# USE_PAD=1 時從第 0 步（pad 階段）就改用晶片 top ${DESIGN}_chip：
#   pad      從 RTL port 產生 wrapper，並從 IO library 查出 PAD 延遲，產生帶 specify 的 PAD model
#   rtl_sim  模擬 wrapper＋RTL＋PAD model，PAD 延遲已經在裡面
#   合成／Formality／STA／閘級模擬／APR／signoff 都以 ${DESIGN}_chip 為 top，1 pF 板級負載
# SAED32 io_std 原檔有 GDS／CDL／LEF 錯誤，pad 階段的 fix_io_lib.py 會產生修正版（runs/iofix/），
# 之後的 APR、DRC、LVS 都用修正版；DRC／LVS 的判定和核心一樣，CLEAN／PASS 才算過。
set USE_PAD 0
if {[info exists ::env(USE_PAD)] && $::env(USE_PAD) ne ""} {set USE_PAD $::env(USE_PAD)}
# RTL 模擬（沒有 SDF）時 PAD model 用哪個 corner 的延遲；slow 最保守
set PAD_SIM_CORNER slow
set PAD_IN_TRAN    0.10     ;# ns，晶片 port 的輸入 transition（與 constraints_chip.sdc 一致）
set PAD_IN_LOAD    5        ;# fF，input PAD DOUT 推的核心負載估計
set PAD_OUT_TRAN   0.10     ;# ns，核心 cell 推 output PAD DIN 的 transition 估計
set PAD_OUT_LOAD   1000     ;# fF，板級負載 1 pF（與 constraints_chip.sdc 一致）

# ---- 製程選擇：saed32 | cbdk ----
set PROCESS saed32

if {$PROCESS eq "cbdk"} {
    # IC Contest 評分製程：只有 slow corner，單位 ns / pF / kOhm
    set LIB_DIR    /mnt/nfs/opt/PROCESS/CBDK_IC_Contest_v2.5/SynopsysDC/db
    set LIB_SLOW   slow
    set LIB_TYP    slow
    set LIB_FAST   slow
    set CELL_MODEL /mnt/nfs/opt/PROCESS/CBDK_IC_Contest_v2.5/Verilog/tsmc13_neg.v
    set WLM        tsmc13_wl10
} else {
    # SAED32 EDK RVT：三個 corner，單位 ns / fF / MOhm
    set PDK        /mnt/nfs/opt/PROCESS/SAED32_EDK
    set LIB_DIR    $PDK/lib/stdcell_rvt/db_nldm
    set LIB_SLOW   saed32rvt_ss0p95v125c
    set LIB_TYP    saed32rvt_tt1p05v25c
    set LIB_FAST   saed32rvt_ff1p16vn40c
    set CELL_MODEL $PDK/lib/stdcell_rvt/verilog/saed32nm.v
    set WLM        ForQA
    # 實體資料
    set TECH_TF    $PDK/tech/milkyway/saed32nm_1p9m_mw.tf
    set CELL_LEF   $PDK/lib/stdcell_rvt/lef/saed32nm_rvt_1p9m.lef
    set CELL_GDS   $PDK/lib/stdcell_rvt/gds/saed32nm_rvt_oa.gds
    set CELL_CDL   $PDK/lib/stdcell_rvt/lvs/saed32nm_rvt.cdl
    set GDS_MAP    $PDK/tech/milkyway/saed32nm_1p9m_gdsout_mw.map
    set TLUP_DIR   $PDK/tech/star_rcxt
    set TLUP_MAP   $TLUP_DIR/saed32nm_tf_itf_tluplus.map
    set ICV_DRC_RS $PDK/tech/icv_drc/saed32nm_1p9m_drc_rules.rs
    # IO PAD library（USE_PAD=1 才用到；io_std wire-bond 版本）
    set IO_DIR     $PDK/lib/io_std
    set IO_DB_DIR  $IO_DIR/db_nldm
    set IO_LEF     $IO_DIR/lef/saed32_io_wb_all.lef
    set IO_GDS     $IO_DIR/gds/saed32_stdio_wb.gds
    set IO_CDL     $IO_DIR/lvs/saedio_std_wb.cdl
    set IO_MODEL   $IO_DIR/verilog/saed32nm_io_wb.v
    # 填 _NS 版本（上下邊用）。左右邊在 APR 自動換成同功能的 _EW 版本：
    # _NS 旋轉 90 度放在左右邊會讓 PO 方向錯，DRC 出現幾千個 PO.W／PO.S 錯誤
    set IN_PAD     I1025_NS          ;# input PAD（.PADIO .DOUT .R_EN=1）
    set OUT_PAD    D4I1025_NS        ;# output PAD（.PADIO .DIN .EN=1），4 mA
}
if {$USE_PAD && $PROCESS ne "saed32"} {
    # CBDK_IC_Contest_v2.5 沒有 IO PAD library（只有核心 slow/typical/fast.db）
    error "USE_PAD=1 needs an IO PAD library: only PROCESS saed32 (io_std) is set up in this template"
}

# corner 名稱 -> library、RC 模型（APR／StarRC／PT 共用同一張對照表）
# io / vio：PAD library 與 IO 電壓（只在 USE_PAD=1 使用）
set CORNERS [dict create \
    slow    [dict create lib $LIB_SLOW rc Cmax    v 0.95 t 125 p 0.99 io saed32io_wb_ss0p95v125c_2p25v vio 2.25] \
    typical [dict create lib $LIB_TYP  rc nominal v 1.05 t 25  p 1.00 io saed32io_wb_tt1p05v25c_2p5v  vio 2.50] \
    fast    [dict create lib $LIB_FAST rc Cmin    v 1.16 t -40 p 1.01 io saed32io_wb_ff1p16vn40c_2p75v vio 2.75]]

# ---- 各階段產物位置（下游階段從這裡讀上游結果） ----
set SYN_DIR  $RUNS/synthesis
set APR_DIR  $RUNS/apr
# 核心模式 top = $DESIGN；PAD 模式從一開始就是 ${DESIGN}_chip（pad 階段由 RTL 產生的 wrapper）
set CHIP_TOP  ${DESIGN}_chip
set PAD_DIR   $RUNS/pad
# 修正版 IO library（pad 階段由 fix_io_lib.py 從 PDK 原檔產生；PDK 不動）：
#   GDS 修了輸入 PAD 的 PADIO/VDDIO 短路與幾個小 DRC，CDL 修了 VDD/VSS PAD 二極體方向，
#   DRC runset 把 M9.W.2 改回設計規則手冊的 10 um。理由見 fix_io_lib.py 檔頭。
set IO_FIX_DIR    $RUNS/iofix
set IO_GDS_FIXED  $IO_FIX_DIR/saed32_stdio_wb_fixed.gds
set IO_CDL_FIXED  $IO_FIX_DIR/saedio_std_wb_fixed.cdl
set DRC_RS_FIXED  $IO_FIX_DIR/drc_rules_fixed.rs
set IO_LEF_FIXED  $IO_FIX_DIR/saed32_io_wb_fixed.lef   ;# 加上 GDS 實際的 M4 電源線（core 電源從這裡接）
set CHIP_V    $PAD_DIR/${CHIP_TOP}.v        ;# 純結構 wrapper（RTL 模擬、DC、Formality 讀這份）
set PAD_MODEL $PAD_DIR/io_pad_sim.v         ;# 帶 specify 延遲的 PAD 模擬 model
set TOP       [expr {$USE_PAD ? $CHIP_TOP : $DESIGN}]
set PG_NETS   [expr {$USE_PAD ? {VDD VSS VDDIO VSSIO} : {VDD VSS}}]
set NETLIST  $SYN_DIR/${TOP}_syn.v          ;# PAD 模式含 wrapper 與 PAD 實例
set SVF      $SYN_DIR/${DESIGN}.svf
set NDM_LIB  $APR_DIR/${TOP}.ndm
set ROUTED_V    $APR_DIR/routed.v       ;# 功能／時序用，不含 PG 與 filler
set ROUTED_PG_V $APR_DIR/routed_pg.v    ;# LVS 用，含 PG 與 filler
set ROUTED_GDS  $APR_DIR/routed_full.gds

# 不是每個 shell 都支援這個指令（例如 lm_shell），所以包在 catch 裡
catch {set_host_options -max_cores 4}
