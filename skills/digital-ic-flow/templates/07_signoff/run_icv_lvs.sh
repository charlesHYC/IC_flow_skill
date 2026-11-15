#!/usr/bin/env bash
# run_icv_lvs.sh — 階段 7b：IC Validator LVS（layout GDS vs schematic）
# 來源：REFRACT run_icv_lvs_50ff.sh（電晶體 LVS PASS，74,309 devices）
# 流程：Verilog(含 PG) + cell CDL --icv_nettran--> SPICE schematic --icv--> 比對
# USE_PAD=1：top 是晶片 wrapper，CDL 加上 IO library。SAED32 io_std 的 PAD PG pin
#   LEF/GDS 不一致，全晶片 LVS 一定 FAIL（VDD/VSS/VDDIO/VSSIO open）。判定方式：
#     PASS → LVS_PASS；FAIL 但只有 PG net 的問題 → LVS_PAD_LIMITED；有訊號 net 問題 → FAIL
set -eo pipefail
source /.bash_EDA >/dev/null 2>&1
export LD_PRELOAD=/usr/lib64/libkrb5support.so.0
PROJ=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
USE_PAD=${USE_PAD:-$(sed -n 's/^set USE_PAD \([01]\).*/\1/p' "$PROJ/scripts/flow_config.tcl")}

# ---------- 依設計修改 ----------
DESIGN=geofence
PDK=/mnt/nfs/opt/PROCESS/SAED32_EDK
GDS=$PROJ/runs/apr/routed_full.gds
NETLIST_PG=$PROJ/runs/apr/routed_pg.v          # 一定要含 PG 與 filler 的版本
CDL=$PDK/lib/stdcell_rvt/lvs/saed32nm_rvt.cdl
IO_CDL=$PDK/lib/io_std/lvs/saedio_std_wb.cdl
RUNSET=lvs_local.rs
export SAED32_PATH=$PDK
# --------------------------------
TOP=$DESIGN; CDLS=$CDL
[ "$USE_PAD" = 1 ] && { TOP=${DESIGN}_chip; CDLS="$CDL $IO_CDL"; }

# PDK 原始 runset 是範例設定（CELLNAME.gds / resistor），需要專案副本；原 PDK 不動
bash "$PROJ/scripts/make_lvs_runset.sh" "$TOP" "$GDS" "$RUNSET"

# 新版 icv_nettran 已預設輸出 $PINS，不要加舊選項 -sp-dollarPins
icv_nettran -outType SPICE -verilog "$NETLIST_PG" -sp $CDLS -outName schematic.sp > nettran.log 2>&1
icv -vue -i "$GDS" -c "$TOP" -s schematic.sp -stc "$TOP" -sf SPICE -host_init 2 "$RUNSET" > icv_lvs.log 2>&1 || true
if grep -q 'Final comparison result:PASS' "$TOP.LVS_ERRORS"; then echo "LVS_PASS"; exit 0; fi
[ "$USE_PAD" = 1 ] || { echo "LVS FAIL: see $TOP.LVS_ERRORS"; exit 1; }
# PAD 模式：先確認 LVS 有跑到比對（不是 runset / nettran 錯誤），再看問題是不是只在 PG net
grep -q 'Final comparison result' "$TOP.LVS_ERRORS" || { echo "LVS FAIL: comparison did not run"; exit 1; }
python3 "$PROJ/scripts/lvs_pad_classify.py" "$TOP.LVS_ERRORS"
