#!/usr/bin/env bash
# run_all.sh — 一個指令跑完整流程（含 eco / drc_patch / signoff_eco 三個修正回圈）
#   bash scripts/run_all.sh            # 在專案目錄外也可以：bash <proj>/scripts/run_all.sh
# USE_PAD=1 時第一步先跑 pad 階段（wrapper＋帶延遲的 PAD model），之後每個階段都以晶片 top 進行；DRC/LVS 若只剩 IO library 的問題會記為 PAD_LIMITED 並繼續，
# 結尾印 ALL_STAGES_DONE_PAD_LIMITED（不是 PASS）。
# 2026-11-11 以這支腳本在乾淨目錄跑 geofence（SAED32，USE_PAD=0）：ALL_STAGES_PASS，約 24 分鐘。
cd "${1:-$(dirname -- "${BASH_SOURCE[0]}")/..}"; set -o pipefail
# 新的一輪：清掉上一輪的階段歷史（儀表板的「執行次數」只算這一輪）；結束時（含中途 STOP）更新儀表板
mkdir -p runs; : > runs/stage_history.log
exec > >(tee runs/run_all.log) 2>&1     # 儀表板也讀這份（沒有 status.txt 的階段用它判斷）
# 結束時（含中途 STOP）在終端機印出流程表格，並更新 runs/dashboard.html
trap 'python3 scripts/flow_dashboard.py . --text' EXIT
st() { echo "=== $1 $(date +%T)"; timeout 5400 bash scripts/run_stage.sh "$1" 2>&1 | tail -3; }
for s in pad rtl_sim synthesis formality sta gate_sim ndm apr eco finish; do st $s || { echo "STOP at $s"; exit 1; }; done
if ! st drc; then st drc_patch && st finish && st drc || { echo STOP-DRC; exit 1; }; fi
st lvs && st starrc || { echo STOP; exit 1; }
for it in 1 2 3 4; do
  if st pt_post; then echo "SIGNOFF CLOSED after $((it-1)) signoff_eco loop(s)"; break; fi
  [ $it = 4 ] && { echo "STOP: not closed"; exit 1; }
  st signoff_eco && st finish || { echo STOP; exit 1; }
  if ! st drc; then st drc_patch && st finish && st drc || { echo STOP-DRC; exit 1; }; fi
  st lvs && st starrc || { echo STOP; exit 1; }
done
st fm_post && st gate_post || { echo STOP; exit 1; }
if grep -qs '^[A-Z]*_PAD_LIMITED' runs/drc/console.log runs/lvs/console.log; then
  echo "ALL_STAGES_DONE_PAD_LIMITED"
  grep -h 'DRC_CLASSIFY\|_PAD_LIMITED' runs/drc/console.log runs/lvs/console.log
else
  echo "ALL_STAGES_PASS"
fi
grep -h "DC_SLACK" runs/synthesis/console.log | grep -v puts
grep -h "STA_SLACK" runs/sta/console_*.log | grep -v puts
grep -h "POSTROUTE_SLACK" runs/pt_post/console_*.log | grep -v puts
grep -h "ECO inserted\|ECO buffer\|ECO upsize" runs/apr/eco_console.log | grep -v puts
grep -h "^PATCH\|DRC_PATCH:" runs/apr/drc_patch_console.log 2>/dev/null | grep -v puts
grep -h "^SIZE\|^BUFFER" runs/apr/signoff_eco_console.log 2>/dev/null
grep -h "PG_FIX" runs/apr/console.log | grep -v puts
