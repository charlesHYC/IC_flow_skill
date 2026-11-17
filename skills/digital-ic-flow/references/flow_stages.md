# 各階段說明

每節固定四段：**目的**、**關鍵設定**、**怎麼確認做對**、**省略會怎樣**。範例數字來自驗證公版用的例子設計（30 ns 與 50 ns 各一個），換設計會不同。

目錄
0. 開始前：要不要上 PAD
1. RTL 模擬
2. 邏輯合成（DC）與 SDC
3. 等價驗證（Formality）
4. 佈局前 STA（PrimeTime）
5. 閘級模擬（SDF）
6. APR（ICC2）
7. DRC / LVS（ICV）
8. 寄生萃取（StarRC）
9. 繞線後 STA／LEC／模擬
10. 專案目錄與交付慣例
11. IO PAD 完整說明（是什麼、製程給什麼、怎麼選、怎麼排、怎麼確認）

---

## 0. 開始前：要不要上 PAD（`USE_PAD`）

- **目的**：決定這顆設計是「只做核心」（IP block），還是「加 IO PAD 的全晶片」。**要在寫 RTL、跑第一次模擬之前就決定**，不能等到 APR。
- **為什麼要這麼早**：PAD 本身有延遲（SAED32 slow corner：input PAD 約 0.4 ns；output PAD 推 1 pF 約 1.2–1.4 ns），而且輸出負載從核心的 20 fF 變成板級 1 pF。這些會直接影響：tb 在什麼時間點取樣輸出、合成的 I/O 時序預算、STA 結果、閘級模擬。等到 APR 才加，前面五個階段的結論都要重做。
- **`USE_PAD 1` 時的第 0 步**：`pad` 階段（`pad_tools.py`）
  1. 讀 **RTL** top module 的 port（ANSI 或 Verilog-1995 都可以，位寬可用 parameter），每個 bit 接一顆 PAD，產生 `${DESIGN}_chip` wrapper（`runs/pad/${DESIGN}_chip.v`）。
  2. 從 IO library 的 NLDM 表查出 PAD 延遲（`PAD_SIM_CORNER`，預設 slow），產生帶 `specify` 的 PAD 模擬 model（`runs/pad/io_pad_sim.v`）。官方 IO Verilog model 沒有 specify，PAD 在模擬裡原本是零延遲。
- **之後每個階段的 top 都是 `${DESIGN}_chip`**：RTL 模擬（wrapper＋RTL＋PAD model）、DC（PAD dont_touch）、Formality、PT、閘級模擬（SDF 的 PAD IOPATH 註入 PAD model）、APR、signoff。
- **怎麼確認**：`pad` 階段印出 `PAD_DELAY` 數值；RTL 模擬 log 開頭印出 PAD model 使用的延遲。
- **限制**：只有 SAED32（io_std）有 IO library；`PROCESS cbdk`（CBDK_IC_Contest_v2.5）沒有 PAD library，`USE_PAD 1` 會直接報錯。

## 1. RTL 模擬（VCS／Verdi）

- **目的**：在沒有時序的理想世界確認功能正確，是所有後續比對的基準。
- **關鍵設定**：`vcs -full64 -sverilog -debug_access+r`；用到 DesignWare 時加 `-y $SYNOPSYS/dw/sim_ver +libext+.v`；參數化測試用 `+define+RI=11` 這類 macro。
- **怎麼確認**：tb 印出的 PASS 字串，加上 log 沒有 `Error-[`／`Fatal`。官方 tb 不一定完整，例如某題官方 tb 只檢查 512 個位址中的 272 個、誤差容忍比規格寬，所以要再寫 strict／supplemental tb：全位址、嚴格誤差、寫入順序、DONE 時機、隨機與邊界測資。
- **`USE_PAD 1`**：模擬晶片 top。tb 用副本把 `<DESIGN> u_xxx(` 換成 `<DESIGN>_chip u_xxx(`（原 tb 不動），編譯 wrapper＋RTL＋`io_pad_sim.v`，再用 `-v <IO_MODEL>` 補官方 RECEIVER／DRIVER。核心是零延遲，但 PAD 有延遲，所以 tb 取樣時間點太貼近輸出變化時，在這裡就會失敗。PAD 的 PG port 沒接會出現 `TFIPC` warning（PAD model 內部已經把 PG 當成有效），可以忽略。
- **省略會怎樣**：後面每一階段都只能證明「和 RTL 一樣」，RTL 錯了全部白做。

## 2. 邏輯合成（Design Compiler）與 SDC

- **目的**：把 RTL 對應到 target library 的標準元件，在約束下取得時序與面積的平衡。
- **library 三件組**：`target_library`（挑 cell 用）、`link_library`（`*` 加上所有會用到的 .db 與 `dw_foundation.sldb`）、`synthetic_library`（DesignWare）。
- **SDC 的五類約束**：
  1. clock：`create_clock`、`set_clock_uncertainty`（skew + jitter + margin）、`set_clock_latency`、`set_clock_transition`。
  2. I/O：`set_input_delay`／`set_output_delay`，以外部 launch／capture edge 為參考。題目規定外部用負緣時加 `-clock_fall`。數字寫在 `flow_config.tcl` 的 `IN_DELAY_*`／`OUT_DELAY_*`，SDC 與 APR 共用。
  3. 環境：`set_load`（輸出負載）、`set_drive` 或 `set_driving_cell`（輸入驅動）、`set_input_transition`。
  4. 設計規則：`set_max_transition`、`set_max_capacitance`、`set_max_fanout`。
  5. 例外：false path、multicycle、clock group。
- **合成期間的 clock**：`set_ideal_network` 加 `set_dont_touch_network`，讓 DC 不要建 clock tree，CTS 交給 APR。到了 APR 一定要解除。
- **compile 選擇**：比賽常見 `compile`／`compile -map_effort high`；`compile_ultra` 會自動 ungroup、做 datapath 最佳化，加 `-retime` 可以搬動暫存器（Formality 一定要有 SVF）。
- **輸出**：`.ddc`（DC 資料庫）、`.v`（netlist）、`.sdf`（CBDK 比賽用 1.0；SAED32 用 3.0）、`.sdc`、`.svf`（給 Formality）。
- **怎麼確認**：`report_constraint -all_violators` 沒有時序或 DRC 違規（`max_leakage_power` 預設上限是 0，一定會顯示違規，可忽略）；`check_timing` 沒有 unconstrained endpoint；比賽面積看 **Total cell area**，不是 Total area。
- **SAED32 實務**：target 用 FF library、wire-load 用 `ForQA`、`set_dont_use *X0_RVT *X1_RVT`、max_capacitance 收緊（`MAXCAP_DERATE`）、必要時 `MAX_FANOUT`，為不同 corner 保留電容與轉換時間餘裕；hold／removal 用哪個 corner 修由 `DC_HOLD_CORNER` 決定（見 `dc_syn.tcl` 檔頭的取捨說明）。
- **`USE_PAD 1`**：`analyze` RTL＋wrapper，`elaborate ${DESIGN}_chip`；link 加上 IO library（slow＋fast）；`set_dont_touch [get_cells pad_*]`；約束用 `constraints_chip.sdc`（1 pF）。晶片 port 到 PADIO 的 net 是打線，不是晶片內走線：要 `set_dont_touch` 再 `set_resistance 0`（只設電阻，compile 會把它拿掉，OPT-801）。輸出 `${DESIGN}_chip_syn.v`；核心面積另外寫到 `reports/area_core.rpt`（`area.rpt` 含 PAD，例：24 個訊號 PAD 的設計約 29 萬 µm²）。
- **省略會怎樣**：沒有 netlist；約束錯了，合成結果看起來通過，但其實不符合規格。

## 3. 等價驗證（Formality）

- **目的**：用數學方法證明 netlist 與 RTL 功能相同，不靠 pattern。
- **流程**：`set_svf` → `read_db -technology_library` → `read_verilog -r`（RTL）→ `set_top r:/WORK/<top>` → 讀 implementation（`-i`）→ `match` → `verify`。
- **關鍵設定**：`synopsys_auto_setup true`；DesignWare 需要設 `hdlin_dwroot`；DC 端要 `hdlin_enable_hier_map true` 與 `set_verification_top`。
- **怎麼確認**：`Verification SUCCEEDED`、failing = 0；`report_guidance -summary` 檢查 retiming／ungroup 是否全部 accepted。
- **常見失敗**：`compile_ultra -spg -retime` 把暫存器 retime 進 `DP_OP_*` datapath 區塊，Formality 回報 FM-503「Register … not found in the reference」。改用 `compile_ultra -retime -scan`（不加 -spg）就能通過（Design_compiler_lab Lab 5 實測）。

## 4. 佈局前 STA（PrimeTime）

- **目的**：用 signoff 等級的時序引擎，在多個 corner 檢查 setup／hold／電氣規則。DC 的 report_timing 也是在分析合成電路；PT 是本流程選擇的獨立引擎。
- **corner 觀念**：setup 看 slow（ss、高溫、低壓），hold 看 fast（ff、低溫、高壓）。但 SAED32 的 wire-load tree_type 在 ss／tt／ff 分別是 best／balanced／worst，所以不能預設 ss 一定最嚴，三個都要跑。
- **怎麼確認**：每個 corner 的 setup 與 hold slack 都 ≥ 0、`report_constraint` 沒有 VIOLATED、`check_timing -verbose` 乾淨；`report_analysis_coverage` 未測項目（例如非週期 reset 的 min pulse width）要列出來，不要宣稱 100% coverage。
- **輸出**：每個 corner 的 SDF（`write_sdf -version 3.0`），給閘級模擬用。
- **`USE_PAD 1`**：link 同 corner 的 IO library，top = `${DESIGN}_chip`。佈局前有兩個設定一定要有：(1) port↔PADIO 的打線 net 電阻設 0；(2) clock PAD 之後的 clock net 設 `set_ideal_network [get_pins pad_<clk>/DOUT]`。核心模式的 clock 從 port 直接進 FF，本來就是 ideal；PAD 模式中間隔了一顆 PAD，沒設的話，PT 寫出的 SDF 會把 wire-load 估出來的高扇出 clock net 延遲寫進去（例：實測 2.3 µs，fast 閘級模擬直接失敗）。PAD 本身的延遲寫在 `reports_<corner>/pad_delay_in.rpt`、`pad_delay_out.rpt`。

## 5. 閘級模擬（SDF）

- **目的**：netlist 加上 cell／wire 延遲後再跑一次功能，抓 STA 抓不到的問題，例如 X 傳播、reset 時序、tb 取樣時間。
- **指令**：`vcs ... <netlist> -v <cell model> +define+SDF +neg_tchk +maxdelays`（或 `+mindelays`）。CBDK 用 `tsmc13_neg.v`；SAED32 用 `saed32nm.v`。
- **怎麼確認**：功能 PASS；SDF annotation `Total errors: 0`；log 沒有 `$setuphold`／`$recrem`／`$width` 違規。warning 要逐一分類（`run_gate_sim.sh` 會用 `+sdfverbose` 全部列出，寫到 `sdf_warnings.txt`）。SAED32 只容許兩種：async reset flop 的 `$removal`（cell model 沒有這個 check，每個帶非同步 reset 的 DFF 一個），以及繞線後 SDF 跨階層的 INTERCONNECT `SDFCOM_IWSBA`（VCS 明講延遲仍會註入）。出現其他 warning 就判 FAIL。PAD 模式下 PAD 的 IOPATH 必須註入成功（PAD model 有 specify），沒註入（`SDFCOM_IANE`）也算失敗。
- **比賽評分**：IC Contest 的 A 級要求所有 pattern 都通過 gate-level 模擬；分數 = 模擬時間 × Total cell area（越小越好）。

## 6. APR（IC Compiler II）

依序是 **NDM → floorplan → power → place → CTS → route → ECO → finish**（DRC 有 M1 細條時再加 **drc_patch → finish**），每步 `save_block -as <stage>`，出錯可以回到上一步。

| 步驟 | 指令重點 | 檢查 |
|---|---|---|
| NDM | `icc2_lm_shell`：`create_workspace` → `read_db` → `read_lef` → `commit_workspace` | `check_workspace` |
| floorplan | `initialize_floorplan -core_offset`、routing direction、`set_ignored_layers`、`place_pins` | `check_design -checks pre_placement_stage` |
| MCMM | `create_mode/corner/scenario`、`read_parasitic_tech`（TLU+）、各 corner 的電壓溫度 | `report_pvt` 沒有 mismatch |
| power | ring（M7/M8）→ mesh（M6/M7）→ std cell rail（M1）、`compile_pg`、`create_pg_vias` M1→M6（被 M7 擋住的 rail 用 `-drc no_check` 補） | `check_pg_connectivity` 浮接 = 0、`check_pg_drc` |
| place | `add_tie_cells`、`place_opt`、`connect_pg_net` | `check_legality`、`report_qor` |
| CTS | 解除 ideal／dont_touch clock、`set_lib_cell_purpose -include cts`、`clock_opt` | `report_clock_qor` |
| route | `route_auto`、`route_opt` | `check_routes`（DRC／open／short = 0）、`check_lvs` |
| ECO | 讀 `report_constraints` 違規 pin → `insert_buffer`／`size_cell` → `route_eco` | `report_constraints` 無 VIOLATED |
| finish | filler、PG terminal、`write_gds -merge_files`、兩份 netlist | 同上，加上 GDS 能被 ICV 讀 |

- **兩份 netlist**：功能／時序用 `-exclude {physical_only_cells pg_netlist}`；LVS 用 `-include {pg_netlist physical_only_cells filler_cells}`。有 PAD 時還要加 `pad_cells pad_spacer_cells corner_cells`。
- **ICC2 的 SPEF** 是繞線估計值，不能當 signoff PEX。

### 6-PAD. 加 IO PAD ring（`USE_PAD 1`）

- **為什麼要 PAD**：晶片的 port 最後要打線到封裝。PAD 負責推板級負載（1 pF 等級，核心 cell 推不動）、做 ESD 保護，並從 VDDIO 供 IO 電壓。不加 PAD 的「核心」只能當成 IP block。
- **完整說明**：PAD 的種類、怎麼選、怎麼排、corner pad、怎麼確認用對，見第 11 節。
- **流程差別**：PAD 從第 0 步就在設計裡（見第 0 節），合成 netlist 已經含 wrapper 與 PAD 實例（input 用 `I1025_NS`、output 用 `D4I1025_NS`），APR 直接讀它。APR 改用 `apr_pad_ring.tcl`：
  1. die 由 PAD 數決定：每邊放 ⌈N/4⌉ 個訊號 PAD 加一對電源 PAD，PAD 寬 40、深 300 µm，四角放 CORNER，空位補 FILLER40。PAD ring 要連續。
  2. 四組電源：核心 VDD/VSS 由上下邊的 `VDD_NS`／`VSS_NS` 供應，IO 電源 VDDIO/VSSIO 由左右邊的 `IOVDD_EW`／`IOVSS_EW` 供應。左右邊一律用 `_EW` cell，不要把 `_NS` 轉 90 度。每個 corner 的 VDDIO 電壓不同（2.25／2.5／2.75 V），要對 PAD 的 PG pin 各自 `set_voltage`。
  3. 訊號 port 的 terminal 放在 PADIO 的 MRDL pin 上（GDS 輸出時文字改寫到 M9，見 pitfalls），電源 port 的 terminal 放在 core ring（VDD/VSS）與電源 PAD 的 M4 條（VDDIO/VSSIO）上（`pad_pg_terminals`）。不要用 `place_pins`。
  4. core ring 建好後，從修正版 IO LEF 讀電源 PAD 的 M4 電源條，拉線接到 core ring。這條線沒接上，核心就沒有電源可用。
  5. PAD 一律設 `set_dont_touch`，IO library 設 `set_dont_use`。
- **怎麼確認**：`check_routes` 乾淨；`check_pg_connectivity` 全部 0 浮接；繞線後 PT／Formality／SDF 模擬 PASS；DRC `RESULTS: CLEAN`、LVS `Final comparison result:PASS`（和核心一樣）。IO library 要先經過 `fix_io_lib.py` 修正，原因見 pitfalls。
- **省略會怎樣**：只有核心的時序沒有算到 PAD 延遲（例：某設計繞線後 PT 實測：input PAD `I1025_NS` 0.18–0.35 ns；output PAD `D4I1025_NS` 推 1 pF 時 0.79 ns（fast）、1.11 ns（typical）），也沒驗證 1 pF 輸出負載。要拿去封裝或接板子的設計，時序與負載的結論都不成立。

## 7. DRC / LVS（IC Validator）

- **DRC**：`icv -i <gds> -c <top> <drc runset>`，看 `<top>.RESULTS` 的 `RESULTS: CLEAN`，以及 NOT EXECUTED 的規則數。GDS 要 merge 標準元件 GDS，否則只是 abstract 檢查。
- **LVS**：`icv_nettran` 把含 PG 的 Verilog 加上 cell CDL 轉成 SPICE，再用 `icv -s schematic.sp`。看 `<top>.LVS_ERRORS` 的 `Final comparison result:PASS`。
- **blackbox LVS**（只比對 cell 連線，不展開電晶體）與電晶體層級 LVS 不同，回報時要寫清楚是哪一種。

## 8. 寄生萃取（StarRC）

- **目的**：從實際繞線幾何萃取 RC，取代 wire-load 與 ICC2 估計值。
- **設定**：`BLOCK`、`NDM_DATABASE`、`TCAD_GRD_FILE`（nxtgrd：Cmax／nominal／Cmin）、`MAPPING_FILE`、`NETLIST_FORMAT: SPEF`。
- **corner 配對**：slow↔Cmax、typical↔nominal、fast↔Cmin（與 APR 的 TLU+ 一致）。

## 9. 繞線後 STA／LEC／模擬

- **STA**：`read_verilog routed.v` → 約束 → `set_propagated_clock` → `read_parasitics <spef>` → `report_annotated_parasitics -check`（有驅動與負載的 net 都要註入）→ setup／hold。
- **Formality**：RTL 對 routed.v，沿用 DC 的 SVF。
- **SDF 模擬**：用 PT 寫出的 post-route SDF，三個 corner × min／max 都跑。
- 這一步全部通過，才能說「無 PAD 核心」完成。另外還要列出沒做的項目：PAD、antenna、SI、IR／EM、OCV、金屬溫度等。

## 10. 專案目錄與交付慣例

```
<proj>/
  rtl/  tb/  patterns/  constraints/
  scripts/            # 從 templates/ 複製後修改；flow_config.tcl 放這裡
  runs/<stage>/       # 每階段的執行目錄與報告，可隨時刪除重跑
  docs/               # 報告、教學
  deliverables/       # 繳交檔，附 SHA256
```

IC Contest 繳交（附錄三）：`<DESIGN>.v`、`<DESIGN>_syn.v`、`<DESIGN>_syn.sdf`、`<DESIGN>_syn.ddc`、`report.txt`，放在 `result_000/` 再 `tar cvf`。`report.txt` 的格式要照 PDF：Level、Synthesis area、Time（RI=5＋RI=11 模擬時間）、Total mismatch、CYCLE、HDL simulator。

---

## 11. IO PAD 完整說明

這一節把 PAD 從頭講一次：它是什麼、製程給了什麼、怎麼選、流程每一步多做什麼、怎麼排、怎麼確認用對。SAED32 的部分對照它的 IO library 手冊（`lib/io_std/doc/SAED32.28nm_IO_Standard_Cell_Library_b100_01312012.pdf`）。標「業界常見做法」的是一般原則，不是 SAED32 手冊的規定。

### 11.1 PAD 是什麼、為什麼要

晶片做好後，要用金線（打線，wire bond）接到封裝的接腳。金線不能打在你的電路上，要打在晶片邊緣一圈專門的元件上，這種元件叫 PAD。PAD 做四件事：

- **打線的落點**：每顆 PAD 有一塊大金屬片給金線焊上去。
- **推得動外面的負載**：板子上的線和其他晶片是 pF 等級，核心的小 cell 推不動，要靠 PAD 裡的大驅動電路。
- **電壓轉換**：核心 1.05 V，晶片外 2.5 V（SAED32），PAD 負責兩者之間的轉換。
- **ESD（Electrostatic Discharge，靜電放電）保護**：PAD 裡的二極體把靜電導走，避免打壞核心電晶體（SAED32 手冊：HBM 2 kV）。

不加 PAD 的設計只能當 IP block，不能直接封裝。

### 11.2 製程提供哪些 PAD 資料、怎麼用

SAED32 的 PAD 資料在 `lib/io_std/`：

| 資料 | 內容 | 哪一步用 |
|---|---|---|
| `db_nldm/*.db`、`.lib` | 每顆 PAD 的延遲、負載能力、電壓，一個 corner 一份 | 合成、STA；`pad_tools.py` 從這裡查 PAD 延遲 |
| `verilog/` | PAD 的行為 model（沒有延遲） | RTL／閘級模擬 |
| `lef/` | 外框大小、pin 位置、繞線阻擋 | 建 NDM、APR |
| `gds/` | 真正的版圖 | APR 輸出 GDS 時併進去，給 DRC／LVS |
| `lvs/*.cdl` | PAD 裡的電晶體電路 | LVS |
| `doc/*.pdf` | 有哪些 PAD、電壓、電流上限、結構 | 選 PAD、決定電源 PAD 數量 |

這些都是固定的元件資料。製程**不會**告訴你 PAD 要擺哪裡、電源怎麼接，這部分要自己寫腳本（11.5）。

SAED32 的這幾份資料彼此有幾處不一致，所以流程先用 `fix_io_lib.py` 產生修正版副本（PDK 不動），原因見 `pitfalls.md`「PAD」。正常的商用製程不需要這一步；遇到 library 有錯時，業界是回報給廠商修正。

### 11.3 SAED32 有哪些 PAD、怎麼選

| 種類 | SAED32 名稱 | 什麼時候用 |
|---|---|---|
| 輸入 | `I1025` | 一般輸入 |
| 輸入（Schmitt trigger，施密特觸發，抗雜訊） | `ISH1025` | 訊號慢或雜訊大，例如 reset、按鍵 |
| 輸出 | `D4I1025`、`D8I1025`、`D12I1025`、`D16I1025` | 一般輸出；數字是驅動電流（mA），負載大選大的（手冊列了 2 mA 版，但 library 裡沒有） |
| 雙向 | `B4I1025`～`B16I1025`（`BxISH1025` 為 Schmitt 版） | inout port；公版目前不支援，`pad_tools.py` 遇到 inout 會報錯 |
| 核心電源 | `VDD`、`VSS` | 核心 1.05 V 電源；手冊標每顆 40 mA |
| IO 電源 | `IOVDD`、`IOVSS` | PAD 自己的 2.5 V 電源；每顆 40 mA |
| 類比 | `A1825`、`AR1825`、`AVDD`、`AVSS` | 類比訊號與類比電源 |
| 角落 | `CORNER`、`CAPCORNER` | 四個角，見 11.8 |
| 填空 | `FILLER`、`FILLER01`～`FILLER50` | PAD 之間的空位；數字是寬度（µm），讓電源環連續 |
| 斷開 | `BREAKCORE`（只留 IO 電源）、`BREAKIO`（只留核心電源） | 要把電源環切成好幾段時 |
| 去耦電容 | `CVDDVSS`、`CIOVDDIOVSS` | 放在 PAD ring 裡多加穩壓電容（約 70 pF） |

每種都有 `_NS` 與 `_EW` 兩個版本：**`_NS`（直的，40 寬 × 300 高）放上下邊，`_EW`（橫的，300 × 40）放左右邊**。不要把 `_NS` 轉 90 度放在左右邊：裡面電晶體的方向會錯，DRC 報幾千個 PO／CO 錯誤。

輸出驅動電流怎麼選：看 `.lib` 推 1 pF 的延遲。電流越大越快，但耗電與同時切換雜訊也越大。公版輸出用 `D4I1025`（4 mA）：slow corner 推 1 pF 約 1.2–1.4 ns，對 30–50 ns 週期夠用。

### 11.4 加 PAD 的完整流程

PAD 從第 0 步就加，不是到 APR 才加（理由見第 0 節）：

| 步驟 | 加 PAD 後多做的事 | 公版 |
|---|---|---|
| 0. 規劃 | 每個 port 用哪種 PAD、幾顆電源 PAD、晶片多大 | `pad_tools.py`、`flow_config.tcl` |
| 0. wrapper | 產生 `${DESIGN}_chip`：每個 port 接一顆 PAD，裡面接原設計 | `pad_tools.py wrapper` |
| 0. PAD model | 從 `.lib` 查延遲，產生帶 `specify` 的 PAD 模擬 model | `pad_tools.py padmodel` |
| 1. RTL 模擬 | 模擬 `${DESIGN}_chip`，訊號經過 PAD，看得到延遲 | `run_rtl_sim.sh` |
| 2. 合成 | PAD `dont_touch`；輸出負載 1 pF；port 到 PAD 的打線 `set_resistance 0` | `dc_syn.tcl`、`constraints_chip.sdc` |
| 4. STA | 路徑起訖點是 PAD，延遲含 PAD；clock PAD 後設 ideal network | `pt_prelayout.tcl` |
| 5. 閘級模擬 | SDF 的 PAD 延遲註入 PAD model | `run_gate_sim.sh` |
| 6. APR | 依 PAD 數算 die；擺 PAD／corner／filler；四組電源；電源 PAD 接 core ring；port 綁在 PAD 上；clock PAD 後插 buffer 當 clock tree 起點 | `apr_pad_ring.tcl`、`apr_core.tcl` |
| 7. DRC／LVS | GDS 併入 PAD 版圖；LVS 加入 PAD 的 CDL | `apr_finish.tcl`、`run_icv_drc.sh`、`run_icv_lvs.sh` |
| 8、9 | 和核心相同，top 是 `${DESIGN}_chip` | |

### 11.5 PAD 的腳本做什麼

製程只給 PAD 元件，怎麼擺、怎麼接要自己寫；業界也是每個專案自己寫，或用公司內部模板。

| 腳本 | 做什麼 |
|---|---|
| `pad_tools.py` | 讀 RTL port 產生 `${DESIGN}_chip.v` 與 PAD 擺放計畫；從 `.lib` 查 PAD 延遲產生模擬 model；繞線後 netlist 轉成模擬用版本 |
| `apr_pad_ring.tcl` | `pad_floorplan`：依 PAD 數算 die、擺 PAD／corner／filler。`pad_pg_setup`：建立 VDD／VSS／VDDIO／VSSIO、設定各 corner 的 IO 電壓、訊號 port 的 terminal。`pad_ring_to_core`：電源 PAD 的 M4 電源條接到 core ring。`pad_pg_terminals`：電源 port 的 terminal 放在真正的電源金屬上 |
| `constraints_chip.sdc` | 1 pF 負載、打線電阻設 0 |
| `fix_io_lib.py` | 只因為 SAED32 PAD 資料不一致才需要 |
| `drc_pad_classify.py`、`lvs_pad_classify.py` | FAIL 時把錯誤分到核心／PAD 區，幫忙找問題（不改變判定） |

### 11.6 怎麼確認 PAD 用對了

全部都要成立：

1. **功能**：RTL 模擬 `${DESIGN}_chip` PASS，而且看得到 PAD 延遲（結果和沒 PAD 時一模一樣，代表 PAD model 沒延遲）。
2. **時序**：最差路徑有經過 PAD 且 slack ≥ 0；輸出負載確實是 1 pF，不是預設幾 fF。
3. **APR**：PAD 圍成一圈不中斷、四角都有 corner；`check_pg_connectivity` 四組電源全部 0 浮接；每個 port 都綁在對應 PAD 上。
4. **DRC**：`RESULTS: CLEAN`，PAD 區域的錯誤也算錯誤。
5. **LVS**：`Final comparison result:PASS`，PAD 裡的電晶體與二極體也要對上。
6. **繞線後模擬**：用實際線延遲跑 `${DESIGN}_chip` 仍然 PASS。

### 11.7 最常要注意的點

- **一開始就決定**：中途才加 PAD，合成 top 會變，前面每一步都要重跑。
- **輸出負載要改**：沒改成 1 pF，時序結論是假的。
- **上下 `_NS`、左右 `_EW`**：不要自己轉。
- **電源 PAD 要夠（業界常見做法）**：核心總電流 ÷ 每顆電源 PAD 的電流上限（SAED32 手冊 40 mA）= 至少要幾對；輸出 PAD 同時切換會讓 IO 電源跳動，每幾顆輸出 PAD 要配一對 IO 電源 PAD（實際比例看廠商的 SSO 規範，SSO = Simultaneous Switching Output）。不夠時 DRC／LVS 照樣會過，但晶片可能不穩。
- **電源 PAD 一定要真的接到 core ring**：沒接上核心就沒電；用 `check_pg_connectivity` 確認。
- **PAD 一定要 `dont_touch`**：否則合成或 APR 可能改掉、刪掉 PAD。
- **clock 經過 PAD 之後**：ICC2 不在 PAD 的輸出 net 上建 clock tree（CTS-053），要在 PAD 後插一顆 buffer 當起點。
- **VSS 與 VSSIO**：手冊有 `DIOVSSVSS` 二極體，表示原本設計是兩者分開；但 SAED32 核心和 IO 共用 P 型基板，矽片上是連在一起的，所以公版的 LVS 把兩者當同一個 net（代價：兩者之間的金屬短路抓不到）。

### 11.8 通常怎麼排（業界常見做法）

- **先判斷 pad-limited 還是 core-limited**：PAD 一圈排下來比核心大，就是 pad-limited（例：49 個 PAD → die 1200 µm，核心只用一部分），可以縮 PAD 間距、選窄的 PAD、減少 port。核心比較大就是 core-limited，PAD 之間會有空位要補 filler。
- **電源 PAD 分散在四邊**：不要擠在同一邊，核心各處電壓才平均。公版每邊放一對：上下邊核心電源、左右邊 IO 電源。
- **輸出 PAD 附近要有 IO 電源 PAD**。
- **clock 輸入 PAD 放在某一邊的中間附近**，到核心的距離短。
- **相關訊號放同一邊**（例如同一組匯流排），板子上拉線方便。

### 11.9 Corner pad 是什麼、怎麼選

PAD 一圈排下來，四個角是空的。但 PAD 裡的四條電源環（VDD／VSS／VDDIO／VSSIO）要繞整圈才連得起來，角落要放一塊把兩邊電源環接起來的元件，這就是 corner pad。它沒有打線金屬、沒有電路，只讓電源環轉彎連通。

| 名稱 | 差別 | 什麼時候用 |
|---|---|---|
| `CORNER` | 只把電源環接起來 | 一般情況（公版用這個） |
| `CAPCORNER` | 再加上 VDD／VSS 之間的去耦電容 | 核心電源雜訊大、想多一點穩壓時 |

四個角都要放，方向依角落旋轉（公版：左下 R270、右下 R0、右上 R90、左上 R180）。

兩種 corner 的 LEF 都很複雜（各約 11 萬個形狀），預設設定建 io.ndm 要 40 分鐘以上；`build_ndm.tcl` 已改用 `block_and_trim`，幾秒就建好，和選哪一種無關。
