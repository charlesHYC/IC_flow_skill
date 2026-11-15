#!/usr/bin/env bash
# run_stage.sh — 每個階段的統一入口
#   bash scripts/run_stage.sh <stage> [corner]
# 規則：在 runs/<stage>/ 裡執行，log 存 console.log，
#       以「成功標記字串」判定通過（工具 exit 0 不代表驗證通過）。
set -e
export EDA_ENV_QUIET=1
source /.bash_EDA >/dev/null 2>&1
set -uo pipefail
# 工具的 tcl 在 source 子檔時出錯會停在互動提示字元等輸入；stdin 接 /dev/null 讓它直接結束
exec </dev/null

PROJ=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
S="$PROJ/scripts"
stage=${1:?Usage: run_stage.sh status|pad|rtl_sim|synthesis|formality|sta|gate_sim|pad|ndm|apr|eco|finish|drc_patch|drc|lvs|starrc|pt_post|fm_post|signoff_eco|gate_post}
corner=${2:-}
# USE_PAD：flow_config.tcl 的設定，環境變數可覆蓋；tcl 也讀同一個環境變數
export USE_PAD=${USE_PAD:-$(sed -n 's/^set USE_PAD \([01]\).*/\1/p' "$S/flow_config.tcl")}
cfg() { sed -n "s/^ *set $1 *\([A-Za-z0-9_]*\).*/\1/p" "$S/flow_config.tcl" | head -1; }

# 終端機流程表格：bash scripts/run_stage.sh status（不執行任何工具）
if [ "$stage" = status ]; then python3 "$S/flow_dashboard.py" "$PROJ" --text; exit 0; fi

out="$PROJ/runs/$stage${corner:+_$corner}"
mkdir -p "$out/reports"
cd "$out"

# 儀表板用：每個階段寫 status.txt（RUNNING → PASS／FAIL／PAD_LIMITED／SKIP），
# 並在 runs/stage_history.log 記一筆；結束後重新產生 runs/dashboard.html
t0=$(date +%s); SKIPPED=0
echo "RUNNING $t0" > "$out/status.txt"
record() {
  rc=$?; res=FAIL
  if [ "$SKIPPED" = 1 ]; then res=SKIP
  elif [ $rc = 0 ]; then
    res=PASS
    grep -qs '^[A-Z]*_PAD_LIMITED' "$out/console.log" && res=PAD_LIMITED
  fi
  echo "$res $t0 $(( $(date +%s) - t0 ))" > "$out/status.txt"
  echo "$stage $res $t0 $(( $(date +%s) - t0 ))" >> "$PROJ/runs/stage_history.log"
  echo "USE_PAD=$USE_PAD" > "$PROJ/runs/flow_mode.txt"   # 這一輪實際用的模式（環境變數可能覆蓋 config）
  python3 "$S/flow_dashboard.py" "$PROJ" > /dev/null 2>&1 || true
}
trap record EXIT

# bash 階段：同時印到螢幕與 console.log，讓最後的成功標記檢查找得到
# 工具失敗（exit 1）時不能讓 set -e 直接結束：要走到最後的標記檢查，印出 FAIL 訊息
run_sh() { bash "$1" 2>&1 | tee console.log || true; }

# 本機 ICV / Formality 會與系統 Kerberos 函式庫衝突，需預載系統版本
krb_fix() { export LD_PRELOAD=/usr/lib64/libkrb5support.so.0:/lib64/libk5crypto.so.3; }

case "$stage" in
  rtl_sim)   run_sh "$S/run_rtl_sim.sh";                         marker='ALL PASS' ;;
  synthesis) dc_shell -f "$S/dc_syn.tcl" > console.log 2>&1 || true;   marker=DC_PASS ;;
  formality) krb_fix; fm_shell -f "$S/fm_rtl2gate.tcl" > console.log 2>&1 || true; marker=FM_PASS ;;
  sta)       bad=0   # 每個 corner 都跑完再判定，報告才完整
             for c in ${corner:-slow typical fast}; do
               FLOW_CORNER=$c pt_shell -f "$S/pt_prelayout.tcl" > console_$c.log 2>&1 || true   # set -e 下不能讓單一 corner 中斷
               grep -q "STA_PASS $c" console_$c.log || { echo "STA FAIL $c"; bad=1; }
             done; [ $bad = 0 ] && echo "STA PASS"; exit $bad ;;
  gate_sim)  run_sh "$S/run_gate_sim.sh";                        marker='GATE_SIM_PASS' ;;
  gate_post) export POSTROUTE=1; run_sh "$S/run_gate_sim.sh";           marker='GATE_SIM_PASS' ;;
  pad)       [ "$USE_PAD" = 1 ] || { SKIPPED=1; echo "pad: USE_PAD=0, nothing to do"; echo "pad SKIP"; exit 0; }
             # 第 0 步（RTL 模擬之前）：從 RTL port 產生晶片 wrapper，並從 IO library 的
             # NLDM 表查出 PAD 延遲，寫成帶 specify 的 PAD 模擬 model
             eval "$(tclsh <<EOF
source $S/flow_config.tcl
puts "DESIGN=\$DESIGN IN_PAD=\$IN_PAD OUT_PAD=\$OUT_PAD RTL_FILES='\$RTL_FILES'"
puts "IO_LIB=\$IO_DB_DIR/[dict get \$CORNERS \$PAD_SIM_CORNER io].lib PAD_MODEL=\$PAD_MODEL"
puts "PAD_ARGS='\$PAD_IN_TRAN \$PAD_IN_LOAD \$PAD_OUT_TRAN \$PAD_OUT_LOAD'"
EOF
)"
             { python3 "$S/pad_tools.py" wrapper "$DESIGN" "$out" "$IN_PAD" "$OUT_PAD" $RTL_FILES &&
               python3 "$S/pad_tools.py" padmodel "$IO_LIB" "$IN_PAD" "$OUT_PAD" "$PAD_MODEL" $PAD_ARGS &&
               echo PAD_PASS; } 2>&1 | tee console.log || true; marker=PAD_PASS ;;
  ndm)       icc2_lm_shell -f "$S/build_ndm.tcl" > console.log 2>&1 || true; marker=NDM_PASS ;;
  apr)       icc2_shell -f "$S/apr_core.tcl" > console.log 2>&1 || true; marker=APR_ROUTED ;;
  eco)       cd "$PROJ/runs/apr"; icc2_shell -f "$S/apr_eco.tcl" > eco_console.log 2>&1 || true
             grep -q "^APR_PASS" eco_console.log || { echo "ECO FAIL"; exit 1; }; echo "eco PASS"; exit 0 ;;
  drc_patch) cd "$PROJ/runs/apr"; icc2_shell -f "$S/apr_drc_patch.tcl" > drc_patch_console.log 2>&1 || true
             grep -q "^DRC_PATCH_PASS" drc_patch_console.log || { echo "DRC PATCH FAIL"; exit 1; }; echo "drc_patch PASS"; exit 0 ;;
  signoff_eco) cd "$PROJ/runs/apr"; icc2_shell -f "$S/apr_signoff_eco.tcl" > signoff_eco_console.log 2>&1 || true
             grep -q "^SIGNOFF_ECO_PASS" signoff_eco_console.log || { echo "SIGNOFF ECO FAIL"; exit 1; }; echo "signoff_eco PASS"; exit 0 ;;
  finish)    icc2_shell -f "$S/apr_finish.tcl" > console.log 2>&1 || true; marker=FINISH_PASS ;;
  # USE_PAD=1：DRC／LVS 只剩 IO library 的問題時記為 PAD_LIMITED（不是 PASS，但流程繼續）
  drc)       krb_fix; run_sh "$S/run_icv_drc.sh";                marker='DRC_PASS\|DRC_PAD_LIMITED' ;;
  lvs)       krb_fix; run_sh "$S/run_icv_lvs.sh";                marker='LVS_PASS\|LVS_PAD_LIMITED' ;;
  starrc)    run_sh "$S/run_starrc.sh";                          marker='STARRC_PASS' ;;
  pt_post)   bad=0   # 全部 corner 跑完，signoff_eco 才看得到所有違規
             for c in ${corner:-slow typical fast}; do
               FLOW_CORNER=$c pt_shell -f "$S/pt_postroute.tcl" > console_$c.log 2>&1 || true
               grep -q "POSTROUTE_STA_PASS $c" console_$c.log || { echo "POST STA FAIL $c"; bad=1; }
             done; [ $bad = 0 ] && echo "POST STA PASS"; exit $bad ;;
  fm_post)   krb_fix; fm_shell -f "$S/fm_postroute.tcl" > console.log 2>&1 || true; marker=FM_POST_PASS ;;
  *) echo "unknown stage $stage" >&2; exit 2 ;;
esac

[ -f console.log ] && grep -E '^Error' console.log && { echo "tool reported errors"; exit 1; }
# 標記要在行首：工具會把執行過的 tcl 指令印回 log（例如 `puts "DC_PASS"`），只找子字串會誤判
grep -rq "^\($marker\)" . || { echo "FAIL: marker '$marker' not found in $out"; exit 1; }
if [ -f console.log ] && grep -q '^[A-Z]*_PAD_LIMITED' console.log; then echo "$stage PAD_LIMITED"; exit 0; fi
echo "$stage PASS"
