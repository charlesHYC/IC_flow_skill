#!/usr/bin/env bash
# run_icv_drc.sh — 階段 7a：IC Validator DRC（完整 GDS，含標準元件電晶體幾何）
# USE_PAD=1：top 是晶片 wrapper，GDS merge 的是 fix_io_lib.py 修正過的 IO library，
#   runset 用修正版（M9.W.2 改回手冊的 10 um）。判定和核心一樣：RESULTS: CLEAN 才算過。
set -eo pipefail
source /.bash_EDA >/dev/null 2>&1
# ICV 與系統 Kerberos 函式庫衝突，預載系統版本才能啟動
export LD_PRELOAD=/usr/lib64/libkrb5support.so.0
PROJ=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
USE_PAD=${USE_PAD:-$(sed -n 's/^set USE_PAD \([01]\).*/\1/p' "$PROJ/scripts/flow_config.tcl")}

# ---------- 依設計修改 ----------
DESIGN=$(sed -n 's/^set DESIGN *\([A-Za-z0-9_]*\).*/\1/p' "$PROJ/scripts/flow_config.tcl")   # top 名稱：從 flow_config.tcl 讀，不在這裡改
GDS=$PROJ/runs/apr/routed_full.gds
RUNSET=/mnt/nfs/opt/PROCESS/SAED32_EDK/tech/icv_drc/saed32nm_1p9m_drc_rules.rs
# --------------------------------
TOP=$DESIGN; [ "$USE_PAD" = 1 ] && { TOP=${DESIGN}_chip; RUNSET=$PROJ/runs/iofix/drc_rules_fixed.rs; }   # M9.W.2 改回 10 um（fix_io_lib.py）

rm -f "$TOP.RESULTS" "$TOP.LAYOUT_ERRORS"   # 先刪掉上一次的結果：ICV 中途出錯時才不會讀到舊檔
icv -vue -i "$GDS" -c "$TOP" -host_init 2 "$RUNSET" > icv_drc.log 2>&1 || true
# 也記下有沒有規則沒被執行（NOT EXECUTED），回報時要說明
echo "NOT EXECUTED rules: $(grep -c 'NOT EXECUTED' "$TOP.RESULTS" || true)"
# 程序結束不代表 CLEAN，要讀結果檔
if grep -Eq '^[[:space:]]*RESULTS: CLEAN' "$TOP.RESULTS"; then echo "DRC_PASS"; exit 0; fi
echo "DRC FAIL: see $PWD/$TOP.RESULTS / $TOP.LAYOUT_ERRORS"
# PAD 模式另外依位置把錯誤分成 IO ring 內／核心區（只是診斷，不改變判定）
if [ "$USE_PAD" = 1 ]; then
    python3 "$PROJ/scripts/drc_pad_classify.py" "$TOP.LAYOUT_ERRORS" "$PROJ/runs/apr/pad_geometry.txt" || true
fi
exit 1
