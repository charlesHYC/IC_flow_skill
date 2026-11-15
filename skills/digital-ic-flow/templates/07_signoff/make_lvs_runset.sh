#!/usr/bin/env bash
# make_lvs_runset.sh — 由 PDK 的 SAED32 LVS runset 產生專案用副本（原 PDK 不修改）
#   bash make_lvs_runset.sh <TOP> <GDS 路徑> <輸出 .rs>
# 修改內容（來自 REFRACT saed32_lvs_local.rs，LVS PASS）：
#   1. library_name / cell 改成本設計的 GDS 與 top cell（原檔是 CELLNAME.gds / resistor 範例）
#   2. schematic_file 改成 icv_nettran 產生的 schematic.sp（原檔指向作者機器路徑）
#   3. xref_db_h 宣告型別改為 xref_database_handle（新版 ICV 不接受舊型別名）
#   4. 兩處 tagname 字串尾端多一個空白（"subtie_scon "、"ndores "），去掉
set -euo pipefail
TOP=${1:?top cell}; GDS=${2:?gds path}; OUT=${3:?output runset}
SRC=/mnt/nfs/opt/PROCESS/SAED32_EDK/tech/icv_lvs/saed32nm_1p9m_lvs_rules.rs

sed -e "s#library_name= \"CELLNAME.gds\",#library_name= \"$GDS\",#" \
    -e "s#^cell= \"resistor\"#cell= \"$TOP\"#" \
    -e 's#xref_db_h:handle;#xref_db_h:xref_database_handle;#' \
    -e 's#schematic_file    = {{filename = "[^"]*func.rs", format = SPICE}}#schematic_file    = {{filename = "schematic.sp", format = SPICE}}#' \
    -e 's#tagname="subtie_scon "#tagname="subtie_scon"#' \
    -e 's#tagname="ndores "#tagname="ndores"#' \
    "$SRC" > "$OUT"

# 確認 6 處都有改到；PDK 版本不同時 sed 可能沒匹配，直接報錯
n=$(diff "$SRC" "$OUT" | grep -c '^>' || true)
[ "$n" -eq 6 ] || { echo "expected 6 changed lines, got $n — check PDK runset version" >&2; exit 1; }
echo "wrote $OUT"
