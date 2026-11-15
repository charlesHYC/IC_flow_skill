#!/usr/bin/env python3
"""drc_pad_classify.py — USE_PAD=1 的 ICV DRC 結果分類（run_icv_drc.sh 呼叫）

  python3 drc_pad_classify.py <TOP>.LAYOUT_ERRORS <runs/apr/pad_geometry.txt>

把每個錯誤框分成三類：
  stitch：碰到電源 PAD 端的 M5 接線補丁（apr_pad_ring.tcl 記在 STITCH 行）。補丁畫在
          LEF 宣告的 PG pin 位置，但 IO GDS 在那裡附近有 LEF 沒寫到的金屬 → spacing 錯誤，
          是 LEF/GDS 不一致的直接後果（geofence 實測 M5.S.3.3 ×4）
  io    ：落在外圈 PAD 帶（距 die 邊 < PAD_DEPTH）的其他錯誤 → IO library 自己的 GDS 問題
  core  ：其他全部（核心、core ring、PAD 與核心之間的繞線）→ 要修
有任何 core 錯誤就 exit 1；只有 stitch/io 時印 DRC_PAD_LIMITED。結果寫到 drc_classified.rpt。
"""
import re, sys, collections

errs, geo = sys.argv[1], sys.argv[2]
words = open(geo).read().split()
die = depth = None
stitches = []
for line in open(geo):
    f = line.split()
    if f and f[0] == "DIE":
        kv = dict(zip(f[0::2], f[1::2])); die = float(kv["DIE"]); depth = float(kv["PAD_DEPTH"])
    elif f and f[0] == "STITCH":
        stitches.append(tuple(map(float, f[2:6])))
def touches_stitch(x1, y1, x2, y2):
    return any(x2 > a and x1 < c and y2 > b and y1 < d for a, b, c, d in stitches)

io, core, st = collections.Counter(), collections.Counter(), collections.Counter()
core_boxes, st_boxes = [], []
rule, details = None, False
box = re.compile(r"\(\s*([-\d.]+),\s*([-\d.]+)\)\s*\(\s*([-\d.]+),\s*([-\d.]+)\)")
for line in open(errs, errors="replace"):
    if "ERROR DETAILS" in line:
        details = True; continue
    if not details:
        continue
    m = re.match(r"^([A-Z][A-Z0-9]*\.[A-Za-z0-9.]+):", line)
    if m:
        rule = m.group(1); continue
    b = box.search(line)
    if b and rule:
        x1, y1, x2, y2 = map(float, b.groups())
        in_core_square = x2 > depth and x1 < die - depth and y2 > depth and y1 < die - depth
        if touches_stitch(x1, y1, x2, y2):
            st[rule] += 1; st_boxes.append((rule, x1, y1, x2, y2))
        elif in_core_square:
            core[rule] += 1; core_boxes.append((rule, x1, y1, x2, y2))
        else:
            io[rule] += 1
with open("drc_classified.rpt", "w") as f:
    f.write("IO ring (library) errors:\n")
    for r, n in io.most_common(): f.write("  %-12s %d\n" % (r, n))
    f.write("PAD-side PG stitch errors (LEF pin location vs IO GDS metal):\n")
    for r, n in st.most_common(): f.write("  %-12s %d\n" % (r, n))
    for b in st_boxes: f.write("    %s (%.3f, %.3f) (%.3f, %.3f)\n" % b)
    f.write("core / PAD-to-core errors:\n")
    for r, n in core.most_common(): f.write("  %-12s %d\n" % (r, n))
    for b in core_boxes: f.write("    %s (%.3f, %.3f) (%.3f, %.3f)\n" % b)
print("DRC_CLASSIFY io_ring=%d (%s) stitch=%d (%s) core=%d (%s)" % (
    sum(io.values()), " ".join(sorted(io)), sum(st.values()), " ".join(sorted(st)),
    sum(core.values()), " ".join(sorted(core))))
if core:
    print("DRC FAIL: errors inside core / PAD-to-core area, see drc_classified.rpt"); sys.exit(1)
print("DRC_PAD_LIMITED: core clean; remaining errors are IO library GDS + PAD-side PG stitch (LEF/GDS mismatch)")
