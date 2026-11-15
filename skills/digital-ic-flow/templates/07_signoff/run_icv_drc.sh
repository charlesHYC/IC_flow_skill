#!/usr/bin/env bash
# run_icv_drc.sh — 階段 7a：IC Validator DRC（完整 GDS，含標準元件電晶體幾何）
# 來源：REFRACT run_icv_drc_50ff.sh（404 rules 全執行，CLEAN）
# USE_PAD=1：top 是晶片 wrapper，GDS 也 merge 了 IO library。SAED32 io_std 的 PAD
#   GDS 本身就有 DRC 錯誤，所以結果分成兩類（依錯誤框位置）：
#     IO ring 內（PAD 所在的外圈帶）→ library 限制，記為 PAD_LIMITED
#     核心＋PAD 與核心之間（自己畫的 ring、接線、繞線）→ 一律 FAIL
set -eo pipefail
source /.bash_EDA >/dev/null 2>&1
# ICV 與系統 Kerberos 函式庫衝突，預載系統版本才能啟動
export LD_PRELOAD=/usr/lib64/libkrb5support.so.0
PROJ=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
USE_PAD=${USE_PAD:-$(sed -n 's/^set USE_PAD \([01]\).*/\1/p' "$PROJ/scripts/flow_config.tcl")}

# ---------- 依設計修改 ----------
DESIGN=geofence
GDS=$PROJ/runs/apr/routed_full.gds
RUNSET=/mnt/nfs/opt/PROCESS/SAED32_EDK/tech/icv_drc/saed32nm_1p9m_drc_rules.rs
# --------------------------------
TOP=$DESIGN; [ "$USE_PAD" = 1 ] && TOP=${DESIGN}_chip

icv -vue -i "$GDS" -c "$TOP" -host_init 2 "$RUNSET" > icv_drc.log 2>&1 || true
# 也記下有沒有規則沒被執行（NOT EXECUTED），回報時要說明
echo "NOT EXECUTED rules: $(grep -c 'NOT EXECUTED' "$TOP.RESULTS" || true)"
# 程序結束不代表 CLEAN，要讀結果檔
if grep -Eq '^[[:space:]]*RESULTS: CLEAN' "$TOP.RESULTS"; then echo "DRC_PASS"; exit 0; fi
[ "$USE_PAD" = 1 ] || { echo "DRC FAIL: see $TOP.RESULTS / $TOP.LAYOUT_ERRORS"; exit 1; }

# PAD 模式：依 pad_geometry.txt（apr_pad_ring.tcl 寫出：die、PAD 高度、自己畫的接線框）分類
python3 "$PROJ/scripts/drc_pad_classify.py" "$TOP.LAYOUT_ERRORS" "$PROJ/runs/apr/pad_geometry.txt"
