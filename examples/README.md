# 流程表格 demo 專案

兩個資料夾都是 geofence（IC Contest 題目，SAED32 EDK、clock 30 ns）用本 repo 的公版從乾淨目錄跑 `run_all.sh` 的結果，只留下流程表格與 `/ic_flow` 面板需要的資料：

- `scripts/flow_config.tcl`：當次的設定（`/ic_flow` 用它辨認專案）
- `runs/<stage>/status.txt`：`run_stage.sh` 寫的判定（狀態、開始時間、耗時）
- `runs/**/console*.log`：只保留腳本印出的結果標記行（例如 `DC_SLACK`、`STA_SLACK`、`DRC_CLASSIFY`、`GATE_SIM_PASS`），本機路徑已去掉
- `runs/stage_history.log`、`runs/flow_mode.txt`：執行順序與 PAD 模式
- `runs/lvs/lvs_classified.rpt`、`runs/drc/drc_classified.rpt`：PAD 模式的 DRC／LVS 分類統計
- `flow_table.txt`：終端機表格（`flow_dashboard.py --text`）

不含 RTL、netlist、GDS、SPEF 或任何製程檔。重新印出表格：

```bash
python3 ../skills/digital-ic-flow/templates/00_common/flow_dashboard.py geofence_pad
```

注意：`flow_dashboard.py` 每次執行都會把專案登記到 `~/.claude/ic-flow/projects.txt`，所以 demo 也會出現在 `/ic_flow` 的 History。
