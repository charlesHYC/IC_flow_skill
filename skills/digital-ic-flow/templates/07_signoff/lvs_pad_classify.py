#!/usr/bin/env python3
"""lvs_pad_classify.py — USE_PAD=1 的全晶片 LVS 結果分類（run_icv_lvs.sh 在 FAIL 時呼叫）

  python3 lvs_pad_classify.py <TOP>.LVS_ERRORS

LVS 沒通過時，幫忙判斷問題在核心還是在 PAD（只印診斷，不決定 PASS／FAIL）：
  1. 所有 MOS / 電阻是否都配對成功（unmatched = 0）——核心的電晶體全部對上
  2. 沒配對的 instance 是否只在 PAD 實例底下（Xpad_* / Xpg_*）
  3. 沒配對的 schematic net 是否只有 PG net（VDD/VSS/VDDIO/VSSIO）或晶片 port
都成立時印 LVS_DIAG（問題集中在 PAD／電源接線）；否則列出核心的問題。結果寫到 lvs_classified.rpt。
"""
import re, sys

text = open(sys.argv[1], errors="replace").read()
PG = {"VDD", "VSS", "VDDIO", "VSSIO"}
problems, notes = [], []

# 1. 元件類型配對表：Matched  Unmatched-sch  Unmatched-lay  TYPE[sch, lay]
dev = re.findall(r"^\s*(\d+)\s+(\d+)\s+(\d+)\s+\*?\s*(\w+)\[(\w+), (\w+)\]", text, re.M)
if not dev:
    problems.append("cannot find the post-compare device table")
for matched, us, ul, kind, s, l in dev:
    line = "%s[%s] matched=%s unmatched sch=%s lay=%s" % (kind, s, matched, us, ul)
    notes.append(line)
    if kind in ("NMOS", "PMOS", "RES") and (int(us) or int(ul)):
        problems.append("transistor/resistor mismatch: " + line)

# 2. missing / extra instance 要都在 PAD 底下
insts = re.findall(r"^\s+(X\S+)\s.*\* (?:Missing|Extra) instance", text, re.M)
for inst in insts:
    if not re.match(r"Xp(ad|g)_", inst):
        problems.append("unmatched instance outside PAD: " + inst)
notes.append("unmatched instances: %d (outside PAD: %d)" % (
    len(insts), sum(1 for i in insts if not re.match(r"Xp(ad|g)_", i))))

# 3. complex connection 群組：每行是「配對數  schematic net : n  layout net : n」，
#    只有一欄時用欄位位置判斷是 schematic 還是 layout（header 的 "Layout net" 位置）
sch_nets, groups, cur = set(), [], None
lay_col = None
for line in text.splitlines():
    if "Schematic net : connections" in line:
        lay_col = line.expandtabs().index("Layout net"); cur = {"sch": set(), "lay": None}; groups.append(cur)
        continue
    if lay_col is None:
        continue
    l = line.expandtabs()
    m = re.match(r"^\s+\d+\s+", l)
    if not m:
        if l.strip() and not l.strip().startswith("-"):
            lay_col = None
        continue
    for pm in re.finditer(r"(\S+) : \d+", l):
        if pm.start() < lay_col - 4:
            sch_nets.add(pm.group(1)); cur["sch"].add(pm.group(1))
for n in sorted(sch_nets):
    if "/" in n:
        problems.append("internal net in connection error: " + n)
    elif n not in PG and not re.match(r"^[A-Za-z_]\w*(\[\d+\])?$", n):
        problems.append("unexpected net: " + n)
notes.append("schematic nets in connection errors: %s" % " ".join(sorted(sch_nets)))
# PG 之間短在一起要特別列出
merged = sorted(PG & sch_nets)
if len(merged) > 1:
    notes.append("NOTE: PG nets %s appear in the same connection-error group (possible PG short in layout)" % merged)

with open("lvs_classified.rpt", "w") as f:
    f.write("\n".join(notes + ["PROBLEM: " + p for p in problems]) + "\n")
if problems:
    print("LVS FAIL (not only PAD-related):")
    for p in problems[:10]: print("  " + p)
    sys.exit(1)
for n in notes:
    if n.startswith("NOTE"): print(n)
print("LVS_DIAG: all MOS/RES matched; mismatches only inside PAD cells / on PG nets and chip ports")
