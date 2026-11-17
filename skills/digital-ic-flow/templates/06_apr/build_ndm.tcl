##############################################################################
# build_ndm.tcl — 階段 6-0：把 .db + LEF 轉成 ICC2 用的 NDM reference library
# 執行：icc2_lm_shell -f build_ndm.tcl   （lm_shell，不是 icc2_shell）
##############################################################################
source [file join [file dirname [info script]] flow_config.tcl]
# commit_workspace 不會自動建立上層目錄
file mkdir $APR_DIR/libs

create_workspace stdcell_rvt -technology $TECH_TF
dict for {name c} $CORNERS { read_db [file join $LIB_DIR [dict get $c lib].db] }
read_lef $CELL_LEF
check_workspace
file delete -force $APR_DIR/libs/stdcell_rvt.ndm   ;# 重跑時先刪上一次的（否則 FILE-008 already exists）
commit_workspace -output $APR_DIR/libs/stdcell_rvt.ndm
remove_workspace

# USE_PAD=1：再建一份 IO library（SAED32 用 io_std wire-bond），corner 與核心一致
if {$USE_PAD} {
    create_workspace io -technology $TECH_TF
    dict for {name c} $CORNERS { read_db [file join $IO_DB_DIR [dict get $c io].db] }
    read_lef $IO_LEF_FIXED   ;# 修正版（fix_io_lib.py）：補上 GDS 實際的 M4 電源線 pin
    # 不加這段：CORNER 有 6 萬多個 OBS，預設 frame 產生要 ~42 分鐘（實測）。
    # block_and_trim：PAD 內部整片當 blockage，只露出 pin 可接觸區，幾秒完成。
    configure_frame_options -mode block_and_trim
    set_app_options -as_user_default -name lib.physical_model.block_all -value used_layers
    set_app_options -as_user_default -name lib.physical_model.merge_metal_blockage -value true
    set_app_options -as_user_default -name lib.physical_model.block_core_margin -value {{used_layers 0}}
    check_workspace
    file delete -force $APR_DIR/libs/io.ndm   ;# 重跑時先刪上一次的（否則 FILE-008 already exists）
    commit_workspace -output $APR_DIR/libs/io.ndm
    remove_workspace
}

puts "NDM_PASS"
exit
