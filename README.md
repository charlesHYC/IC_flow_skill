# IC_flow_skill

**把一份 Verilog 程式一路做成晶片版圖（RTL → GDS），每一步都有腳本、有說明、有判定。**

對象是第一次接觸數位 IC 後段流程的學生，例如做完 IC Contest 題目、想知道「合成之後還要做什麼」的人。

它是一個標準格式的 **skill**（一個資料夾，裡面有 `SKILL.md` 說明檔和腳本），**OpenAI Codex、Claude Code 等支援 skill 的 AI 程式助手都能用**；裝進去之後，你用中文問 IC 流程的問題，AI 助手就會照這份教材回答、幫你建專案和跑腳本。

裝好之後你會得到兩樣東西：

| | 是什麼 | 你可以拿它做什麼 |
|---|---|---|
| **`digital-ic-flow` skill** | 給 AI 助手看的「教材＋腳本範本」 | 問 AI 助手「下一步要做什麼？」「這個 DRC 錯誤是什麼意思？」「幫我寫 PrimeTime 腳本」，它會照這份教材回答，並用裡面的公版腳本幫你建專案、跑流程 |
| **`/ic_flow` 面板**（選用） | 即時進度面板（目前只有 Claude Code 能用） | 看專案跑到哪一步、哪一步 PASS／FAIL、關鍵數字；點任一階段看白話說明 |

> 腳本整理自實際做過的 lab（IC Contest 的 geofence、REFRACT），在 SAED32 教學製程與 CBDK_IC_Contest 上跑過，[完整流程的結果](#五分鐘體驗不用裝-eda-工具)放在 `examples/`。

---

## 目錄

1. [先搞懂：這個流程在做什麼？](#先搞懂這個流程在做什麼)
2. [五分鐘體驗（不用裝 EDA 工具）](#五分鐘體驗不用裝-eda-工具)
3. [安裝](#安裝)
4. [用它跑你自己的設計](#用它跑你自己的設計)
5. [每個階段用哪些腳本](#每個階段用哪些腳本)
6. [看懂結果](#看懂結果)
7. [卡關了怎麼辦](#卡關了怎麼辦)
8. [常見問題](#常見問題)
9. [需求、限制、檔案說明](#需求與限制)

---

## 先搞懂：這個流程在做什麼？

你寫的 Verilog（**RTL**）只是「描述電路行為的程式」。要變成真的晶片，還要經過一連串工具把它變成**邏輯閘**，再把邏輯閘**擺到矽晶片上、用金屬線連起來**，最後檢查做出來的東西**又快又正確、而且工廠做得出來**。

可以把它想成蓋房子：

| 蓋房子 | 晶片流程 | 這個 repo 的階段 |
|---|---|---|
| 寫需求、確認格局合理 | 寫 RTL、跑模擬確認功能對 | 1 RTL 模擬 |
| 把需求換成標準建材清單 | **合成**：RTL → 標準元件（AND、OR、正反器…）組成的 netlist | 2 合成 |
| 確認建材清單跟需求一致 | **等價驗證**：數學證明 netlist 和 RTL 功能一樣 | 3 Formality |
| 估算水電夠不夠用 | **STA**：算每條訊號路徑在時脈內跑不跑得完 | 4 STA |
| 用建材清單再模擬一次 | **閘級模擬**：netlist 加上元件延遲再跑一次 testbench | 5 閘級模擬 |
| 畫平面圖、擺家具、拉管線 | **APR**：擺放元件、長時脈樹、繞線 | 6 APR |
| 建管處審圖 | **DRC／LVS**：檢查版圖合不合製程規則、和電路圖一不一致 | 7 DRC／LVS |
| 量實際管線長度 | **寄生萃取**：算出每條金屬線真正的電阻電容 | 8 StarRC |
| 用實際管線重新驗收 | 用真實線延遲再做一次 STA、等價驗證、模擬 | 9 繞線後驗證 |

```mermaid
flowchart LR
  P["0 PAD 規劃<br/>（選用）"] --> A["1 RTL 模擬<br/>VCS"] --> B["2 合成<br/>Design Compiler"] --> C["3 等價驗證<br/>Formality"] --> D["4 STA<br/>PrimeTime"] --> E["5 閘級模擬<br/>VCS + SDF"]
  E --> F["6 APR<br/>IC Compiler II"] --> G["7 DRC / LVS<br/>IC Validator"] --> H["8 寄生萃取<br/>StarRC"] --> I["9 繞線後驗證<br/>PT / FM / VCS"]
```

**每一步怎樣才算過？** 不是看工具有沒有當掉，而是**讀報告**：例如 STA 的 slack（時間餘裕）要 ≥ 0、DRC 要 `CLEAN`、LVS 要 `PASS`。每個腳本最後都會自己讀報告、印出 `XXX_PASS` 或失敗，你不用自己翻幾千行 log。

### 要不要加 PAD？

**PAD** 是晶片邊緣的接腳零件，負責打線、防靜電、推動板子上的負載。比賽通常只做「核心」（沒有 PAD）；真正的晶片則一定要有。

| | 無 PAD（`USE_PAD 0`） | 有 PAD（`USE_PAD 1`） |
|---|---|---|
| 做到哪 | 只有你的電路本體 | 你的電路＋外圍一圈 PAD 的完整晶片 |
| 時序 | 不考慮 PAD | 輸入多約 0.4 ns、輸出推 1 pF 約 1.3 ns，**從 RTL 模擬就看得到** |
| 晶片大小 | 小（例：240 µm） | 被 PAD 數量撐大（例：920 µm） |
| DRC／LVS | 可以完全通過 | 最多到 `PAD_LIMITED`（見[限制](#需求與限制)） |
| 適合 | 先把流程跑通 | 想看完整晶片長什麼樣子 |

不確定的話，**兩種都跑來比較**。AI 助手每次開始跑流程前都會問你選哪一種。

---

## 五分鐘體驗（不用裝 EDA 工具）

`examples/` 裡放了兩個**已經跑完**的 geofence 專案，一個無 PAD、一個有 PAD。只要有 Python 3 就能看結果：

```bash
git clone https://github.com/charlesHYC/IC_flow_skill.git
cd IC_flow_skill
python3 skills/digital-ic-flow/templates/00_common/flow_dashboard.py examples/geofence_core
python3 skills/digital-ic-flow/templates/00_common/flow_dashboard.py examples/geofence_pad
```

你會看到像這樣的表格（有 PAD 版本，節錄）：

```
┌──────────────────────────────────────────────┬─────────────┬──────────────────────────────────────────┬──────────┐
│ Stage (steps)                                │ Status      │ Key numbers                              │ Time     │
├──────────────────────────────────────────────┼─────────────┼──────────────────────────────────────────┼──────────┤
│ PAD_planning (pad_wrapper, pad_delay_model)  │ PASS        │ pads 24, in 0.42/0.34, out 1.23/1.36 ns  │ 0:00     │
│ RTL_coding (vcs_simulation)                  │ PASS        │                                          │ 0:02     │
│ Synthesis (design_compiler_synthesis)        │ PASS        │ area 6013.8, setup +8.589 ns             │ 0:13     │
│ ...                                          │             │                                          │          │
│ DRC (icv_drc)                                │ PAD_LIMITED │ core 0, io_ring 2120, stitch 4           │ 3:37 x3  │
│ LVS (icv_lvs_transistor)                     │ PAD_LIMITED │ MOS 25,640, RES 8 matched                │ 0:23 x2  │
│ STA_postroute (primetime_spef)               │ PASS        │ setup +22.877 / hold +0.016 ns           │ 0:19 x2  │
│ Gate_post (vcs_postroute_sdf)                │ PASS        │ SDF $removal warn 17/17                  │ 0:07     │
└──────────────────────────────────────────────┴─────────────┴──────────────────────────────────────────┴──────────┘
  ALL_STAGES_DONE_PAD_LIMITED  全部跑完；DRC／LVS 只剩 IO library 的問題，這不等於 PASS。
```

完整表格：[geofence_core](examples/geofence_core/flow_table.txt)（全部 PASS）、[geofence_pad](examples/geofence_pad/flow_table.txt)。表格每一欄的意思見[看懂結果](#看懂結果)。

用 Claude Code 並裝了面板的話，輸入 `/ic_flow <你 clone 的路徑>/examples/geofence_pad`，就能在面板上點每個階段看說明和動畫。

---

## 安裝

skill 本身就是 `skills/digital-ic-flow/` 這個資料夾，把它複製到你的 AI 助手讀 skill 的地方就好。

### OpenAI Codex

```bash
git clone https://github.com/charlesHYC/IC_flow_skill.git
mkdir -p ~/.codex/skills
cp -r IC_flow_skill/skills/digital-ic-flow ~/.codex/skills/
```

重新啟動 `codex` 就會生效。之後直接用中文問 IC 流程的問題即可；想明確指定時，可以在訊息裡打 `$digital-ic-flow`。

### Claude Code

只要 skill：

```bash
git clone https://github.com/charlesHYC/IC_flow_skill.git
mkdir -p ~/.claude/skills
cp -r IC_flow_skill/skills/digital-ic-flow ~/.claude/skills/
```

想要 skill＋`/ic_flow` 面板一起裝，在 Claude Code 的提示列輸入：

```
/plugin install ic-flow --marketplace charlesHYC/IC_flow_skill
```

出現 `Add marketplace?` 時按 `y`，選安裝範圍時直接按 Enter，看到 `Installed ic-flow` 就完成了。

### 其他 AI 助手

支援 `SKILL.md` 格式的工具，照它的說明把 `skills/digital-ic-flow/` 放到 skill 資料夾即可。不支援的話，也可以把 `SKILL.md` 的內容貼給它當作說明，腳本在 `templates/` 裡照樣能用。

---

## 用它跑你自己的設計

### 第 1 步：準備好這些檔案

| 你需要 | 例子（geofence） | 說明 |
|---|---|---|
| RTL | `rtl/geofence.v` | 你的設計 |
| testbench | `tb/tb.sv` | 比賽給的 tb 就可以 |
| 測資 | `patterns/` | tb 會讀的輸入／標準答案 |
| tb 成功時印的字 | `ALL PASS` | 腳本用它判斷模擬有沒有過 |
| 時脈 | port 名稱 `clk`、週期 30 ns | 比賽題目通常有規定 |

建議的專案資料夾長這樣（`scripts/` 和 `runs/` 會自動產生）：

```
my_project/
├── rtl/        你的 Verilog
├── tb/         testbench
├── patterns/   測資
├── scripts/    公版腳本（AI 助手幫你複製進來）
└── runs/       每個階段的輸出，一個階段一個資料夾
```

### 第 2 步：建專案、改設定（手動）

**(1) 把公版腳本複製到 `scripts/`**（所有階段的腳本放在同一層）：

```bash
cd my_project
mkdir -p scripts
cp <IC_flow_skill 的路徑>/skills/digital-ic-flow/templates/*/* scripts/
```

**(2) 改這幾個檔案**。每個腳本開頭都有標「依設計修改」的區塊，只要改那裡：

| 檔案 | 要改什麼 |
|---|---|
| `scripts/flow_config.tcl` | **總設定**，最重要（見下面） |
| `scripts/run_rtl_sim.sh`、`scripts/run_gate_sim.sh` | tb 路徑 `TB`、tb 的 top `TOP`、測資 `PATTERNS`、成功字串 `PASS_MARKER`、`DESIGN` |
| `scripts/constraints_saed32.sdc`（SAED32）或 `constraints.sdc`（CBDK） | 輸入／輸出延遲、輸出負載；比賽有規定就照規定 |
| `scripts/run_icv_drc.sh`、`run_icv_lvs.sh`、`run_starrc.sh` | `DESIGN`、製程檔路徑 |

`flow_config.tcl` 最重要的幾行：

```tcl
set DESIGN     geofence                       ;# 你的 top module 名稱
set RTL_FILES  [list $PROJ/rtl/geofence.v]    ;# RTL 檔案
set CLK_PORT   clk                            ;# 時脈 port
set PERIOD     30.0                           ;# 時脈週期（ns）
set USE_PAD    0                              ;# 0 = 無 PAD，1 = 有 PAD
set PROCESS    saed32                         ;# saed32 或 cbdk
```

再往下還有製程檔路徑（`/mnt/nfs/opt/PROCESS/...`），請改成你機器上的位置。

**(3) 載入 EDA 工具環境**：各學校／公司的方式不同，例如 `source /usr/cad/synopsys/CIC/...` 或 `module load ...`。確認 `vcs`、`dc_shell`、`fm_shell`、`pt_shell`、`icc2_shell`、`icv` 打得出來。`scripts/run_stage.sh` 第 8 行預設是 `source /.bash_EDA`，請改成你的方式。

> 不想手動改的話，也可以請 AI 助手代勞：在 `my_project/` 裡啟動 `codex` 或 `claude`，說「用 digital-ic-flow 幫我把這個設計建成完整流程，設計叫 geofence，clock 是 clk、30 ns」。它會先問要不要上 PAD，再幫你複製、填好上面這些檔案。

### 第 3 步：跑起來

每個階段一個指令，依序執行：

```bash
bash scripts/run_stage.sh synthesis    # 例：跑合成
```

`run_stage.sh` 會切到 `runs/<階段>/`、執行對應的工具和腳本、把輸出存成 `console.log`，最後在 log 裡找成功標記判定 PASS／FAIL。全部 16 個階段的名稱、各自用哪些 `.tcl`、想自己下工具指令怎麼下，見下一節[每個階段用哪些腳本](#每個階段用哪些腳本)。

一次全部跑完（geofence 約 20–30 分鐘），遇到失敗會停下來：

```bash
bash scripts/run_all.sh
```

### 第 4 步：看進度

- **終端機**：`bash scripts/run_stage.sh status`，隨時印出流程表格。
- **`/ic_flow` 面板**（Claude Code 裝了 plugin 才有）：輸入 `/ic_flow`，右邊會開即時面板，每 5 秒更新：
  - 正在跑的階段有轉圈動畫 `⠋ RUNNING`。
  - **點任一階段**，下面會顯示這一步在做什麼（What）、怎樣算過（Pass）、產出什麼（Output）、關鍵數字（Numbers）、log 裡的結果行（Results）和 log 位置。
  - 下方 **History** 列出跑過的專案，點一下或按 1–5 切換。
  - 按 `Esc` 關閉。

---

## 每個階段用哪些腳本

公版一共 28 個檔案，依流程階段分組如下。每一組寫出：用什麼工具、每個檔案在做什麼、產出什麼，以及怎麼執行。

**執行方式（每個階段都一樣）**

- 用包裝好的指令：`bash scripts/run_stage.sh <階段名>`（建議）。
- 自己下工具指令：
  ```bash
  mkdir -p runs/<階段名>/reports && cd runs/<階段名>
  <工具指令> < /dev/null | tee console.log    # < /dev/null：腳本出錯時工具不會卡在提示字元
  grep '^<成功標記>' console.log                # 找得到才算通過
  cd ../..
  ```

---

### 共用：設定與執行入口

| 檔案 | 做什麼 |
|---|---|
| `flow_config.tcl` | **總設定**。設計名稱、RTL、時脈、週期、要不要上 PAD、製程與 library 路徑、三個 corner 的對照表。所有 `.tcl` 第一行都會讀它，換設計主要改這一個檔 |
| `run_stage.sh` | 單一階段的入口：切到 `runs/<階段>/`、執行工具、存 log、找成功標記判定 PASS／FAIL；`run_stage.sh status` 印出流程表格 |
| `run_all.sh` | 依序跑完所有階段，包含修正回圈；遇到失敗會停 |
| `flow_dashboard.py` | 讀 `runs/` 裡的狀態檔，印出流程表格（也提供 `/ic_flow` 面板用的資料） |

---

### 0. PAD 規劃（只有 `USE_PAD 1`）— Python

決定晶片外圍要放哪些 PAD，並算出 PAD 的延遲，讓之後每一步都把 PAD 算進去。

| 檔案 | 做什麼 |
|---|---|
| `pad_tools.py` | `wrapper`：讀 RTL 的 port，產生包住你設計的晶片外殼 `<DESIGN>_chip.v`（每個 port 接一顆 PAD）和 PAD 擺放計畫；`padmodel`：從 IO library 查表算出 PAD 延遲，寫成模擬用的 PAD model |
| `constraints_chip.sdc` | 晶片版的時序約束：port 在 PAD 外側、輸出推 1 pF 板級負載。之後合成、STA、APR 都用它取代核心版約束 |

產出：`runs/pad/<DESIGN>_chip.v`、`io_pad_sim.v`、`pad_plan.tcl`　　成功標記：`PAD_PASS`

```bash
bash scripts/run_stage.sh pad
```

---

### 1. RTL 模擬 — VCS

確認你寫的 RTL 功能正確，之後每一步都要和這個結果一致。

| 檔案 | 做什麼 |
|---|---|
| `run_rtl_sim.sh` | 用 VCS 編譯 tb＋RTL 並執行，檢查 tb 印出成功字串。有 PAD 時改模擬晶片外殼＋帶延遲的 PAD model；可用 `SIM_CASES` 讓同一個 tb 用不同 define 跑多次 |

成功標記：`ALL PASS`

```bash
cd runs/rtl_sim && bash ../../scripts/run_rtl_sim.sh
```

---

### 2. 邏輯合成 — Design Compiler

把 RTL 換成標準元件（AND、OR、正反器…）組成的 gate-level netlist。

| 檔案 | 做什麼 |
|---|---|
| `dc_syn.tcl` | 主腳本：設定 library → 讀 RTL → 套時序約束 → compile → 報告 → 寫出 netlist 等檔案 → 檢查沒有時序與設計規則違規 |
| `constraints_saed32.sdc` | SAED32 用的時序約束：時脈、輸入／輸出延遲、負載（單位 ns、fF） |
| `constraints.sdc` | CBDK_IC_Contest 用的時序約束（比賽原題風格，單位 ns、pF） |

產出：`<top>_syn.v`（netlist）、`.ddc`、`.sdc`、`.sdf`、`.svf`（給 Formality）　　成功標記：`DC_PASS`

```bash
cd runs/synthesis && dc_shell -f ../../scripts/dc_syn.tcl
```

---

### 3. 等價驗證 — Formality

不跑模擬，用數學方法證明合成出來的 netlist 和 RTL 功能完全相同。

| 檔案 | 做什麼 |
|---|---|
| `fm_rtl2gate.tcl` | 讀 RTL（reference）和合成 netlist（implementation），用 DC 留下的 `.svf` 對上兩邊的名字，逐一比對 |

成功標記：`FM_PASS`

```bash
cd runs/formality && fm_shell -f ../../scripts/fm_rtl2gate.tcl
```

---

### 4. 佈局前 STA — PrimeTime

在 slow／typical／fast 三個 corner 計算每條路徑的時間餘裕（slack），確認時序來得及。

| 檔案 | 做什麼 |
|---|---|
| `pt_prelayout.tcl` | 讀 netlist 和約束，報告 setup／hold slack 與違規；同時寫出該 corner 的 SDF（每顆元件的延遲），給下一步閘級模擬用。每個 corner 跑一次 |

產出：`<DESIGN>_<corner>.sdf`　　成功標記：`STA_PASS slow`（typical、fast 同理）

```bash
cd runs/sta
for c in slow typical fast; do FLOW_CORNER=$c pt_shell -f ../../scripts/pt_prelayout.tcl > console_$c.log; done
```

---

### 5. 閘級模擬 — VCS

用合成後的 netlist 加上每顆元件的真實延遲（SDF），再跑一次 testbench。比賽通常評到這一步。

| 檔案 | 做什麼 |
|---|---|
| `run_gate_sim.sh` | 用 VCS 模擬 netlist＋SDF，檢查功能 PASS、SDF 全部註入成功、沒有時序違規。設 `POSTROUTE=1` 時改用繞線後的 netlist 和 SDF（第 9 步） |

成功標記：`GATE_SIM_PASS`

```bash
cd runs/gate_sim && bash ../../scripts/run_gate_sim.sh
```

---

### 6. APR（擺放與繞線）— IC Compiler II

把 netlist 裡的元件擺到晶片上、長時脈樹、用金屬線連起來，最後輸出版圖。分成五個腳本：

| 檔案 | 做什麼 | 在哪跑 | 成功標記 |
|---|---|---|---|
| `build_ndm.tcl` | 把標準元件的時序檔（.db）和外框檔（LEF）打包成 ICC2 用的 library（NDM） | `runs/ndm`，用 `icc2_lm_shell` | `NDM_PASS` |
| `apr_core.tcl` | 主流程：floorplan → 電源網路 → 擺放 → 時脈樹（CTS）→ 繞線。每一步存一個 block，出錯可從上一步重來 | `runs/apr` | `APR_ROUTED` |
| `apr_pad_ring.tcl` | 有 PAD 時由 `apr_core.tcl` 自動呼叫：算 die 大小、擺 PAD 和角落元件、把 PAD 電源接到核心電源環。不用單獨執行 | — | — |
| `apr_eco.tcl` | 讀報告找出推不動負載的訊號（max_cap／max_transition 違規），自動插 buffer 修好 | `runs/apr` | `APR_PASS` |
| `apr_finish.tcl` | 補 filler 元件，寫出 GDS 版圖、兩份 netlist（`routed.v` 給時序、`routed_pg.v` 含電源給 LVS）、DEF | `runs/finish` | `FINISH_PASS` |

```bash
cd runs/ndm    && icc2_lm_shell -f ../../scripts/build_ndm.tcl && cd ../..
cd runs/apr    && icc2_shell -f ../../scripts/apr_core.tcl   && cd ../..
cd runs/apr    && icc2_shell -f ../../scripts/apr_eco.tcl    && cd ../..
cd runs/finish && icc2_shell -f ../../scripts/apr_finish.tcl && cd ../..
```

產出：`runs/apr/routed_full.gds`、`routed.v`、`routed_pg.v`

---

### 7. DRC／LVS — IC Validator

檢查版圖能不能被工廠做出來（DRC），以及版圖接出來的電路和 netlist 是否一致（LVS）。

| 檔案 | 做什麼 |
|---|---|
| `run_icv_drc.sh` | 用製程的 DRC 規則檢查整張 GDS，結果要 `CLEAN` |
| `drc_pad_classify.py` | 有 PAD 時由上面自動呼叫：把錯誤分成「PAD library 本身的」和「你的電路的」，只有前者就記為 `PAD_LIMITED` |
| `apr_drc_patch.tcl` | **修正回圈**：DRC 抓到 M1 金屬太細的小錯時，在 ICC2 裡自動補金屬。跑完要重跑 `apr_finish.tcl` 和 DRC |
| `run_icv_lvs.sh` | 把 netlist 轉成電晶體層級電路，和版圖萃取出的電晶體逐一比對 |
| `make_lvs_runset.sh` | 由上面自動呼叫：複製製程的 LVS 規則檔，改掉幾個不相容的地方（原檔不動） |
| `lvs_pad_classify.py` | 有 PAD 且 LVS 失敗時自動呼叫：確認不一致只在電源網路和 PAD 裡，就記為 `PAD_LIMITED` |

成功標記：DRC `DRC_PASS`、LVS `LVS_PASS`（有 PAD 時最多到 `DRC_PAD_LIMITED`、`LVS_PAD_LIMITED`）

```bash
cd runs/drc && bash ../../scripts/run_icv_drc.sh && cd ../..
cd runs/lvs && bash ../../scripts/run_icv_lvs.sh && cd ../..
# DRC 有 M1 細條錯誤時：
cd runs/apr && icc2_shell -f ../../scripts/apr_drc_patch.tcl && cd ../..   # 成功：DRC_PATCH_PASS，再重跑 finish 和 DRC
```

---

### 8. 寄生萃取 — StarRC

從版圖算出每條金屬線真正的電阻和電容，給繞線後的時序分析用。

| 檔案 | 做什麼 |
|---|---|
| `run_starrc.sh` | 對三個 RC corner（Cmax／nominal／Cmin，對應 slow／typical／fast）各寫一份 SPEF |

成功標記：`STARRC_PASS`

```bash
cd runs/starrc && bash ../../scripts/run_starrc.sh
```

---

### 9. 繞線後驗證 — PrimeTime、Formality、VCS

用真實的線延遲，把時序、等價、模擬再驗一次。

| 檔案 | 工具 | 做什麼 | 成功標記 |
|---|---|---|---|
| `pt_postroute.tcl` | PrimeTime | 讀繞線後 netlist＋SPEF，用真的時脈樹重算 slack；寫出繞線後 SDF。每個 corner 跑一次 | `POSTROUTE_STA_PASS slow` 等 |
| `apr_signoff_eco.tcl` | IC Compiler II | **修正回圈**：上一步還有小幅違規時，自動把元件換大一號或插 buffer。跑完要依序重跑 finish → DRC → LVS → StarRC → 繞線後 STA | `SIGNOFF_ECO_PASS` |
| `fm_postroute.tcl` | Formality | 證明繞線後的 netlist（多了時脈樹和 ECO 插的 buffer）仍和 RTL 相同 | `FM_POST_PASS` |
| `run_gate_sim.sh` | VCS | 和第 5 步同一支，設 `POSTROUTE=1` 改用繞線後 netlist＋SDF | `GATE_SIM_PASS` |

```bash
cd runs/pt_post
for c in slow typical fast; do FLOW_CORNER=$c pt_shell -f ../../scripts/pt_postroute.tcl > console_$c.log; done
cd ../..
cd runs/fm_post   && fm_shell -f ../../scripts/fm_postroute.tcl     && cd ../..
cd runs/gate_post && POSTROUTE=1 bash ../../scripts/run_gate_sim.sh && cd ../..
# 繞線後 STA 有違規時：
cd runs/apr && icc2_shell -f ../../scripts/apr_signoff_eco.tcl && cd ../..
```

---

## 看懂結果

### 表格的每一欄

| 欄位 | 意思 |
|---|---|
| **Stage (steps)** | 階段名稱，括號裡是這一步做的事。名字後面有 `*` 的是**修正回圈**：只有上一步發現問題才會跑 |
| **Status** | 這一步的判定（見下表） |
| **Key numbers** | 最重要的數字，例如合成的面積和 slack、DRC 錯誤數 |
| **Time** | 花了多久；`x3` 表示這一輪跑了 3 次（修正回圈會讓同一步重跑） |

### 狀態

| 狀態 | 意思 | 要做什麼 |
|---|---|---|
| `PASS` | 報告確認通過 | 繼續下一步 |
| `FAIL` | 報告裡有問題 | 看 log，見[卡關了怎麼辦](#卡關了怎麼辦) |
| `RUNNING` | 正在跑 | 等 |
| `PAD_LIMITED` | 只有 PAD 模式會出現：你的電路沒問題，錯誤都在 PAD library 裡 | **這不是 PASS**，但已經是這套教學製程能做到的最好結果 |
| `-` | 還沒跑 | |
| `skip` | 無 PAD 模式跳過 PAD 規劃 | |
| `not needed` | 修正回圈不需要跑 | |

### 幾個常看到的數字

| 數字 | 意思 | 好的範圍 |
|---|---|---|
| **setup slack** | 訊號在下一個時脈來之前，還多出多少時間 | ≥ 0（負的代表太慢，要放寬週期或改電路） |
| **hold slack** | 訊號會不會太快、蓋掉上一筆資料 | ≥ 0 |
| **area** | 元件總面積（µm²） | 越小越好（比賽常用面積 × 時間評分） |
| **DRC core 0** | 你的電路區域沒有違反製程規則 | 0 |
| **MOS matched** | LVS 對上的電晶體數 | 全部對上 |

三個 **corner**（slow／typical／fast）是指晶片在「最慢、一般、最快」三種製程、電壓、溫度條件下都要能正常運作。

---

## 卡關了怎麼辦

1. **看是哪一步 FAIL**：`bash scripts/run_stage.sh status`，或在 `/ic_flow` 點那一列看 Results。
2. **看 log**：每一步的輸出都在 `runs/<階段>/console.log`。
3. **直接問 AI 助手**：
   > synthesis FAIL 了，幫我看 runs/synthesis/console.log 是什麼問題。

   這個 skill 裡有一份「實際踩過的坑」清單（[`pitfalls.md`](skills/digital-ic-flow/references/pitfalls.md)），AI 助手會先對照它。
4. **修好後重跑那一步**，例如 `bash scripts/run_stage.sh synthesis`，再繼續往下。

---

## 常見問題

**Q：我沒有 Synopsys 工具，可以用嗎？**
可以看 demo、讀教材、問 AI 助手流程的問題；但要真的跑流程，需要學校或公司的 Synopsys 授權與伺服器。

**Q：可以用在比賽嗎？**
IC Contest 通常只評到第 5 步（RTL 模擬＋合成後閘級模擬），第 6–9 步是延伸練習。比賽用 CBDK_IC_Contest 製程時，把 `PROCESS` 設成 `cbdk`。

**Q：`PAD_LIMITED` 是我做錯了嗎？**
不是。SAED32 教學製程的 PAD library 自己的版圖檔和規格檔彼此不一致，加 PAD 的晶片一定會有這些錯誤。腳本會幫你確認錯誤都在 PAD 裡、你的電路是乾淨的。要完全乾淨的 DRC／LVS，用無 PAD 模式。

**Q：看不懂縮寫（STA、CTS、SDF…）？**
看 [`glossary.md`](skills/digital-ic-flow/references/glossary.md)，每個縮寫都有全名和白話解釋；或直接問 AI 助手「SDF 是什麼？」。

**Q：每一步的原理在哪裡？**
[`flow_stages.md`](skills/digital-ic-flow/references/flow_stages.md)：每個階段的目的、做法、檢查清單。

---

## 需求與限制

**需求**
- 支援 skill 的 AI 程式助手：OpenAI Codex、Claude Code 等
- Python 3
- 真的要跑流程時：Synopsys VCS、Design Compiler、Formality、PrimeTime、IC Compiler II、IC Validator、StarRC（要自己有授權）
- 製程：SAED32 EDK 或 CBDK_IC_Contest

**要依你的環境修改**
- 工具環境：`run_stage.sh` 預設執行 `source /.bash_EDA` 載入工具，請改成你機器上的設定方式。
- 製程路徑：腳本裡的 `/mnt/nfs/opt/PROCESS/...` 是範例路徑，請改成你機器上製程檔的位置。**製程檔不包含在這個 repo 裡**（SAED32 依授權不得另行散布）。

**已知限制**
- 有 PAD 模式只支援 SAED32（CBDK_IC_Contest 沒有 PAD library）。
- 有 PAD 模式的 DRC／LVS 最多到 `PAD_LIMITED`（原因見[常見問題](#常見問題)與 [`pitfalls.md`](skills/digital-ic-flow/references/pitfalls.md)）。
- 還沒實測過：`PROCESS cbdk` 用本公版跑完全流程、雙向（inout）PAD、`io_std` 以外的 PAD library。

### 檔案說明

```
IC_flow_skill/
├── skills/digital-ic-flow/          ← skill 本體
│   ├── SKILL.md                     給 AI 助手看的總說明與規則
│   ├── references/
│   │   ├── flow_stages.md           每個階段的原理與檢查清單
│   │   ├── pitfalls.md              實際踩過的錯誤與解法
│   │   └── glossary.md              縮寫對照（全名＋白話）
│   └── templates/                   公版腳本，會被複製到你專案的 scripts/
│       ├── 00_common/               總設定 flow_config.tcl、run_stage.sh、run_all.sh、流程表格
│       ├── 01_rtl_sim/ … 07_signoff/  各階段腳本（每個檔案的用途見「每個階段用哪些腳本」）
├── examples/                        兩個跑完的 demo（無 PAD／有 PAD）
├── hooks/  types/                   /ic_flow 面板的程式（Claude Code plugin，選用）
└── .claude-plugin/                  Claude Code plugin 安裝設定（選用）
```

## 授權

[MIT](LICENSE)：可以自由使用、修改、分享，保留版權聲明即可。
