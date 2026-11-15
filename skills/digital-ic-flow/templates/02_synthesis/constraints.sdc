##############################################################################
# constraints.sdc — IC Contest 原題風格（CBDK slow，單位 ns / pF / kOhm）
# 來源：geofence 官方 geofence.sdc；REFRACT 官方 REFRACT.sdc 同樣結構
# 用 $CLK_PORT / $PERIOD 取代寫死的名稱與週期（定義在 flow_config.tcl）
##############################################################################

create_clock -name $CLK_PORT -period $PERIOD [get_ports $CLK_PORT]

# 合成階段的 clock 是理想時脈：不讓 DC 在 clock net 上插 buffer，CTS 交給 APR
set_dont_touch_network       [all_clocks]
set_ideal_network            [get_ports $CLK_PORT]
set_clock_uncertainty  0.1   [all_clocks]   ;# skew + jitter 預留
set_clock_latency      0.5   [all_clocks]   ;# 估計 clock tree 延遲

# I/O 時序：相對於外部 launch / capture 的 clock edge
# geofence 外部用 falling edge -> 加 -clock_fall；REFRACT 用 rising edge 並給 max 1 / min 0
set in_ports [remove_from_collection [all_inputs] [get_ports $CLK_PORT]]
set_input_delay  -max 1 -clock $CLK_PORT $in_ports
set_input_delay  -min 0 -clock $CLK_PORT $in_ports
set_output_delay 1      -clock $CLK_PORT [all_outputs]

# 環境：輸出負載 1（=1 pF，CBDK 的單位），輸入驅動電阻 0.1（=100 Ohm）
set_load   1   [all_outputs]
set_drive  0.1 [all_inputs]

# CBDK 版需要 operating condition 與 wire-load
set_operating_conditions -max_library slow -max slow
set_wire_load_model -name tsmc13_wl10 -library slow
set_max_fanout 20 [all_inputs]
