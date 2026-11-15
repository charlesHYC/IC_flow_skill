##############################################################################
# constraints_saed32.sdc — SAED32 版（單位 ns / fF / MOhm）
# 來源：geofence scripts/saed32/constraints.tcl、REFRACT constraints_50ff.tcl
# DC、PrimeTime、ICC2 共用；ICC2 在 CTS 後會另外改成 propagated clock
##############################################################################

create_clock -name $CLK_PORT -period $PERIOD [get_ports $CLK_PORT]
set_clock_uncertainty -setup 0.10 [get_clocks $CLK_PORT]
set_clock_uncertainty -hold  0.05 [get_clocks $CLK_PORT]
set_clock_transition  0.10        [get_clocks $CLK_PORT]

set in_ports [remove_from_collection [all_inputs] [get_ports $CLK_PORT]]
# 外部 falling-edge launch 時加 -clock_fall（geofence）；rising edge 就拿掉
set_input_delay  -clock $CLK_PORT -max 2.0 $in_ports
set_input_delay  -clock $CLK_PORT -min 0.2 $in_ports
set_input_transition 0.10 $in_ports
set_output_delay -clock $CLK_PORT -max 2.0 [all_outputs]
set_output_delay -clock $CLK_PORT -min 0.2 [all_outputs]

# 輸出負載：SAED32 最大的核心 cell（NBUFFX32_RVT）max_capacitance 只有 168 fF，
# 原題的 1 pF（=1000 fF）核心 cell 推不動。無 PAD 核心用 20~50 fF；
# 加 PAD 版本則把 1000 fF 放在晶片 port（由 output pad 驅動）。
set_load 20.0 [all_outputs]
# 原題 set_drive 0.1（100 Ohm）在 MOhm 單位下要寫 0.0001
set_drive 0.0001 $in_ports

# 不對 reset 設 false path：保留 recovery / removal 檢查
