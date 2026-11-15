##############################################################################
# constraints_chip.sdc — USE_PAD=1 的晶片 top 約束（DC、佈局前 PT、ICC2、繞線後 PT 共用）
# 來源：geofence scripts/apr/chip_constraints.tcl
# 和核心版 constraints_saed32.sdc 的差別：
#   * port 在 PAD 外側，PAD 的延遲算在時序路徑內
#   * 輸出負載是板級 1 pF（SAED32 單位 fF → 1000），由 output PAD 推，不是核心 cell
#   * 排除四個 PG port
# USE_PAD=1 時從合成開始就用這份（PAD 從設計一開始就在 netlist 裡）。
##############################################################################

create_clock -name $CLK_PORT -period $PERIOD [get_ports $CLK_PORT]
set_clock_uncertainty -setup 0.10 [get_clocks $CLK_PORT]
set_clock_uncertainty -hold  0.05 [get_clocks $CLK_PORT]
set_clock_transition  0.10        [get_clocks $CLK_PORT]

set pg_ports [get_ports -quiet {VDD VSS VDDIO VSSIO}]
set in_ports [remove_from_collection [all_inputs] [add_to_collection [get_ports $CLK_PORT] $pg_ports]]
set out_ports [remove_from_collection [all_outputs] $pg_ports]
# 外部 falling-edge launch 時加 -clock_fall（geofence）；rising edge 就拿掉
set_input_delay  -clock $CLK_PORT -max 2.0 $in_ports
set_input_delay  -clock $CLK_PORT -min 0.2 $in_ports
set_input_transition 0.10 $in_ports
set_output_delay -clock $CLK_PORT -max 2.0 $out_ports
set_output_delay -clock $CLK_PORT -min 0.2 $out_ports

# 板級／封裝負載 1 pF（單位 fF）
set_load 1000 $out_ports
