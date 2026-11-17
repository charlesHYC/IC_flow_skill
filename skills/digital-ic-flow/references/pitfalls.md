# 實際踩過的坑

用例子設計驗證公版時真的遇到的錯誤與解法；括號裡的數字是當時的實測值，換設計會不同。

格式：**症狀 → 原因 → 解法**。遇到錯誤先搜尋這份文件。

## 環境與工具啟動

- **階段被中斷（Ctrl-C、kill），`status.txt` 卻寫 PASS** → bash 收到 SIGTERM 時，`EXIT` trap 讀到的 `$?` 可能是 0。`run_stage.sh` 另外攔 TERM／INT／HUP，被中斷一律記 FAIL（REFRACT 實測：Formality 被 kill、報告是空的，舊版仍記 PASS）。

- **Formality／LC／ICV 啟動就 crash：`symbol lookup error: /lib64/libkrb5.so.3: undefined symbol krb5int_c_deprecated_enctype`**
  → 工具自帶的 libk5crypto 與系統 libkrb5 版本不合。
  → `LD_PRELOAD=/lib64/libk5crypto.so.3`（Formality／LC）或 `LD_PRELOAD=/usr/lib64/libkrb5support.so.0`（ICV、Verdi）。不要修改安裝目錄。
- **`create_lib`／`open_lib` unknown command** → 用了 `dc_shell`；NDM 需要 `dcnxt_shell -topo`。
- **`report_lib` 沒有輸出** → 這個指令要靠 Library Compiler。可以直接用 `lc_shell`（LC 2024 版也有 krb5 問題，可改用 2022.03）。
- **一定要先 `source /.bash_EDA`**：這是本機的 EDA 環境（Synopsys 路徑與 license <license server>）。
- **Verdi／DC GUI 截圖要有 display** → 啟動 `Xvfb :N`、設 `DISPLAY=:N`；DC 用 `gui_write_window_image`。Verdi 在 `-nogui` 下不會畫波形，要跑真正的 GUI。

## 合成（DC）

- **UCN-4（change_names 衝突）** → `define_name_rules verilog -replacement_char x` 後再 `change_names -rules verilog -hierarchy`。
- **netlist 出現 assign、port 直接相連** → `set_fix_multiple_port_nets -all -buffer_constants [get_designs *]`。
- **constraint 報告一直有 max_leakage_power VIOLATED** → 預設上限是 0，不是時序問題，但也不要從報告中刪掉。
- **換製程後時序或負載結果怪異** → 單位不同。CBDK：pF／kΩ；SAED32：fF／MΩ。`set_load 1` 要換成 `1000`，`set_drive 0.1` 要換成 `0.0001`。先 `report_units`。
- **SAED32 上 1 pF 輸出負載怎樣都修不掉** → 核心 cell 最大 max_capacitance 是 168 fF（NBUFFX32_RVT）。無 PAD 核心改用 20～50 fF；1 pF 應放在晶片 port，由 output PAD 驅動。
- **SAED32：DC 乾淨，PT fast corner 卻大負 slack（單一 gate 延遲 7～9 ns）** → FF library 的 wire-load RC 在高扇出 net 上暴增。只對 SS library 合成時，DC 看不到這個問題。照 geofence 的做法：target 用 FF library、link 同時放 SS 與 FF、wire-load 用 SS 的 `ForQA`（mode top）、`set_dont_use *X0_RVT *X1_RVT`、`set_max_fanout 1.0`。（skill smoke test 實測：只用 SS target 時 fast setup 為 −6.5～−15.5 ns）
- **PT 報 `SEL-005 Nothing matched for lib_spec` 在 set_wire_load_model** → wire-load 模型所在的 library（SS）沒放進 link_path。把它加在 link_path 最後面，不要排序：PT 會把 cell 連到 link_path 第一個符合的 library，排序後 typical corner 會被連到 SS（兩個 corner 的數字會完全一樣，這就是徵兆）。
- **DC constraint 乾淨，PT 仍有 max_capacitance 違規（差一點點，例如 16.99 fF > 16 fF）** → PT 檢查時 pin 電容取 rise/fall 範圍的上限，DC 用標稱值（REFRACT 實測：同一條 net DC 15.99 fF、PT 17.62 fF，84 個 pin）。公版在 DC 記憶體內把 max_capacitance 收緊到 85%（`dc_syn.tcl` 的 `MAXCAP_DERATE`，SAED32 與 CBDK 都做，PDK 檔案不動）。差距比 15% 大時要再調低：推很多 XNOR／XOR 的 net（乘法器）pin 電容上限比標稱值高約 45%，例：某設計 PAD 版 DC 26.3 fF、PT 35.0 fF（pin 電容 18.8 → 27.5 fF，走線 7.5 fF 兩邊相同），上限 32 fF，`MAXCAP_DERATE` 要設到 0.70。
- **PT 報非同步 reset 的 recovery／removal 違規，DC 報告卻完全沒有** → DC 預設不分析 recovery／removal（`enable_recovery_removal_arcs` 是 false），看不到 reset 路徑，也不會幫高扇出的 reset 建 buffer tree。REFRACT 實測：約 600 個 DFF 的 `RST` 只有一顆 INVX8 推，fast corner recovery −3.26 ns。公版已 `set_app_var enable_recovery_removal_arcs true`。
- **打開 recovery／removal 後，PT slow／typical 仍有 removal 違規** → DC 用 FF library 修 hold，但 removal 時間在 SS 最大（REFRACT：`RST` 只過一個反相器到 `RSTB`，slow −0.20 ns，609 個 DFF）。公版改成 `set_operating_conditions -max <FF> -max_library <FF> -min <SS> -min_library <SS>`：setup 用 FF、hold／removal 用 SS 分析。REFRACT 面積 17375 → 19844（+14%，多半是 reset 路徑的延遲 buffer）。
- **reg-to-reg 差一點點（例如 −0.002 ns）** → `report_timing -significant_digits 4` 確認，再做 `compile_ultra -incremental`，或加強 `group_path -weight`。

## Function 驗證（Formality）

- **FM-503 Register … not found in the reference（暫存器在 `DP_OP_*` 底下）** → `-spg` 加 retime 把暫存器推進 datapath。改用 `compile_ultra -retime -scan`。
- **verify 卡很久（geofence＋compile_ultra 實測 >20 分鐘仍在 Verifying）** → compile_ultra 重組乘法器等 datapath，等價證明變難。改回 `compile`（geofence 實測很快 PASS），或保留 compile_ultra 但確定 SVF 有讀到、考慮 `-no_autoungroup`。
- **大量 unmatched black box** → 沒讀 SVF、沒設 `hdlin_dwroot`，或 DC 沒開 `hdlin_enable_hier_map`。

## Gate-level sim

- **`SDFCOM_CFTC Cannot find timing check $removal(posedge RSTB,posedge CLK)`（DFFARX*）** → 同一個原因：cell model 沒有 removal check。這是 warning，不影響功能結果，但 reset 的 removal 時序只有 STA 有檢查。`run_gate_sim.sh` 只容許這一種，其餘 SDF warning（包括 PAD 上的 `SDFCOM_IANE`）都判失敗。舊版公版只檢查 error，所以這 17 個 warning 一直沒被注意到（2026-11-12 發現）。
- **SAED32 SDF 有 `REMOVAL`，VCS 報 annotation 錯誤** → 舊版 SAED cell model 把 removal 寫成 clock-to-reset 的 HOLD。只在**模擬副本**把 `(REMOVAL …)` 改成 `(HOLD …)`，並做反向比對，確認只改這一處。原始 SDF 要保留。（geofence `scripts/saed32/gate.py`）
- **`SDFCOM_IWSBA` INTERCONNECT will still be annotated（只在繞線後 SDF）** → 保留 DesignWare 階層時（例如 REFRACT 的 `sub_97_2`），跨階層的 INTERCONNECT 會被提醒，VCS 明講延遲仍會註入，不是漏註入。`run_gate_sim.sh` 已列為已知 warning。
- **TFIPC 警告** → 多半是 DFF 未使用的 QN 輸出沒接，不是輸入沒接，列入說明即可。
- **官方 tb gate-level 取樣太早而失敗** → 檢查 tb 的取樣時間是否在 clock-to-Q 加輸出延遲之後；修改 tb 時只改模擬副本，並說明理由。

## APR（ICC2）

- **CTS 後 clock 沒有 buffer** → 合成留下的 `set_dont_touch_network`／ideal network 沒解除。CTS 前要 `set_dont_touch_network -clear [all_clocks]`、`remove_ideal_network`。
- **I/O path 時序與 PT 對不上** → ICC2 預設會在 input delay 加上 clock network latency。加 `-network_latency_included`。
- **APR 的 I/O 約束比 signoff 鬆，繞線後 PT 才出現大量 hold／removal 違規** → APR 的每個 I/O delay 只能比 SDC 嚴。REFRACT 實測：`apr_core.tcl` CTS 後的 input min delay 原本是 0.2（SDC 是 0），ICC2 以為 `RST` 晚 0.2 ns 才到、沒修 removal，繞線後 PT fast corner 619 個 removal 違規（−0.07 ns）。公版已改成 0。
- **`route_opt` 後還剩少數 short／spacing，增量 `route_detail` 也清不掉** → cell 剛好在 M6 電源條正下方，電源條往下的 via stack 佔掉 M2／M3 走線空間，訊號線短到 VSS（REFRACT 實測 3 個）。`apr_core.tcl` 的修正回圈：先拆有違規的 net 重繞，還在的把相連的 cell 往右移 2 um、legalize 後再重繞。重繞時 clock net 也要包含，否則移過 DFF 後 clock 會斷開（實測 open net 1）。
- **重跑 APR 立刻失敗：`Library directory … already exists (LIB-009)`** → 上一次的 design library 還在。`apr_core.tcl` 已在 `create_lib` 前 `file delete -force $NDM_LIB`。
- **`save_block -as X` 之後還在改舊 block** → `save_block -as` 不會切換 current block，要再 `open_block X`。
- **report_timing 列出所有 scenario** → 加 `-scenarios [get_scenarios functional_ss]`。
- **LVS：VDD 斷成數十個 layout net（"open layout net"），`check_pg_connectivity` 顯示 floating wires** → `compile_pg` 只在 ring 與 mesh 的交點放 via，M1 rail 到 M6/M7/M8 的 via 要自己補：`create_pg_vias -nets {VDD VSS} -from_layers M1 -to_layers M6 -via_masters {VIA12SQ_C … VIA56SQ_C}`，M6→M7、M7→M8 也一樣。（skill smoke test 實測：沒補時只有 49 個 PG via；REFRACT 補完約 1550 個）
- **ICV DRC `M1.W.2.1`（細 M1 接寬 M1，寬度 < 0.06）** → 繞線的 via enclosure 在 cell pin 旁留下細條。在同一 net 上畫 M1 矩形，蓋住「pin ∪ 錯誤區」：`templates/06_apr/apr_drc_patch.tcl` 會自動讀 ICV 錯誤檔處理。錯誤區常常只是貼著 pin 邊緣，搜尋時要放大約 0.01 um。
- **PG fat via 造成上千個 ICV DRC** → 改用 tech file 現有的方形 via（VIA12SQ…VIA67SQ）手動建立。
- **tie cell 加不進去** → TIEH／TIEL 在 Liberty 是 dont_use／dont_touch，兩個屬性都要解除。
- **write_verilog 漏 PAD** → 要明列 `pad_cells pad_spacer_cells corner_cells`。filler 也要另外列 `filler_cells`（`physical_only_cells` 不含 filler）。

## PAD（USE_PAD=1，SAED32 io_std wire-bond）

2026-11-12 用 geofence 跑 `USE_PAD=1` 全流程時遇到的問題，都已經寫進公版：

- **PAD 版 APR 後 clock 線 max_transition 大量違規（例：`core_CLK` 0.81 ns > 0.25 ns），`clock_qor.rpt` 的 repeater 是 0，APR ECO 越修越多** → log 裡有 `CTS-053 The net 'core_CLK' will not be buffered because it is a pad net`：clock PAD 輸出的 net 直接接在 PAD 上，ICC2 不在 pad net 上建 clock tree，PAD 只能直接推所有 DFF。DFF 少時推得動、看不出問題（例：小設計可以過），多時就爆掉（例：619 個 DFF）。`apr_core.tcl` 在 CTS 前於 `pad_<clk>/DOUT` 後插一顆 buffer（`CLK_ROOT_BUF`）並設 `dont_touch`（`clock_opt` 會先移除 clock 線上原有的 buffer，不設就被拆掉），CTS 從它的輸出開始建 tree；例：repeater 0 → 15 顆。
- **io.ndm 要建 40 分鐘以上（卡在 `CAPCORNER.frame` 的 FRAM-066 warning）** → CORNER 的 LEF 有 6 萬多個 OBS，預設的 frame 產生非常慢（geofence 實測 42 分鐘）。`build_ndm.tcl` 在 IO workspace 改用 `configure_frame_options -mode block_and_trim`，加上 `lib.physical_model.block_all used_layers` 和 `merge_metal_blockage true`，就降到幾秒（geofence `io_abstract_v2.tcl`）。
- **`Error: Cannot create procedure named 'place_io' - existing command`** → `place_io` 是 ICC2 內建指令，自訂 proc 不能用這個名字（公版改叫 `pad_place_cell`）。
- **某個階段失敗時 `run_stage.sh` 什麼都沒印就結束** → `set -e` 下工具 exit 1 會直接終止腳本，走不到最後的 FAIL 訊息（舊版公版 DC 失敗時就是這樣）。工具呼叫一律加 `|| true`，由最後的成功標記判定。標記要在**行首**（`grep "^DC_PASS"`）：DC 會把執行過的 tcl 指令印回 log，用子字串比對會把 `puts "DC_PASS"` 這行誤認為通過。
- **在 `source` 的子檔出錯後 icc2_shell 停在提示字元，不會結束** → 工具在等 stdin。`run_stage.sh` 用 `exec </dev/null`，讓它直接結束並回報錯誤。
- **`Port 'wire' is not defined in module terminal list`（SVR-8）** → ICC2 的 Verilog reader 不吃 `input wire clk;`。wrapper 要用 Verilog-1995 寫法（`input clk;`）。另外它也不吃 `` `ifdef ``，所以 `pad_tools.py` 產生的 wrapper 是純結構、沒有 `` `ifdef ``（RTL 模擬、DC、Formality 共用同一份）。
- **IO Verilog model 的輸出一直是 X** → `RECEIVER`／`DRIVER` 會檢查 `VDD==1 && VSS==0 && VDDIO==1 && VSSIO==0`。公版的 PAD model（`pad_tools.py padmodel` 產生的 `io_pad_sim.v`）在 model 內用 `supply1`／`supply0` 接這四個 pin，所以 RTL、合成後的 netlist（沒有 PG）都能直接模擬。繞線後含 PG 的 netlist 仍要用 `pad_tools.py simnet` 拿掉 std cell 上的 `.VDD/.VSS`（std cell model 沒有 PG port）。PG 接得對不對由 LVS 檢查，不靠模擬。
- **IO Verilog model 沒有延遲（PAD 在模擬裡是零延遲）** → 官方 `saed32nm_io_wb.v` 沒有 specify block，SDF 的 PAD IOPATH 也註入不進去（`SDFCOM_IANE`）。`pad_tools.py padmodel` 從 IO library NLDM 表查出延遲，產生同名的 PAD model（加 specify，邏輯沿用官方 RECEIVER／DRIVER），模擬時放在 source、官方 model 用 `-v`，同名 module 以 source 為準。RTL 模擬用 specify 預設值，Gate-level sim 由 SDF 覆蓋。
- **PAD 模式 DC／佈局前 PT 出現 -19～-22 ns setup，路徑從 input port 經過 PAD（`pad_reset/DOUT` 45 ns）** → port 到 PADIO 的 net 接了 PADIO 的 2.4 pF pin cap，wire-load 的電阻乘上它就是幾十 ns。這段其實是打線，佈局前要 `set_resistance 0`。DC 裡要先 `set_dont_touch` 這些 net，否則 compile 會把電阻設定拿掉（`OPT-801 Removing some annotated net resistances`）。
- **PAD 模式 fast Gate-level sim 跑到 tb timeout，但 STA 全部 PASS** → SDF 裡 `INTERCONNECT pad_clk/DOUT …/CLK` 是 2321 ns。clock 經過 clock PAD 後，PT 不再把後面的 net 當成 ideal clock net，write_sdf 會把 wire-load 估出的高扇出延遲寫進去；STA 本身用 ideal clock，所以看不出來。佈局前 PT 要 `set_ideal_network [get_pins pad_<clk>/DOUT]`。
- **`icv_nettran: Cell 'CORNER' is not defined`** → IO 的 CDL 沒有 `CORNER`／`FILLER*` 的 subckt。LVS netlist 要把這兩種實例刪掉（GDS 裡的形狀照樣會被萃取）。`write_verilog` 不能同時下 `-include` 和 `-exclude`，而電源 PAD、SHFILL 又屬於 `physical_only_cells`，所以 `apr_finish.tcl` 是先全部寫出，再用 regsub 刪掉。
- **`VDD_NS: Port 'VDDPAD' not declared`（NETTRAN-904 warning）** → CDL 裡電源 PAD 的打線點就是 VDD 本身，沒有獨立的 port。這只是 warning，可以忽略。
2026-11-17 用 REFRACT 跑 `USE_PAD=1`，把全晶片 DRC／LVS 從「只剩 IO 相關錯誤」做到 `RESULTS: CLEAN`／`Final comparison result:PASS`。下面每一項都是單獨找出、單獨驗證過的原因。前 7 項是 IO library 本身的錯，由 `fix_io_lib.py`（pad 階段）產生修正版 library 到 `runs/iofix/`；PDK 原檔不動。每一項修正前都先確認原始幾何和預期一致，PDK 版本不同就直接中止。

- **DRC：左右邊的 PAD 有幾千個 PO.W／PO.S／CO.S 錯誤** → 左右邊放的是轉 90 度的 `_NS` cell，cell 裡的多晶矽方向跟著轉錯，有方向性的規則全部報錯。左右邊改用同功能的 `_EW` cell（原始就是 300 寬 × 40 高）。`apr_pad_ring.tcl` 用 `set_reference` 換，`pad_tools.py` 也會產生 `_EW` 的 PAD model（繞線後 netlist 兩種都有）。
- **DRC：所有 PAD 的 M9 打線條都報 M9.W.2** → PDK 的 DRC runset 用中間層金屬的 5 µm 上限檢查 M9，設計規則手冊（Table 13，MT.W.2）頂層金屬是 10 µm。`fix_io_lib.py` 寫一份改成 10 的 runset 副本，`run_icv_drc.sh` 在 PAD 模式用它。
- **LVS：每個輸入 port 都和 VDDIO 併成同一個 net** → `I1025_NS／_EW` 的 PADIO M2 橫線直接穿過 VDDIO 的 M2 直線，是真的短路。M2 在 VDDIO 兩側斷開，用 VIA2＋M3 跨過去。
- **LVS：VDD／VSS PAD 的 ESD 二極體報 swapped pins** → CDL 把 `nd`／`pd` 的兩端寫反（layout 是 pd：PAD→VDDIO、nd：VSSIO→PAD）。在 CDL 副本對調。
- **DRC：PAD 內少量 VIA1.W、M2.W.2.1、M2.S.1** → 兩顆 via 疊成不合法形狀、M2 線端超出 via pad 0.001 µm、同 net M2 只差 0.036 µm。逐一修 GDS。
- **核心電源接不上 PAD／接縫 M5.S.3.3** → LEF 只在接縫寫了 0.19 µm 的 pin，GDS 裡那個位置沒有對應的金屬；真正的電源是 PAD 內 2 µm 寬的 M4 垂直條（`gen_Buses`），LEF 沒寫。照 LEF 接會碰到別的 net。把這四條 M4 照 GDS 位置加進 LEF 副本，`pad_ring_to_core` 從 M4 條拉線到 core ring。
- **晶片 LVS：輸入 PAD 裡的 level shifter 的 VDD／VSS 是浮接孤島（單顆 PAD LVS 卻會過）** → `I1025_NS` 的 level shifter M1 電源環沒有 via 接到 M4 電源條（`_EW` 版有）。單顆 PAD 是 top cell 時，同名文字把兩塊併起來，所以看不出來。在環的垂直邊（剛好在電源條正下方）補 VIA1／VIA2／兩顆 VIA3；兩顆 VIA3 是為了 VIA3.B.1，M2／M3 補小塊是為了最小面積。找法：ICV 的 layout netlist（`*.net.gz`）有每個元件的座標，看孤島的 MOS 在哪裡。
- **LVS：VDD open，PAD 的 `R_EN`／`EN` 等 125 個閘極沒接到電源；ICC2 log 有 `OPT-200 No tie cell is available`、`ZRT-511`** → SAED32 的 `TIEH_RVT／TIEL_RVT` 在 library 裡是 `dont_use`、`dont_touch`，`add_tie_cells` 一顆都插不進去，`1'b1` 變成 `*Logic1*`。std cell 旁邊有電源軌還能接上，PAD 的 pin 離電源軌很遠就變成一段浮接的線。`apr_core.tcl` 在 `add_tie_cells` 前用 `set_attribute … dont_use false`／`dont_touch false` 解除（`set_dont_use … false` 會報 CMD-012）。這一項也影響 `USE_PAD 0`。
- **LVS：VSS 和 VSSIO 在 layout 裡是同一個 net** → 這是真的：SAED32 沒有 deep N-well，核心和 IO 共用一塊 P 型基板，runset 的 `pwell = 整顆晶片 − nwell`，ptap 硬接到 pwell。核心的 VSS tap 和 PAD 的 VSSIO tap 都打在上面。試過把 runset 改成 soft connect，結果 PAD 自己有幾塊 VSS 也是靠 pwell 接起來的，改了反而 open，所以不採用。`run_icv_lvs.sh` 在 PAD 模式把 schematic 的 VSSIO 併到 VSS。**代價**：VSS 和 VSSIO 之間的金屬短路 LVS 抓不到。
- **LVS：`52 untexted layout ports`、`Missing power/ground nets`** → port 的文字要落在 GDS 裡真的有金屬的地方。訊號 PAD：LEF 說 PADIO 打線 pin 在 MRDL，GDS 的打線金屬其實是 M9（沒有 MRDL）。terminal 仍放 MRDL（放到 M9 的話 router 會繞線過去，多出一百多個繞線 DRC），`apr_finish.tcl` 用專案的 layer map 副本加一行 `T 41 39`，把 MRDL 上的文字改寫到 M9PIN。電源 PAD 根本沒有打線金屬，`pad_pg_terminals` 把 VDD／VSS 的 terminal 放在 core ring 的 M7 上、VDDIO／VSSIO 放在電源 PAD 的 M4 電源條上。座標要對齊 0.001 µm 格點（否則 DRC off_grid）。
- **`check_pg_connectivity` 的 floating terminals 不是 0** → 舊版公版把它當成 library 限制排除掉；有了 `pad_pg_terminals` 之後它就是 0，現在不排除，有浮接就 FAIL。
- **LVS 失敗後再跑一次，結果沒變** → ICV 中途出錯（例：runset 語法錯）時不會覆寫舊的 `LVS_ERRORS`，腳本會讀到上一輪的結果。`run_icv_drc.sh`／`run_icv_lvs.sh` 執行前先刪掉舊結果。
- **`drc_pad_classify.py`／`lvs_pad_classify.py`** → 現在只是診斷：FAIL 時依位置／instance 把錯誤分成 IO ring、接縫、核心，幫忙找問題在哪。它們不改變判定。

## Signoff

- **GDS pin 文字層不對，LVS 找不到 port** → GDS 匯出要用正確的 layer map（CBDK 用原附 `Astro/macro.map`；SAED32 用 `saed32nm_1p9m_gdsout_mw.map`）。
- **LVS 把 N901 與 n901 合併** → runset 的大小寫設定。改專案副本，保持大小寫敏感。
- **`icv_nettran: unknown option -sp-dollarPins`** → 新版已經預設輸出 `$PINS`，拿掉這個選項。
- **SAED32 LVS runset 直接用失敗** → PDK runset 是範例設定（`CELLNAME.gds`、`resistor`、作者路徑）。用 `templates/07_signoff/make_lvs_runset.sh` 產生副本。
- **`StarXtract: command not found`** → `/.bash_EDA` 沒有把 StarRC 放進 PATH；用絕對路徑 `/mnt/nfs/opt/EDA/synopsys/star-rcxt/cur/bin/StarXtract`。
- **ECO 一直串 buffer 還是修不掉 max_cap** → 每輪都在同一個 pin 後面再插一顆小 buffer。依實際負載挑尺寸（X4/X8/X16/X32），已經是 ECO buffer 的就 `size_cell` 換大顆，不要再串一級（`apr_eco.tcl` 已經這樣做）。
- **signoff_eco 回圈跑滿 4 輪還是 `STOP: not closed`，每輪都只剩同一顆 cell 的 max_cap 小幅超標** → 升一級（X0→X1）沒有用：SAED32 的 NAND2X0／X1、INVX0／X1、AO22X1 的 max_capacitance 都是 8 fF，要到 X2 才變成 16 fF。`apr_signoff_eco.tcl` 現在會直接挑輸出 max_capacitance 真的比較大的尺寸。每一輪要跑 finish→drc→lvs→starrc→pt_post，USE_PAD=1 時約 13 分鐘，白跑一輪的代價很高（2026-11-12 geofence USE_PAD=1 實測）。
- **繞線後 PT 只有 fast corner hold 差幾 ps（例：-0.003 ns），signoff_eco 卻回 `PASS (nothing to do)`，回圈白跑到第 4 輪** → ICC2 用估計 RC 修 hold 時剛好過，StarRC 的 Cmin 再快一點就違規。舊版 signoff_eco 只讀 max_capacitance／max_transition 段落，看不到 `min_delay/hold`。現在會在違規 endpoint（FF 的 D pin）前插 `HOLD_BUF`（預設 NBUFFX2_RVT），PT 失敗但沒有可修項目時直接 FAIL，不再空轉（例：REFRACT USE_PAD=1）。
- **StarRC 金屬溫度** → 沒有設定時是 25°C，報告要註明。
- **工具 exit 0 不代表通過** → 一律讀 `RESULTS: CLEAN`、`Final comparison result:PASS`、`Verification SUCCEEDED`、slack 數值。
