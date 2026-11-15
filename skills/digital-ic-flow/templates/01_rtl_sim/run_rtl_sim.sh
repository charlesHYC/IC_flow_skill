#!/usr/bin/env bash
# run_rtl_sim.sh — 階段 1：VCS RTL 模擬（來源：geofence scripts/run_sim.sh、REFRACT vcs.cmd）
# 在 runs/rtl_sim/ 內被 run_stage.sh 呼叫；也可單獨執行。
# USE_PAD=1：模擬晶片 top（pad 階段產生的 wrapper＋RTL＋帶 specify 延遲的 PAD model），
#   tb 用副本把 `<DESIGN> u_xxx(` 換成 `<DESIGN>_chip u_xxx(`（port 名稱相同，原 tb 不動）。
#   PAD 延遲（slow corner，input 約 0.4 ns、output 推 1 pF 約 1.3 ns）因此在 RTL 階段就看得到：
#   tb 的取樣時間點若太貼近輸出變化，這裡就會失敗，不會等到閘級模擬才發現。
# SIM_CASES：同一個 tb 要用不同 define 跑好幾次時（REFRACT 的 RI=2..15），每個 case 各自
#   編譯、執行，放在 run_<case>/，全部 PASS 才算通過。留空 = 只跑一次。
set -euo pipefail
PROJ=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
USE_PAD=${USE_PAD:-$(sed -n 's/^set USE_PAD \([01]\).*/\1/p' "$PROJ/scripts/flow_config.tcl")}

# ---------- 依設計修改 ----------
TB=$PROJ/tb/tb.sv                 # 官方 testbench
TOP=testfixture                   # tb 的 top module 名稱
RTL=$PROJ/rtl/geofence.v
PATTERNS="$PROJ/patterns/univ.data"   # tb 以相對路徑讀的測資（檔案或目錄），複製到執行目錄
PASS_MARKER='ALL PASS'            # tb 成功時印出的字串
FAIL_MARKER=''                    # tb 失敗時印出的字串（regex，例 'FAIL:'）；留空不檢查
SIM_CASES=""                      # 例："RI=2 RI=3 ... RI=15"，每個 case 加 +define+<case> 跑一次
DESIGN=geofence                   # RTL top（USE_PAD=1 時 tb 改接 ${DESIGN}_chip）
IO_MODEL=/mnt/nfs/opt/PROCESS/SAED32_EDK/lib/io_std/verilog/saed32nm_io_wb.v
# DesignWare 元件需加：-y $SYNOPSYS/dw/sim_ver +libext+.v
# --------------------------------

TB_USE=$TB
SRC_EXTRA=""
if [ "$USE_PAD" = 1 ]; then
  PAD=$PROJ/runs/pad
  [ -f "$PAD/${DESIGN}_chip.v" ] || { echo "run the pad stage first (missing $PAD/${DESIGN}_chip.v)"; exit 1; }
  sed -E "s/^([[:space:]]*)${DESIGN}([[:space:]]+[A-Za-z_])/\1${DESIGN}_chip\2/" "$TB" > tb_chip.sv
  grep -q "${DESIGN}_chip" tb_chip.sv || { echo "cannot find '$DESIGN <inst>(' in $TB"; exit 1; }
  TB_USE=$PWD/tb_chip.sv
  # PAD model 定義 PAD cell（含延遲），-v 只補它用到的官方 RECEIVER／DRIVER
  SRC_EXTRA="$PAD/${DESIGN}_chip.v $PAD/io_pad_sim.v -v $IO_MODEL"
  grep -h '^// delays\|^//   ' "$PAD/io_pad_sim.v"
fi

bad=0
for c in ${SIM_CASES:-default}; do
  w=run_${c//[^A-Za-z0-9_]/_}; mkdir -p "$w"
  ( cd "$w"
    for p in $PATTERNS; do cp -r "$p" .; done
    def=""; [ "$c" = default ] || def="+define+$c"
    vcs -full64 -sverilog -debug_access+r -timescale=1ns/10ps \
        "$TB_USE" $SRC_EXTRA $RTL $def -top "$TOP" -o simv -l compile.log > build.log 2>&1 || true
    ./simv -l simulation.log > run.log 2>&1 || true
    # 有些模擬器遇到 $fatal 仍回傳 0，所以一定要找成功字串，也要沒有失敗字串
    grep -qF "$PASS_MARKER" run.log || exit 1
    [ -z "$FAIL_MARKER" ] || ! grep -Eq "$FAIL_MARKER" run.log || exit 1
    ! grep -Eq 'Error-\[|Fatal' compile.log run.log
  ) && echo "rtl $c PASS" || { echo "rtl $c FAIL (see $w/run.log)"; bad=1; }
done
[ $bad = 0 ] || exit 1
echo "ALL PASS"
