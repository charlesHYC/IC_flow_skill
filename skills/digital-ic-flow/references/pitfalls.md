# 實際踩過的坑（geofence／REFRACT／Design_compiler_lab）

格式：**症狀 → 原因 → 解法**。遇到錯誤先搜尋這份文件。

## 環境與工具啟動

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
- **DC constraint 乾淨，PT 仍有 max_capacitance 違規** → 兩個工具不同 corner 的負載估計有差異。SAED32 用上一條的設定；CBDK 在 DC 記憶體內把 max_capacitance 收緊到 85%。
- **reg-to-reg 差一點點（例如 −0.002 ns）** → `report_timing -significant_digits 4` 確認，再做 `compile_ultra -incremental`，或加強 `group_path -weight`。

## 等價驗證（Formality）

- **FM-503 Register … not found in the reference（暫存器在 `DP_OP_*` 底下）** → `-spg` 加 retime 把暫存器推進 datapath。改用 `compile_ultra -retime -scan`。
- **verify 卡很久（geofence＋compile_ultra 實測 >20 分鐘仍在 Verifying）** → compile_ultra 重組乘法器等 datapath，等價證明變難。改回 `compile`（geofence 實測很快 PASS），或保留 compile_ultra 但確定 SVF 有讀到、考慮 `-no_autoungroup`。
- **大量 unmatched black box** → 沒讀 SVF、沒設 `hdlin_dwroot`，或 DC 沒開 `hdlin_enable_hier_map`。

## 閘級模擬

- **`SDFCOM_CFTC Cannot find timing check $removal(posedge RSTB,posedge CLK)`（DFFARX*）** → 同一個原因：cell model 沒有 removal check。這是 warning，不影響功能結果，但 reset 的 removal 時序只有 STA 有檢查。`run_gate_sim.sh` 只容許這一種，其餘 SDF warning（包括 PAD 上的 `SDFCOM_IANE`）都判失敗。舊版公版只檢查 error，所以這 17 個 warning 一直沒被注意到（2026-11-12 發現）。
- **SAED32 SDF 有 `REMOVAL`，VCS 報 annotation 錯誤** → 舊版 SAED cell model 把 removal 寫成 clock-to-reset 的 HOLD。只在**模擬副本**把 `(REMOVAL …)` 改成 `(HOLD …)`，並做反向比對，確認只改這一處。原始 SDF 要保留。（geofence `scripts/saed32/gate.py`）
- **TFIPC 警告** → 多半是 DFF 未使用的 QN 輸出沒接，不是輸入沒接，列入說明即可。
- **官方 tb gate-level 取樣太早而失敗** → 檢查 tb 的取樣時間是否在 clock-to-Q 加輸出延遲之後；修改 tb 時只改模擬副本，並說明理由。

## APR（ICC2）

- **CTS 後 clock 沒有 buffer** → 合成留下的 `set_dont_touch_network`／ideal network 沒解除。CTS 前要 `set_dont_touch_network -clear [all_clocks]`、`remove_ideal_network`。
- **I/O path 時序與 PT 對不上** → ICC2 預設會在 input delay 加上 clock network latency。加 `-network_latency_included`。
- **`save_block -as X` 之後還在改舊 block** → `save_block -as` 不會切換 current block，要再 `open_block X`。
- **report_timing 列出所有 scenario** → 加 `-scenarios [get_scenarios functional_ss]`。
- **LVS：VDD 斷成數十個 layout net（"open layout net"），`check_pg_connectivity` 顯示 floating wires** → `compile_pg` 只在 ring 與 mesh 的交點放 via，M1 rail 到 M6/M7/M8 的 via 要自己補：`create_pg_vias -nets {VDD VSS} -from_layers M1 -to_layers M6 -via_masters {VIA12SQ_C … VIA56SQ_C}`，M6→M7、M7→M8 也一樣。（skill smoke test 實測：沒補時只有 49 個 PG via；REFRACT 補完約 1550 個）
- **ICV DRC `M1.W.2.1`（細 M1 接寬 M1，寬度 < 0.06）** → 繞線的 via enclosure 在 cell pin 旁留下細條。在同一 net 上畫 M1 矩形，蓋住「pin ∪ 錯誤區」：`templates/06_apr/apr_drc_patch.tcl` 會自動讀 ICV 錯誤檔處理。錯誤區常常只是貼著 pin 邊緣，搜尋時要放大約 0.01 um。
- **PG fat via 造成上千個 ICV DRC** → 改用 tech file 現有的方形 via（VIA12SQ…VIA67SQ）手動建立。
- **tie cell 加不進去** → TIEH／TIEL 在 Liberty 是 dont_use／dont_touch，兩個屬性都要解除。
- **write_verilog 漏 PAD** → 要明列 `pad_cells pad_spacer_cells corner_cells`。filler 也要另外列 `filler_cells`（`physical_only_cells` 不含 filler）。

## PAD（USE_PAD=1，SAED32 io_std wire-bond）

2026-11-12 用 geofence 跑 `USE_PAD=1` 全流程時遇到的問題，都已經寫進公版：

- **io.ndm 要建 40 分鐘以上（卡在 `CAPCORNER.frame` 的 FRAM-066 warning）** → CORNER 的 LEF 有 6 萬多個 OBS，預設的 frame 產生非常慢（geofence 實測 42 分鐘）。`build_ndm.tcl` 在 IO workspace 改用 `configure_frame_options -mode block_and_trim`，加上 `lib.physical_model.block_all used_layers` 和 `merge_metal_blockage true`，就降到幾秒（geofence `io_abstract_v2.tcl`）。
- **`Error: Cannot create procedure named 'place_io' - existing command`** → `place_io` 是 ICC2 內建指令，自訂 proc 不能用這個名字（公版改叫 `pad_place_cell`）。
- **某個階段失敗時 `run_stage.sh` 什麼都沒印就結束** → `set -e` 下工具 exit 1 會直接終止腳本，走不到最後的 FAIL 訊息（舊版公版 DC 失敗時就是這樣）。工具呼叫一律加 `|| true`，由最後的成功標記判定。標記要在**行首**（`grep "^DC_PASS"`）：DC 會把執行過的 tcl 指令印回 log，用子字串比對會把 `puts "DC_PASS"` 這行誤認為通過。
- **在 `source` 的子檔出錯後 icc2_shell 停在提示字元，不會結束** → 工具在等 stdin。`run_stage.sh` 用 `exec </dev/null`，讓它直接結束並回報錯誤。
- **`Port 'wire' is not defined in module terminal list`（SVR-8）** → ICC2 的 Verilog reader 不吃 `input wire clk;`。wrapper 要用 Verilog-1995 寫法（`input clk;`）。另外它也不吃 `` `ifdef ``，所以 `pad_tools.py` 產生的 wrapper 是純結構、沒有 `` `ifdef ``（RTL 模擬、DC、Formality 共用同一份）。
- **IO Verilog model 的輸出一直是 X** → `RECEIVER`／`DRIVER` 會檢查 `VDD==1 && VSS==0 && VDDIO==1 && VSSIO==0`。公版的 PAD model（`pad_tools.py padmodel` 產生的 `io_pad_sim.v`）在 model 內用 `supply1`／`supply0` 接這四個 pin，所以 RTL、合成後的 netlist（沒有 PG）都能直接模擬。繞線後含 PG 的 netlist 仍要用 `pad_tools.py simnet` 拿掉 std cell 上的 `.VDD/.VSS`（std cell model 沒有 PG port）。PG 接得對不對由 LVS 檢查，不靠模擬。
- **IO Verilog model 沒有延遲（PAD 在模擬裡是零延遲）** → 官方 `saed32nm_io_wb.v` 沒有 specify block，SDF 的 PAD IOPATH 也註入不進去（`SDFCOM_IANE`）。`pad_tools.py padmodel` 從 IO library NLDM 表查出延遲，產生同名的 PAD model（加 specify，邏輯沿用官方 RECEIVER／DRIVER），模擬時放在 source、官方 model 用 `-v`，同名 module 以 source 為準。RTL 模擬用 specify 預設值，閘級模擬由 SDF 覆蓋。
- **PAD 模式 DC／佈局前 PT 出現 -19～-22 ns setup，路徑從 input port 經過 PAD（`pad_reset/DOUT` 45 ns）** → port 到 PADIO 的 net 接了 PADIO 的 2.4 pF pin cap，wire-load 的電阻乘上它就是幾十 ns。這段其實是打線，佈局前要 `set_resistance 0`。DC 裡要先 `set_dont_touch` 這些 net，否則 compile 會把電阻設定拿掉（`OPT-801 Removing some annotated net resistances`）。
- **PAD 模式 fast 閘級模擬跑到 tb timeout，但 STA 全部 PASS** → SDF 裡 `INTERCONNECT pad_clk/DOUT …/CLK` 是 2321 ns。clock 經過 clock PAD 後，PT 不再把後面的 net 當成 ideal clock net，write_sdf 會把 wire-load 估出的高扇出延遲寫進去；STA 本身用 ideal clock，所以看不出來。佈局前 PT 要 `set_ideal_network [get_pins pad_<clk>/DOUT]`。
- **`icv_nettran: Cell 'CORNER' is not defined`** → IO 的 CDL 沒有 `CORNER`／`FILLER*` 的 subckt。LVS netlist 要把這兩種實例刪掉（GDS 裡的形狀照樣會被萃取）。`write_verilog` 不能同時下 `-include` 和 `-exclude`，而電源 PAD、SHFILL 又屬於 `physical_only_cells`，所以 `apr_finish.tcl` 是先全部寫出，再用 regsub 刪掉。
- **`VDD_NS: Port 'VDDPAD' not declared`（NETTRAN-904 warning）** → CDL 裡電源 PAD 的打線點就是 VDD 本身，沒有獨立的 port。這只是 warning，可以忽略。
- **電源 PAD 的打線 terminal 浮接（`check_pg_connectivity`：floating terminals = 2／net）** → LEF 的 `VDDPAD`（MRDL）和 PAD 內部的電源環不相連，是 library 本身的問題。`apr_core.tcl` 判定時只排除 terminals 這一項，其他浮接一樣要是 0。
- **DRC：IO ring 內有 2000 多個錯誤（PO.W.2、M9.W.2、PO.W.4、PO.S.3…）** → 都是 IO cell 自己的 GDS 問題，geofence 單獨跑 VDD_NS 就有 14 個。`drc_pad_classify.py` 依位置把錯誤分成 io／stitch／core 三類，只要 core 有錯就 FAIL。
- **DRC：M5.S.3.3 ×4 出現在電源 PAD 的接縫上** → 補丁是照 LEF 的 PG pin 位置畫的，但 IO GDS 在旁邊有 LEF 沒寫的寬金屬。這是 LEF/GDS 不一致的直接結果，分類器把它列為 `stitch`，並在報告中逐一列出座標。
- **LVS：VDD、VSS、VDDIO、VSSIO 和所有輸入 port 在 layout 裡併成同一個 net；PAD 內的 ESD 二極體（`nd`／`pd`）全部 missing** → 用 PDK 的核心 LVS runset 萃取 IO GDS 的結果。**拿掉 PAD→ring 接線也一樣**：IO ring 自己就併成一個 net，只有核心 VDD 獨立（2026-11-12 對照實驗）。所以這不是公版接線造成的。`lvs_pad_classify.py` 會檢查三件事：所有 MOS／電阻都要對上、未配對的 instance 只能在 `Xpad_*`／`Xpg_*` 底下、出問題的 net 只能是 PG 或晶片 port。三項都成立才記為 `LVS_PAD_LIMITED`，並印出 PG 合併的 NOTE。**這不是 LVS PASS**，回報時要照實說明。
- **要拿到真正乾淨的全晶片 DRC/LVS** → 需要 LEF、GDS、CDL 一致的 IO library（並搭配含 IO 層的 LVS runset），或另外修 IO cell（見 geofence `docs/apr_io_resolution_proposal.md`）。在那之前，核心的 signoff 用 `USE_PAD 0` 跑。

## Signoff

- **GDS pin 文字層不對，LVS 找不到 port** → GDS 匯出要用正確的 layer map（CBDK 用原附 `Astro/macro.map`；SAED32 用 `saed32nm_1p9m_gdsout_mw.map`）。
- **LVS 把 N901 與 n901 合併** → runset 的大小寫設定。改專案副本，保持大小寫敏感。
- **`icv_nettran: unknown option -sp-dollarPins`** → 新版已經預設輸出 `$PINS`，拿掉這個選項。
- **SAED32 LVS runset 直接用失敗** → PDK runset 是範例設定（`CELLNAME.gds`、`resistor`、作者路徑）。用 `templates/07_signoff/make_lvs_runset.sh` 產生副本。
- **`StarXtract: command not found`** → `/.bash_EDA` 沒有把 StarRC 放進 PATH；用絕對路徑 `/mnt/nfs/opt/EDA/synopsys/star-rcxt/cur/bin/StarXtract`。
- **ECO 一直串 buffer 還是修不掉 max_cap** → 每輪都在同一個 pin 後面再插一顆小 buffer。依實際負載挑尺寸（X4/X8/X16/X32），已經是 ECO buffer 的就 `size_cell` 換大顆，不要再串一級（`apr_eco.tcl` 已經這樣做）。
- **signoff_eco 回圈跑滿 4 輪還是 `STOP: not closed`，每輪都只剩同一顆 cell 的 max_cap 小幅超標** → 升一級（X0→X1）沒有用：SAED32 的 NAND2X0／X1、INVX0／X1、AO22X1 的 max_capacitance 都是 8 fF，要到 X2 才變成 16 fF。`apr_signoff_eco.tcl` 現在會直接挑輸出 max_capacitance 真的比較大的尺寸。每一輪要跑 finish→drc→lvs→starrc→pt_post，USE_PAD=1 時約 13 分鐘，白跑一輪的代價很高（2026-11-12 geofence USE_PAD=1 實測）。
- **StarRC 金屬溫度** → 沒有設定時是 25°C，報告要註明。
- **工具 exit 0 不代表通過** → 一律讀 `RESULTS: CLEAN`、`Final comparison result:PASS`、`Verification SUCCEEDED`、slack 數值。
