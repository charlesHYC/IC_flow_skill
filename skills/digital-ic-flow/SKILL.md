---
name: digital-ic-flow
description: Digital IC (cell-based) RTL-to-GDS design flow guide with ready-to-fill Synopsys .tcl/.sh templates for every stage — VCS RTL sim, Design Compiler synthesis + SDC, Formality, PrimeTime, gate-level SDF sim, IC Compiler II APR (floorplan/power/place/CTS/route/finish), ICV DRC/LVS, StarRC PEX and post-route STA/sim. A teaching template for any cell-based design: learners copy it and edit each stage's script, with design-dependent values in flow_config.tcl and per-script header blocks; verified on example designs with SAED32 (CBDK_IC_Contest branch included). Use this skill whenever the user asks how the digital IC flow works, which stage comes next, what a stage's script should look like, wants a dc_shell / pt_shell / fm_shell / icc2_shell / icv / StarRC script written or reviewed, is starting a new design or IC-contest-style lab (e.g. "幫我把這個設計建成完整流程"), or asks why a synthesis/APR/signoff step fails — even if they don't say "flow" or "template".
---

# Digital IC Design Flow（cell-based，RTL → GDS）

這個 skill 是給任何 cell-based 數位 IC 設計用的教學公版，包含兩件事：

1. **流程知識**：每個階段做什麼、輸入輸出、怎樣才算通過、常見陷阱。
2. **公版腳本**：`templates/` 裡每個階段一份 `.tcl`／`.sh`。學習者把它複製到自己的專案，照自己的設計一個階段一個階段修改：共用的設計資訊（top 名稱、RTL、clock、I/O delay）集中在 `flow_config.tcl`，各階段跟設計有關的值放在該腳本檔頭的「依設計修改」區塊，每個值都註明是什麼、什麼時候要改。腳本目的是讓人看懂每一步並自己調整，不是不改就能跑所有設計的黑盒子。

## 流程總覽

| # | 階段 | 工具 | 主要輸入 | 主要輸出 | 通過依據（看報告，不看 exit code） | 公版 |
|---|---|---|---|---|---|---|
| 0 | 要不要上 PAD（`USE_PAD`） | `pad_tools.py` | RTL port、IO library | `${DESIGN}_chip.v`、帶延遲的 PAD model | 只有 `USE_PAD 1` 才執行；印出 `PAD_DELAY`、`PAD_PASS` | `templates/06_apr/pad_tools.py`（由 `run_stage.sh pad` 呼叫） |
| 1 | RTL 模擬 | VCS（Verdi 看波形） | RTL、tb、pattern | log、VCD/FSDB | tb 印出 PASS 標記，mismatch = 0 | `templates/01_rtl_sim/run_rtl_sim.sh` |
| 2 | 邏輯合成 | Design Compiler | RTL、SDC、.db | netlist .v、.ddc、.sdf、.svf、.sdc | `report_constraint -all_violators` 無時序/DRC 違規、`check_timing` 無 unconstrained | `templates/02_synthesis/dc_syn.tcl` + `constraints.sdc` |
| 3 | Function 驗證 | Formality | RTL、netlist、SVF | match/verify 報告 | `Verification SUCCEEDED`，failing = 0 | `templates/03_formality/fm_rtl2gate.tcl` |
| 4 | 佈局前 STA | PrimeTime | netlist、SDC、多 corner .db | timing 報告、SDF | 每個 corner setup/hold slack ≥ 0、無 VIOLATED | `templates/04_sta/pt_prelayout.tcl` |
| 5 | Gate-level sim | VCS + SDF | netlist、SDF、cell model | log | 功能 PASS、SDF annotation 0 error、warning 只能是已知的 `$removal`、無 timing violation | `templates/05_gate_sim/run_gate_sim.sh` |
| 6 | APR | IC Compiler II | netlist、NDM、tech、TLU+、SDC | routed block、DEF、SPEF(估計)、GDS | `check_routes` 0 DRC/open/short、`check_pg_connectivity` 無浮接、`report_constraints` 無違規 | `templates/06_apr/*.tcl`（route 後再跑 `apr_eco.tcl` 修剩下的 max_cap/transition） |
| 7 | 實體驗證 | IC Validator | GDS、CDL、runset | DRC/LVS 結果 | DRC `RESULTS: CLEAN`、LVS `Final comparison result:PASS` | `templates/07_signoff/run_icv_drc.sh`、`run_icv_lvs.sh` |
| 8 | 寄生萃取 | StarRC | NDM block、nxtgrd | SPEF（每個 RC corner） | SPEF 產生、PT 註入無缺漏 | `templates/07_signoff/run_starrc.sh` |
| 9 | 繞線後 STA／LEC／模擬 | PT、Formality、VCS | routed netlist、SPEF、SDF | 最終報告 | 同 3/4/5 的標準，改用實際 RC | `templates/07_signoff/pt_postroute.tcl`、`fm_postroute.tcl`、`apr_signoff_eco.tcl`；模擬用 `run_gate_sim.sh`（`POSTROUTE=1`） |

比賽（IC Contest）通常只評到第 5 階段（RTL + pre-layout gate-level + 面積×時間）；6–9 是延伸成完整晶片流程。回答時先確認使用者要做到哪一階段、要不要上 PAD（見下一節），不要預設全部都要跑。

## 開始前先問：要不要上 PAD？

**開新設計、寫 RTL 或跑第一次模擬之前，就要先問使用者要不要加 IO PAD**，不要自己決定，也不能等到 APR 才問。原因：PAD 有延遲（SAED32 slow corner：input PAD 約 0.4 ns；output PAD 推 1 pF 約 1.2–1.4 ns），輸出負載也從 20 fF 變成 1 pF。這些從 RTL 模擬就會影響結果，包括 tb 的取樣時間、合成的 I/O 時序預算、STA、Gate-level sim。答案寫進 `flow_config.tcl` 的 `set USE_PAD 0|1`（也可以臨時用 `USE_PAD=1 bash scripts/run_all.sh` 覆蓋）。問的時候要把差別講清楚：

| | `USE_PAD 0`：只做核心（預設） | `USE_PAD 1`：加 PAD 的全晶片 |
|---|---|---|
| 從哪一步開始不同 | — | **第 0 步**：`pad` 階段從 RTL port 產生 `${DESIGN}_chip` wrapper，並從 IO library 查出 PAD 延遲，產生帶 specify 的 PAD 模擬 model |
| 每個階段的 top | `$DESIGN` | `${DESIGN}_chip`（RTL 模擬、合成、Formality、STA、Gate-level sim、APR、signoff 全部） |
| RTL 模擬 | 零延遲 | 核心零延遲＋**PAD 延遲**（預設 slow corner 的值） |
| 合成／STA／Gate-level sim | 核心，20 fF 負載 | 含 PAD，1 pF 板級負載由 output PAD 推（`constraints_chip.sdc`）；SDF 的 PAD 延遲會註入 PAD model |
| die | 依合成面積手動設 `apr_core.tcl` 的 `DIE`（例：cell area 5800 µm² → 240 µm） | 依 PAD 數自動算（例：24 個訊號＋8 個電源 PAD → 920 µm，pad-limited） |
| 電源 | VDD/VSS | VDD/VSS/VDDIO/VSSIO，電源 PAD 的 M4 電源條自動接到 core ring |
| DRC／LVS | CLEAN／PASS | CLEAN／PASS，判定和核心一樣。SAED32 io_std 原檔有錯，pad 階段先用 `fix_io_lib.py` 產生修正版 library；LVS 把 VSSIO 併到 VSS（共用基板，見 pitfalls） |
| 製程 | saed32、cbdk | 只有 saed32（CBDK_IC_Contest_v2.5 沒有 IO PAD library，設了會直接報錯） |

**每次要跑流程前都要問，沒有例外**：開新專案、`run_all.sh`、示範跑、測試跑、重跑，只要會執行流程，就先問使用者一次（工具有選擇題介面時用它，例如 Claude Code 的 AskUserQuestion；沒有就用文字列出選項等使用者回答），不可以沿用上一次的選擇，也不可以自己挑。這個 skill 是教學用的，選項固定三個：

1. 兩種都跑（教學建議）：`USE_PAD 0` 與 `USE_PAD 1` 各一個專案目錄，可以並行。跑完一起回報，對照 PAD 延遲、1 pF 負載、die 大小與 DRC/LVS 結果的差別。
2. 只做核心（`USE_PAD 0`）
3. 上 PAD（`USE_PAD 1`）

PAD 是什麼、製程給什麼、怎麼選、怎麼排、corner pad、怎麼確認用對，見 `references/flow_stages.md` 第 11 節（使用者問 PAD 的流程時照它回答）。SAED32 io_std 原檔的 GDS／CDL／LEF 錯誤和每一項的修法，見 `references/pitfalls.md`「PAD」一節。PAD 模式的 LVS 有一個代價要跟使用者說：VSS 和 VSSIO 在 schematic 裡併成同一個 net，所以這兩者之間的金屬短路抓不到。

**中途改變主意**：改 `USE_PAD` 後要從 `pad` 階段整個重跑（`run_all.sh`），不能只重跑 APR，因為合成 netlist 的 top 不一樣。

## 如何使用公版

把 `templates/*/*` 全部複製到專案的 `scripts/`（同一層）。一次跑完全部：`bash scripts/run_all.sh`；或逐階段執行：

```bash
bash scripts/run_stage.sh pad         # 0  只有 USE_PAD=1：從 RTL 產生 wrapper＋帶延遲的 PAD model（USE_PAD=0 自動略過）
bash scripts/run_stage.sh rtl_sim     # 1  USE_PAD=1 時模擬晶片 top，含 PAD 延遲
bash scripts/run_stage.sh synthesis   # 2
bash scripts/run_stage.sh formality   # 3
bash scripts/run_stage.sh sta         # 4  三個 corner
bash scripts/run_stage.sh gate_sim    # 5
bash scripts/run_stage.sh ndm         # 6-0  USE_PAD=1 時多建 io.ndm
bash scripts/run_stage.sh apr         # 6  floorplan→route（只要求繞線乾淨）
bash scripts/run_stage.sh eco         # 6  修 max_cap/transition，做 APR 最終判定
bash scripts/run_stage.sh finish      # 6  filler、GDS、netlist
bash scripts/run_stage.sh drc         # 7a 若 M1 細條違規：drc_patch → finish → drc
bash scripts/run_stage.sh lvs         # 7b
bash scripts/run_stage.sh starrc      # 8
bash scripts/run_stage.sh pt_post     # 9a 若 StarRC 後仍有小幅 max_cap/transition 超標：
                                      #    signoff_eco → finish → drc → lvs → starrc → pt_post（重複到乾淨）
bash scripts/run_stage.sh fm_post     # 9b
bash scripts/run_stage.sh gate_post   # 9c 繞線後 netlist＋SDF 模擬
```

**終端機流程表格**：`run_all.sh` 結束時（含中途 STOP）會在終端機印出一張表，每一列是一個階段，依流程順序排列：`RTL_coding (vcs_simulation)`、`Synthesis (design_compiler_synthesis)`、`Formality (function_checking)`……一直到 `Gate_post (vcs_postroute_sdf)`。每一列有狀態（PASS／FAIL／RUNNING／-）、關鍵數字（slack、面積、DRC 分類…）、耗時；`*` 是修正回圈，`xN` 是這一輪跑了幾次。任何時候都可以用 `bash scripts/run_stage.sh status` 叫出來（只讀狀態檔，不會執行任何 EDA 工具）。回報流程結果時，先附上這張表。

**專案歷史**：`flow_dashboard.py` 每次執行都會把專案路徑登記到 `~/.claude/ic-flow/projects.txt`；`python3 scripts/flow_dashboard.py --history` 列出所有跑過的專案（正在跑的在前，其次依最後活動時間）。選用的 `/ic_flow` 面板用它自動找專案、顯示歷史。

**`/ic_flow` 面板（選用，目前只有 Claude Code）**：裝了本 repo 的 Claude Code plugin 時，輸入 `/ic_flow`（自動跟隨最近有動的專案）或 `/ic_flow <專案路徑>`，右側會開一個即時更新的面板：同一張流程表，點任一階段可以看白話說明、通過標準、產出、關鍵數字、log 結果行與該階段的動畫；下方 History 可切換專案，Esc 關閉。資料來自 `flow_dashboard.py --json`，判定全部來自 `run_stage.sh` 寫的 `runs/<stage>/status.txt`，面板本身不判定通過與否。

**跑完後的回報**：每次 `run_all.sh` 結束（`ALL_STAGES_PASS` 或中途 STOP），或使用者請你跑完一串階段之後，先貼終端機流程表格，再用文字說明結果；使用者有 `/ic_flow` 面板時，提醒可以用它看每個階段的細節。

APR 之後有三個「修正回圈」，都是從實際報告自動抓問題，不用手寫 cell 名稱：`eco`（ICC2 估計 RC 下的違規）、`drc_patch`（ICV 的 M1 細條）、`signoff_eco`（StarRC＋PT 下的違規）。每個都會先 `save_block -as <name>_before…` 留備份。

使用重點：

1. 先改 `templates/00_common/flow_config.tcl`：集中定義 `USE_PAD`、`DESIGN`、`RTL_FILES`、`CLK_PORT`、`PERIOD`、I/O delay（`IN_DELAY_MAX/MIN`、`OUT_DELAY_MAX/MIN`）、`PROCESS`（saed32／cbdk）、PDK 與 IO library 路徑、corner 清單；並由 `USE_PAD` 推出 `TOP`、`PG_NETS`。標 `←` 的值一定要換成自己的設計（`DESIGN` 預設是 `MY_TOP`，沒改的話 `run_stage.sh` 會直接提示）。所有 tcl 都先 `source` 它；SDC 與 APR 讀同一組 I/O delay，`.sh` 腳本也從這裡讀 top 名稱與 RTL 清單。接著逐一看各階段腳本檔頭的「依設計修改」區塊：模擬的 tb、測資、PASS 字串；DC 的 hold corner 與 max_cap 收緊比例；APR 的 die 大小、I/O 餘裕、繞線修正參數。
2. `templates/00_common/run_stage.sh <stage>` 是統一入口：先 `source /.bash_EDA`，在 `runs/<stage>/` 執行對應工具，最後用 grep 檢查**成功標記**（每個腳本結尾會 `puts "<STAGE>_PASS"`），找不到就回傳失敗。
3. 產生新腳本時，從對應公版複製，保留結構（讀入 → 約束 → 執行 → 報告 → 寫出 → 判定），只換變數與必要的設計特例。
4. 需要說明某階段的原理、檢查點或除錯方式時，讀 `references/flow_stages.md` 對應章節。遇到錯誤訊息時，先查 `references/pitfalls.md`，裡面是這幾個 lab 真的踩過的坑與解法。

製程對照：

| 製程 | 用途 | 單位 | 備註 |
|---|---|---|---|
| CBDK_IC_Contest_v2.5（`slow.db`） | 比賽評分 | ns、pF、kΩ | 比賽規定 slow corner；wire-load `tsmc13_wl10` |
| SAED32 EDK（RVT ss0p95v125c / tt1p05v25c / ff1p16vn40c） | 完整 APR 與 signoff 練習 | ns、**fF**、**MΩ** | 換製程時 SDC 的 `set_load`、`set_drive` 數值一定要換算 |

## 回答時的原則

- **通過與否要看報告內容**：工具 exit 0 不等於通過。每個公版最後都會解析報告並 `exit 1`；寫新腳本時保留這個習慣，回報結果時引用報告裡的實際數字（slack、area、PASS 字串）。
- **說清楚驗證範圍**：例如 ICC2 內建 RC 是估計值，不能稱為 signoff PEX；blackbox LVS 不等於電晶體層級 LVS；STA 未測的 reset pulse width 要列出來。不把沒做的階段說成完成。
- **約束單位跟著 library 走**：`set_load 1` 在 CBDK 是 1 pF，在 SAED32 只是 1 fF。換製程先 `report_units`，再換算。
- **不修改 PDK 與官方附件**：需要調整時在工具記憶體內或專案副本處理，並記錄理由。
- 對初學者解釋時，用「這一步解決什麼問題 → 怎麼做 → 怎麼確認做對了 → 省略會怎樣」的順序。
- **縮寫第一次出現時附上全名與白話**（例如「LVS（Layout Versus Schematic，比對版圖和電路圖）」）。使用者問某個縮寫是什麼，或要一份縮寫介紹時，讀 `references/glossary.md`，照它的表格回答；表裡沒有的縮寫，查證後補進去。

## 檔案地圖

```
templates/
  00_common/  flow_config.tcl  run_stage.sh  run_all.sh  flow_dashboard.py（流程表格／--json／--history）
  01_rtl_sim/ run_rtl_sim.sh
  02_synthesis/ dc_syn.tcl  constraints.sdc  constraints_saed32.sdc
  03_formality/ fm_rtl2gate.tcl
  04_sta/ pt_prelayout.tcl
  05_gate_sim/ run_gate_sim.sh
  06_apr/ build_ndm.tcl  apr_core.tcl  apr_pad_ring.tcl  pad_tools.py  fix_io_lib.py  constraints_chip.sdc
          apr_eco.tcl  apr_drc_patch.tcl  apr_finish.tcl
  07_signoff/ run_icv_drc.sh  drc_pad_classify.py  run_icv_lvs.sh  lvs_pad_classify.py  make_lvs_runset.sh
              run_starrc.sh  pt_postroute.tcl  apr_signoff_eco.tcl  fm_postroute.tcl
references/
  flow_stages.md   每階段原理、指令重點、檢查清單
  pitfalls.md      實際踩過的錯誤訊息與解法
  glossary.md      縮寫與名詞對照（全名＋白話），依類別分表
```

## 驗證狀態

公版用兩個例子設計（IC Contest 題目）在 SAED32 上從頭跑過，數字只是參考，換設計會不同：

**例 1：中小型設計（geofence，30 ns，2026-11-12，當時版本的公版）**
- `USE_PAD 0`：`ALL_STAGES_PASS`，約 19 分鐘。cell area 5863.36；繞線後 setup slow/typ/fast = +23.36/+26.21/+27.51 ns，hold +0.039/+0.051/+0.004 ns；DRC CLEAN（drc_patch 補 4 個 M1.W.2.1）、電晶體層級 LVS PASS、signoff_eco 1 輪。
- `USE_PAD 1`：約 32 分鐘。die 920 µm（24 個訊號 PAD＋8 個電源 PAD），PAD 延遲（slow）input 0.418/0.340 ns、output 推 1 pF 1.231/1.365 ns；前後段時序、Formality、SDF 模擬都 PASS。DRC／LVS 沒有通過：當時還沒有 `fix_io_lib.py`，IO library 的錯誤沒修（見例 2）。

**例 2：較大的設計（REFRACT，50 ns，約 600 個帶非同步 reset 的 DFF，2026-11-16）**
- `USE_PAD 0`：`ALL_STAGES_PASS`（一階段一階段跑）。面積 19843.6；繞線後 setup +36.01／+42.02／+45.65 ns，hold +0.228／+0.085／+0.003 ns；DRC CLEAN、LVS PASS、signoff_eco 1 輪、繞線後 Formality 與 28 次 SDF 模擬 PASS。這個例子抓出 7 個公版問題並已修正（見 `references/pitfalls.md`），之後又把設計相關的值改成檔頭變數與 `flow_config.tcl` 的共用設定。
  2026-11-17 用加了 tie cell 修正的公版重跑：`ALL_STAGES_PASS`，約 31 分鐘。面積 19978.0；繞線後 setup +36.06／+42.05／+45.67 ns，hold +0.242／+0.093／+0.006 ns；DRC CLEAN、LVS PASS、`check_pg_connectivity` 全部 0。
- `USE_PAD 1`（2026-11-17）：`ALL_STAGES_PASS`，約 57 分鐘（修正回圈讓 DRC 跑了 4 次）。49 個 PAD，die 1200 µm、core 520 µm；PAD 延遲（slow）input 0.42/0.34 ns、output 推 1 pF 1.23/1.36 ns。DRC `RESULTS: CLEAN`、LVS `Final comparison result:PASS`（44,171 個 MOS）、`check_pg_connectivity` 全部 0；繞線後 setup +37.18 ns（slow），hold 最差 +0.00005 ns（fast，signoff_eco 2 輪後）。PAD 模式 DRC／LVS 的 10 個原因都在這一輪找出並修掉（見 pitfalls「PAD」）。

尚未實測：`PROCESS cbdk` 分支（沒有用本公版完整跑過）、bidirectional PAD（`pad_tools.py` 遇到 inout port 會直接報錯）、`io_std` 以外的 IO library。

