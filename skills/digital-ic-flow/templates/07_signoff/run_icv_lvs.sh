#!/usr/bin/env bash
# run_icv_lvs.sh — 階段 7b：IC Validator LVS（layout GDS vs schematic）
# 流程：Verilog(含 PG) + cell CDL --icv_nettran--> SPICE schematic --icv--> 比對
# USE_PAD=1：top 是晶片 wrapper，CDL 用 fix_io_lib.py 修正過的 IO library；
#   schematic 的 VSSIO 併到 VSS（共用 P 基板，見下方說明）。判定和核心一樣：PASS 才算過。
set -eo pipefail
source /.bash_EDA >/dev/null 2>&1
export LD_PRELOAD=/usr/lib64/libkrb5support.so.0
PROJ=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
USE_PAD=${USE_PAD:-$(sed -n 's/^set USE_PAD \([01]\).*/\1/p' "$PROJ/scripts/flow_config.tcl")}

# ---------- 依設計修改 ----------
DESIGN=$(sed -n 's/^set DESIGN *\([A-Za-z0-9_]*\).*/\1/p' "$PROJ/scripts/flow_config.tcl")   # top 名稱：從 flow_config.tcl 讀，不在這裡改
PDK=/mnt/nfs/opt/PROCESS/SAED32_EDK
GDS=$PROJ/runs/apr/routed_full.gds
NETLIST_PG=$PROJ/runs/apr/routed_pg.v          # 一定要含 PG 與 filler 的版本
CDL=$PDK/lib/stdcell_rvt/lvs/saed32nm_rvt.cdl
IO_CDL=$PROJ/runs/iofix/saedio_std_wb_fixed.cdl   # 修正版（fix_io_lib.py）：VDD/VSS PAD 二極體方向
RUNSET=lvs_local.rs
export SAED32_PATH=$PDK
# --------------------------------
TOP=$DESIGN; CDLS=$CDL
[ "$USE_PAD" = 1 ] && { TOP=${DESIGN}_chip; CDLS="$CDL $IO_CDL"; }

# PDK 原始 runset 是範例設定（CELLNAME.gds / resistor），需要專案副本；原 PDK 不動
bash "$PROJ/scripts/make_lvs_runset.sh" "$TOP" "$GDS" "$RUNSET"

# 新版 icv_nettran 已預設輸出 $PINS，不要加舊選項 -sp-dollarPins
icv_nettran -outType SPICE -verilog "$NETLIST_PG" -sp $CDLS -outName schematic.sp > nettran.log 2>&1
if [ "$USE_PAD" = 1 ]; then
    # VSS 與 VSSIO 在矽片上是同一個節點：SAED32 沒有 deep N-well，核心和 IO 共用一塊 P 型基板，
    # runset 的 pwell = 整顆晶片減掉 nwell，並用 ptap 硬接到 pwell。核心的 VSS tap 和 PAD 的
    # VSSIO tap 都打在這塊基板上，layout 抽出來一定是同一個 net。IO library 的 CDL 把 IO 側
    # NMOS／ESD 二極體的基板寫成 VSSIO、核心側寫成 VSS，放進晶片後兩者對不上。
    # 所以晶片的 schematic 也要把 VSSIO 併到 VSS（VSS PAD 裡 VSSIO→VSS 的 nd 二極體兩端變成
    # 同一個 net，layout 與 schematic 兩邊都會濾掉）。
    # 代價：這樣比對抓不到 VSS 和 VSSIO 之間的金屬短路。
    sed -i 's/\bVSSIO\b/VSS/g' schematic.sp
fi
rm -f "$TOP.LVS_ERRORS" "$TOP.LAYOUT_ERRORS" "$TOP.RESULTS"   # 先刪掉上一次的結果：ICV 中途出錯時才不會讀到舊檔
icv -vue -i "$GDS" -c "$TOP" -s schematic.sp -stc "$TOP" -sf SPICE -host_init 2 "$RUNSET" > icv_lvs.log 2>&1 || true
if grep -q 'Final comparison result:PASS' "$TOP.LVS_ERRORS"; then echo "LVS_PASS"; exit 0; fi
echo "LVS FAIL: see $PWD/$TOP.LVS_ERRORS"
# PAD 模式另外印出元件／net 分類，幫忙看問題在核心還是 PAD（只是診斷，不改變判定）
if [ "$USE_PAD" = 1 ] && grep -q 'Final comparison result' "$TOP.LVS_ERRORS"; then
    python3 "$PROJ/scripts/lvs_pad_classify.py" "$TOP.LVS_ERRORS" > lvs_classified.rpt 2>&1 || true
    cat lvs_classified.rpt
fi
exit 1
