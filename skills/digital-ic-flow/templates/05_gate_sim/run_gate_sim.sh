#!/usr/bin/env bash
# run_gate_sim.sh — 階段 5：閘級模擬（netlist + SDF 延遲）
# 來源：geofence scripts/run_gate.sh（CBDK）與 scripts/saed32/gate.py（SAED32 三 corner）
# 比賽 A 級要求：所有 pattern 在 gate-level + SDF 下結果正確。
# 兩種模式：
#   （預設）       合成 netlist + 佈局前 SDF（階段 5）
#   POSTROUTE=1    繞線後 netlist + PT（StarRC RC）寫出的 SDF（階段 9c）
# USE_PAD=1：兩種模式都模擬晶片 top（合成 netlist 已含 wrapper 與 PAD 實例），
#   PAD 用 pad 階段產生的帶 specify model（runs/pad/io_pad_sim.v），SDF 的 PAD IOPATH 會註入進去，
#   所以 PAD 延遲是 PT 依實際負載算出的值；繞線後的含 PG netlist 先用 pad_tools.py simnet 處理
set -euo pipefail
PROJ=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
USE_PAD=${USE_PAD:-$(sed -n 's/^set USE_PAD \([01]\).*/\1/p' "$PROJ/scripts/flow_config.tcl")}

# ---------- 依設計修改 ----------
DESIGN=geofence
TB=$PROJ/tb/tb.sv
TOP=testfixture
PATTERNS="$PROJ/patterns/univ.data"
PASS_MARKER='ALL PASS'
FAIL_MARKER=''                     # tb 失敗字串（regex，例 'FAIL:'）；留空不檢查
SIM_CASES=""                       # 同 run_rtl_sim.sh：例 "RI=2 ... RI=15"，每個 case 各跑一次（並行）
TOP_V=$DESIGN; [ "$USE_PAD" = 1 ] && TOP_V=${DESIGN}_chip
NETLIST=$PROJ/runs/synthesis/${TOP_V}_syn.v
# CBDK：SDF 來自 DC；SAED32：用 PT 各 corner 寫出的 SDF
CELL_MODEL=/mnt/nfs/opt/PROCESS/SAED32_EDK/lib/stdcell_rvt/verilog/saed32nm.v
#CELL_MODEL=/mnt/nfs/opt/PROCESS/CBDK_IC_Contest_v2.5/Verilog/tsmc13_neg.v
IO_MODEL=/mnt/nfs/opt/PROCESS/SAED32_EDK/lib/io_std/verilog/saed32nm_io_wb.v
CASES="slow:max fast:min"          # corner:delay 組合；slow 看 setup、fast 看 hold
# --------------------------------

# 晶片模式：tb 的副本把 `<DESIGN> u_xxx(` 換成 `<DESIGN>_chip u_xxx(`（port 名稱相同，原 tb 不動）
chip_tb() {
  sed -E "s/^([[:space:]]*)${DESIGN}([[:space:]]+[A-Za-z_])/\1${DESIGN}_chip\2/" "$TB" > tb_chip.sv
  grep -q "${DESIGN}_chip" tb_chip.sv || { echo "cannot find '$DESIGN <inst>(' in $TB"; exit 1; }
  echo tb_chip.sv
}

PAD_MODEL=$PROJ/runs/pad/io_pad_sim.v
if [ "$USE_PAD" = 1 ]; then [ -f "$PAD_MODEL" ] || { echo "missing $PAD_MODEL: run the pad stage first"; exit 1; }; fi

# 一個 case：在目前目錄（已備好 netlist／SDF）編譯並執行，檢查功能、SDF 註入與 timing check
run_case() {   # $1 = case（"default" 或 define，例 RI=5）$2 = delay（max/min）
  local c=$1 delay=$2 def=""
  [ "$c" = default ] || def="+define+$c"
  for p in $PATTERNS; do cp -r "$p" .; done
  # +sdfverbose：列出全部 SDF warning（預設只印前 10 個），下面才能逐一檢查
  vcs -full64 -sverilog -debug_access+r +neg_tchk +${delay}delays +sdfverbose \
      "$tb" "$NETLIST" -v "$CELL_MODEL" $extra +define+SDF $def -top "$TOP" \
      -o simv -l compile.log > build.log 2>&1 || return 1
  ./simv -l run.log > /dev/null 2>&1 || true
  grep -qF "$PASS_MARKER" run.log || return 1
  [ -z "$FAIL_MARKER" ] || ! grep -Eq "$FAIL_MARKER" run.log || return 1
  # SDF 必須完整註入，且不能有 timing check 違規
  grep -Eq 'Total errors:\s+0' compile.log run.log || { echo "SDF annotation errors"; return 1; }
  ! grep -Eiq 'timing violation|\$setuphold|\$recrem|\$width|Error-\[' run.log || return 1
  # SDF warning 逐一分類，只容許已知的一種，其他一律失敗：
  #   SDFCOM_CFTC $removal：SAED32 cell model 沒有 removal check（見 pitfalls，geofence 每次 17 個）
  # PAD 的 IOPATH 必須註入成功（PAD model 有 specify），所以 PAD 上的 SDFCOM_IANE 也算失敗
  awk '/^Warning-\[SDFCOM/{w=$0; getline; getline m; getline d; print w "|" m "|" d}' compile.log > sdf_warnings.txt
  n_rem=$(grep -c 'SDFCOM_CFTC.*removal' sdf_warnings.txt || true)
  n_all=$(wc -l < sdf_warnings.txt)
  [ "$n_all" = "$n_rem" ] || { echo "unexpected SDF warnings: $((n_all - n_rem))"; return 1; }
  echo "$n_rem" > removal_count
}

bad=0
for c in $CASES; do
  corner=${c%%:*}; delay=${c##*:}
  w="$PWD/run_${corner}_${delay}"; mkdir -p "$w"; cd "$w"
  tb=$TB; extra=""
  [ "$USE_PAD" = 1 ] && { tb=$PWD/$(chip_tb); extra="$PAD_MODEL -v $IO_MODEL"; }
  if [ "${POSTROUTE:-0}" = 1 ]; then
    NETLIST=$PROJ/runs/apr/routed.v
    sdf=$PROJ/runs/pt_post/${DESIGN}_postroute_${corner}.sdf
    if [ "$USE_PAD" = 1 ]; then
      # 含 PG 的 netlist（PAD 的 PG 連線保留）；std cell model 沒有 PG port，simnet 拿掉它們
      python3 "$PROJ/scripts/pad_tools.py" simnet "$PROJ/runs/apr/routed_pg.v" "${DESIGN}_chip" chip_sim.v
      NETLIST=$PWD/chip_sim.v
    fi
  else
    sdf=$PROJ/runs/sta/${DESIGN}_${corner}.sdf
    [ -f "$sdf" ] || sdf=$PROJ/runs/synthesis/${TOP_V}_syn.sdf
  fi
  [ -f "$sdf" ] || { echo "missing SDF $sdf"; exit 1; }
  # 每個 case 一個子目錄，並行跑；官方 tb 以 `define SDFFILE "./<design>_syn.sdf" 讀 SDF，複製成固定名字
  for k in ${SIM_CASES:-default}; do
    d="case_${k//[^A-Za-z0-9_]/_}"; mkdir -p "$d"; cp "$sdf" "$d/${DESIGN}_syn.sdf"
    ( cd "$d"; if run_case "$k" "$delay" > case.log 2>&1; then echo PASS > result; else echo FAIL > result; fi ) &
  done
  wait
  for k in ${SIM_CASES:-default}; do
    d="case_${k//[^A-Za-z0-9_]/_}"
    if [ "$(cat "$d/result")" = PASS ]; then
      echo "gate $corner $delay $k PASS (removal-check warnings=$(cat "$d/removal_count"))"
    else
      echo "gate $corner $delay $k FAIL (see $w/$d)"; bad=1
    fi
  done
  echo "SDF_NOTE $corner: removal-check warnings=$(cat case_*/removal_count 2>/dev/null | sort -u | tr '\n' ' ')"
  cd ..
done
[ $bad = 0 ] || exit 1
echo "GATE_SIM_PASS"
