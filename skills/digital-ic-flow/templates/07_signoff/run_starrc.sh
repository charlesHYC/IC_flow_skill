#!/usr/bin/env bash
# run_starrc.sh — 階段 8：StarRC 寄生萃取（每個 RC corner 一份 SPEF）
# corner 對應：slow -> Cmax、typical -> nominal、fast -> Cmin（與 APR 的 TLU+ 一致）
set -eo pipefail
source /.bash_EDA >/dev/null 2>&1
PROJ=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
USE_PAD=${USE_PAD:-$(sed -n 's/^set USE_PAD \([01]\).*/\1/p' "$PROJ/scripts/flow_config.tcl")}

# ---------- 依設計修改 ----------
DESIGN=$(sed -n 's/^set DESIGN *\([A-Za-z0-9_]*\).*/\1/p' "$PROJ/scripts/flow_config.tcl")   # top 名稱：從 flow_config.tcl 讀，不在這裡改
BLOCK=routed
RC_DIR=/mnt/nfs/opt/PROCESS/SAED32_EDK/tech/star_rcxt
# /.bash_EDA 沒有把 StarRC 放進 PATH，用絕對路徑
STARXTRACT=${STARXTRACT:-/mnt/nfs/opt/EDA/synopsys/star-rcxt/cur/bin/StarXtract}
# --------------------------------
TOP=$DESIGN; PG="VDD VSS"
[ "$USE_PAD" = 1 ] && { TOP=${DESIGN}_chip; PG="VDD VSS VDDIO VSSIO"; }
NDM=$PROJ/runs/apr/$TOP.ndm

for corner in slow typical fast; do
  case "$corner" in slow) rc=Cmax;; typical) rc=nominal;; fast) rc=Cmin;; esac
  mkdir -p "$corner"
  cat > "$corner/extract.cmd" <<CMD
BLOCK: $BLOCK
NDM_DATABASE: $NDM
TCAD_GRD_FILE: $RC_DIR/saed32nm_1p9m_${rc}.nxtgrd
MAPPING_FILE: $RC_DIR/saed32nm_tf_itf_tluplus.map
EXTRACTION: RC
NETS: *
POWER_NETS: $PG
COUPLE_TO_GROUND: NO
NETLIST_FORMAT: SPEF
NETLIST_FILE: $TOP.spef
CMD
  # 注意：未指定 OPERATING_TEMPERATURE 時金屬溫度用預設 25C，回報時要說明
  (cd "$corner" && "$STARXTRACT" extract.cmd > extract.log 2>&1)
  test -s "$corner/$TOP.spef" || { echo "StarRC failed for $corner"; exit 1; }
  echo "SPEF $corner OK"
done
echo "STARRC_PASS"
