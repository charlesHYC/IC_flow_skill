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
