#!/usr/bin/env python3
"""fix_io_lib.py — 產生修正版的 SAED32 io_std wire-bond library（GDS、CDL）與 DRC runset。

PDK 原檔只讀不改；修正版寫到 <out_dir>：
  saed32_stdio_wb_fixed.gds   saedio_std_wb_fixed.cdl   drc_rules_fixed.rs   saed32_io_wb_fixed.lef   fix_io_lib.log

用法：python3 fix_io_lib.py <io_gds> <io_cdl> <drc_runset> <io_lef> <out_dir>

每一項修正都先確認原始幾何／文字與預期完全一致才改；PDK 版本不同、對不上時直接中止，
不會默默改錯地方。修正內容（2026-11-17 以單一 PAD 的 ICV DRC／LVS 逐項確認）：

GDS
  1. I1025_NS／I1025_EW（輸入 PAD）：把 PADIO 從 ESD 接到輸入 buffer 的那條 M2 橫線，
     在同一層 M2 上直接穿過 ESD 的 VDDIO 直線 → PADIO 與 VDDIO 短路（LVS：pd 二極體
     兩端同 net 被濾掉，晶片 LVS 的輸入 port 全部和 VDDIO 併成一個 net）。
     修法：M2 在 VDDIO 線兩側斷開，用 VIA2 + M3 跨過去。
  2. I1025_NS／I1025_EW：VIA12_0／VIA12_2 和 VIA12BAR_14 疊在一起，合成不合法的 VIA1 形狀
     （VIA1.W、VIA1.E.2）。兩顆 via 接的是同一組 M1／M2，拿掉 VIA12BAR_14。
  3. I1025_EW／D4I1025_EW：0.06 寬的 M2 線端超出 via 的 M2 pad 0.001 um（M2.W.2.1）。
     線端往內收到 via pad 裡。
  4. VSS_NS：兩塊同 net（落在同一條 M1 軌上）的 M2 之間只有 0.036 um（M2.S.1／S.2／S.3.1）。
     補一塊 M2 把縫填起來。
  8. I1025_NS：輸入 buffer 的 level shifter（gen_I1025）有自己的 M1 VDD／VSS 環，但 NS 版沒有任何
     via 把它接到 M4 的 VDD／VSS 電源條（EW 版有）。單顆 PAD 的 LVS 會過，是因為 PAD 是 top cell 時
     同名的 VDD／VSS 文字會把兩塊併起來；放進晶片後 level shifter 的 VDD、VSS 是浮接的孤島。
     環的垂直邊剛好在電源條正下方，各補一串 VIA1/VIA2/VIA3。
CDL
  5. VDD_NS／VDD_EW／VSS_NS／VSS_EW：ESD 二極體的兩端寫反（layout 和 gen_ESD 都是
     pd：PAD→VDDIO、nd：VSSIO→PAD）。LVS 報 swapped pins。把 nd／pd 的兩端對調。
LEF
  7. 每個 PAD 的 VDD／VDDIO／VSS／VSSIO 在 GDS 裡是 2 um 寬的 M4 垂直線（gen_Buses），拉到 PAD
     靠 core 的那一邊；LEF 沒有這四條線，只在接縫寫了 GDS 裡不存在的 0.19 um pin。照 LEF 的 pin
     接 core 電源會打到別的 net 的金屬（VDD／VSS／VSSIO 短路，接縫 M5.S.3.3）。
     把這四條線照 GDS 的實際位置加成 LEF 的 PORT，core 電源從這裡接。
DRC runset
  6. M9.W.2：runset 用中間層金屬的上限 5 um 檢查 M9，但設計規則手冊（SAED32 Design Rules
     Rev 1.0.2，Table 13）頂層金屬 MT.W.2 的上限是 10 um。PAD 的 M9 打線條寬 10 um，
     全部被誤報。改成 10。
"""
import struct
import sys
from pathlib import Path

LOG = []


def log(msg):
    LOG.append(msg)
    print(msg)


# ---------------------------------------------------------------- GDS 讀寫
def records(data):
    i = 0
    while i + 4 <= len(data):
        n, t = struct.unpack(">HH", data[i:i + 4])
        if n < 4:
            break
        yield i, n, t >> 8
        i += n


def rec(rt, dt, payload=b""):
    return struct.pack(">HBB", 4 + len(payload), rt, dt) + payload


def name_bytes(s):
    b = s.encode()
    return b + b"\0" * (len(b) % 2)


def um(v):
    return round(v * 1000)  # GDS 單位 1 nm（已確認 UNITS = 1e-3 um / 1e-9 m）


def boundary(layer, x1, y1, x2, y2):
    pts = [(x1, y1), (x2, y1), (x2, y2), (x1, y2), (x1, y1)]
    xy = b"".join(struct.pack(">2i", um(x), um(y)) for x, y in pts)
    return rec(0x08, 0) + rec(0x0D, 0x02, struct.pack(">h", layer)) + \
        rec(0x0E, 0x02, b"\0\0") + rec(0x10, 0x03, xy) + rec(0x11, 0)


def sref(name, x, y):
    return rec(0x0A, 0) + rec(0x12, 0x06, name_bytes(name)) + \
        rec(0x10, 0x03, struct.pack(">2i", um(x), um(y))) + rec(0x11, 0)


def parse_elements(data, recs, a, b):
    """recs[a:b] 是一個 structure 的內容；回傳 element 清單（bytes 與摘要）"""
    els = []
    k = a
    while k < b:
        j = k
        while recs[j][2] != 0x11:
            j += 1
        info = {"kind": recs[k][2], "layer": None, "sname": None, "xy": None, "width": None}
        for o, n, rt in recs[k:j + 1]:
            p = data[o + 4:o + n]
            if rt == 0x0D:
                info["layer"] = struct.unpack(">h", p[:2])[0]
            elif rt == 0x12:
                info["sname"] = p.rstrip(b"\0").decode()
            elif rt == 0x0F:
                info["width"] = struct.unpack(">i", p[:4])[0]
            elif rt == 0x10:
                v = struct.unpack(">%di" % (len(p) // 4), p)
                info["xy"] = [(v[q], v[q + 1]) for q in range(0, len(v), 2)]
        info["bytes"] = data[recs[k][0]:recs[j][0] + recs[j][1]]
        info["xy_rec"] = next((o for o, n, rt in recs[k:j + 1] if rt == 0x10), None)
        els.append(info)
        k = j + 1
    return els


def find_one(els, pred, what):
    hits = [e for e in els if pred(e)]
    if len(hits) != 1:
        sys.exit("fix_io_lib: expected exactly 1 %s, found %d — IO library version differs, abort" % (what, len(hits)))
    return hits[0]


def is_path(e, layer, w, pts):
    return e["kind"] == 0x09 and e["layer"] == layer and e["width"] == um(w) and \
        e["xy"] == [(um(x), um(y)) for x, y in pts]


def is_sref(e, name, x, y):
    return e["kind"] == 0x0A and e["sname"] == name and e["xy"] == [(um(x), um(y))]


def fix_gds(src, dst):
    data = Path(src).read_bytes()
    recs = list(records(data))
    # structure 範圍：STRNAME(0x06) 之後到 ENDSTR(0x07) 之前
    spans = {}
    for idx, (o, n, rt) in enumerate(recs):
        if rt == 0x06:
            nm = data[o + 4:o + n].rstrip(b"\0").decode()
            end = idx
            while recs[end][2] != 0x07:
                end += 1
            spans[nm] = (idx + 1, end)

    edits = {}  # structure -> (remove list, add list)

    def plan(cell, remove, add, why):
        els = parse_elements(data, recs, *spans[cell])
        rm = [find_one(els, p, "%s in %s" % (w, cell)) for p, w in remove]
        edits.setdefault(cell, ([], []))
        edits[cell][0].extend(e["bytes"] for e in rm)
        edits[cell][1].extend(add)
        log("GDS %-11s %s" % (cell, why))

    # 1. 輸入 PAD：PADIO 的 M2 橫線跨過 VDDIO 直線 → 改成 M3 跨線
    plan("I1025_NS",
         [(lambda e: is_path(e, 13, 0.2, [(1.895, 122.753), (6.214, 122.753)]), "M2 PADIO strap")],
         [boundary(13, 1.795, 122.653, 2.80, 122.853), boundary(13, 3.70, 122.653, 6.314, 122.853),
          boundary(15, 2.60, 122.653, 3.90, 122.853),
          sref("VIA23_17", 2.70, 122.753), sref("VIA23_17", 3.80, 122.753)],
         "PADIO M2 strap crossed VDDIO M2 (x 3.13-3.36) -> M3 bridge")
    plan("I1025_EW",
         [(lambda e: is_path(e, 13, 0.2, [(177.247, 1.705), (177.247, 6.024)]), "M2 PADIO strap")],
         [boundary(13, 177.147, 1.605, 177.347, 2.80), boundary(13, 177.147, 3.70, 177.347, 6.124),
          boundary(15, 177.147, 2.60, 177.347, 3.90),
          sref("VIA23_17", 177.247, 2.70), sref("VIA23_17", 177.247, 3.80)],
         "PADIO M2 strap crossed VDDIO M2 (y 3.13-3.36) -> M3 bridge")
    # 2. 重疊的 VIA1
    plan("I1025_NS", [(lambda e: is_sref(e, "VIA12BAR_14", 3.357, 142.724), "VIA12BAR_14")], [],
         "removed VIA12BAR_14 overlapping VIA12_0 (VIA1.W, VIA1.E.2)")
    plan("I1025_EW", [(lambda e: is_sref(e, "VIA12BAR_14", 157.321, 33.159), "VIA12BAR_14")], [],
         "removed VIA12BAR_14 overlapping VIA12_2 (VIA1.W, VIA1.E.2)")
    # 3. M2 線端超出 via pad
    for cell, x0, y in (("I1025_EW", 157.469, 33.164), ("D4I1025_EW", 156.913, 32.651)):
        plan(cell, [(lambda e, x0=x0, y=y: is_path(e, 13, 0.06, [(x0, y), (151.489, y)]), "M2 0.06 wire")],
             [None, (13, 0.06, [(x0, y), (151.52, y)])],
             "M2 wire end 151.489 -> 151.52, inside the via pad (M2.W.2.1)")
    # 4. VSS_NS M2 縫
    plan("VSS_NS", [], [boundary(13, 33.09, 142.581, 33.146, 142.795)],
         "filled 0.036 um M2 gap at x 33.100-33.136 (M2.S.1/S.2/S.3.1); both sides on the same M1 rail")
    # 8. I1025_NS：level shifter（gen_I1025）的 M1 VDD／VSS 環沒有 via 接到 M4 電源條
    #    （I1025_EW 有兩組 VIA12_3+VIA23_5+VIA34_4，NS 版漏了）。環的垂直邊剛好在電源條正下方，
    #    在那裡各補一串 VIA1/VIA2/VIA3（M2、M3 在這兩點是空的）。
    gen_ox, gen_oy = -2.438, 151.211            # I1025_NS 裡 gen_I1025 的 SREF 位置（angle 0）
    els = parse_elements(data, recs, *spans["I1025_NS"])
    find_one(els, lambda e: is_sref(e, "gen_I1025", gen_ox, gen_oy), "gen_I1025 SREF in I1025_NS")
    find_one(els, lambda e: is_sref(e, "gen_Buses", -5.817, 100.0), "gen_Buses SREF in I1025_NS")
    rings = gds_paths(data, "gen_I1025", 11, (0, 2))
    for net, gx, gy, strap in (("VDD", 3.58, 10.789, 7.684), ("VSS", 16.525, 11.289, 20.418)):
        x, y = round(gx + gen_ox, 3), round(gy + gen_oy, 3)
        hit = [xy for w, xy in rings if w == 0.05 and any(
            a[0] == b[0] == gx and min(a[1], b[1]) < gy < max(a[1], b[1]) for a, b in zip(xy, xy[1:]))]
        if len(hit) != 1:
            sys.exit("fix_io_lib: gen_I1025 %s ring edge at x=%s not found — IO library version differs, abort" % (net, gx))
        if abs((strap - 5.817) - x) > 1.0 - 0.06:  # 要落在 2 um 寬的 M4 電源條內
            sys.exit("fix_io_lib: %s via stack at x=%s is not under the %s M4 strap" % (net, x, net))
        # M4 電源條寬 2 um > 0.2 → VIA3 要兩顆、間距 <= 0.15（VIA3.B.1）；
        # M2／M3 小方塊面積要 >= 0.016（M2.A.1／M3.A.1）→ 補 0.11 x 0.21 的 M2、M3
        plan("I1025_NS", [],
             [sref("VIA12_0", x, y), sref("VIA23_17", x, y),
              sref("VIA34_13", x, y), sref("VIA34_13", x, round(y + 0.15, 3)),
              boundary(13, x - 0.055, y - 0.03, x + 0.055, y + 0.18),
              boundary(15, x - 0.055, y - 0.03, x + 0.055, y + 0.18)],
             "level-shifter %s M1 ring -> %s M4 strap: added VIA1/VIA2/2xVIA3 stack at (%.3f, %.3f)" % (net, net, x, y))

    out = bytearray()
    last = 0
    for cell, (a, b) in sorted(spans.items(), key=lambda kv: kv[1][0]):
        if cell not in edits:
            continue
        rm, add = edits[cell]
        body_start = recs[a][0]
        body_end = recs[b][0]
        body = data[body_start:body_end]
        for blob in rm:
            assert body.count(blob) == 1
            body = body.replace(blob, b"", 1)
        extra = b""
        for item in add:
            if item is None:
                continue
            if isinstance(item, tuple):  # 新的 path（取代被移除的那條）
                layer, w, pts = item
                xy = b"".join(struct.pack(">2i", um(x), um(y)) for x, y in pts)
                extra += rec(0x09, 0) + rec(0x0D, 0x02, struct.pack(">h", layer)) + \
                    rec(0x0E, 0x02, b"\0\0") + rec(0x0F, 0x03, struct.pack(">i", um(w))) + \
                    rec(0x10, 0x03, xy) + rec(0x11, 0)
            else:
                extra += item
        out += data[last:body_start] + body + extra
        last = body_end
    out += data[last:]
    Path(dst).write_bytes(bytes(out))


# ---------------------------------------------------------------- CDL
def fix_cdl(src, dst):
    lines = Path(src).read_text().splitlines(keepends=True)
    cell = None
    n = 0
    for i, l in enumerate(lines):
        w = l.split()
        if w and w[0].lower() == ".subckt":
            cell = w[1]
        if cell in ("VDD_NS", "VDD_EW", "VSS_NS", "VSS_EW") and len(w) > 3 and w[3] in ("nd", "pd"):
            pad = cell.split("_")[0]
            expect = {"nd": [pad, "VSSIO"], "pd": ["VDDIO", pad]}[w[3]]
            if w[1:3] != expect:
                sys.exit("fix_io_lib: unexpected diode line in %s: %s" % (cell, l.strip()))
            w[1], w[2] = w[2], w[1]
            lines[i] = " " + " ".join(w) + "\n"
            n += 1
            log("CDL %-11s %s %s -> anode %s cathode %s" % (cell, w[0], w[3], w[1], w[2]))
    if n != 8:
        sys.exit("fix_io_lib: expected 8 power-pad diode lines, fixed %d" % n)
    Path(dst).write_text("".join(lines))


# ---------------------------------------------------------------- LEF
def gds_srefs(data):
    """每個 structure 的 SREF：[(name, x, y, angle, reflect)]（um）"""
    out = {}
    cur = el = None
    for o, n, rt in records(data):
        p = data[o + 4:o + n]
        if rt == 0x06:
            cur = p.rstrip(b"\0").decode()
            out[cur] = []
        elif rt == 0x0A:
            el = {"a": 0.0, "r": False}
        elif el is not None and rt == 0x12:
            el["n"] = p.rstrip(b"\0").decode()
        elif el is not None and rt == 0x1A:
            el["r"] = bool(p[0] & 0x80)
        elif el is not None and rt == 0x1C:
            e = p[0] & 0x7F
            el["a"] = int.from_bytes(p[1:], "big") / 2 ** 56 * 16 ** (e - 64)
        elif el is not None and rt == 0x10:
            el["xy"] = struct.unpack(">2i", p[:8])
        elif rt == 0x11 and el is not None:
            if "n" in el:
                out[cur].append((el["n"], el["xy"][0] / 1000, el["xy"][1] / 1000, el["a"], el["r"]))
            el = None
        elif rt in (0x08, 0x09, 0x0B, 0x0C, 0x2D):
            el = None
    return out


def gds_paths(data, cell, layer, pathtypes=(0,)):
    """structure 內（不展開）指定層的 PATH：[(width, [(x,y),...])]；預設只接受平頭（pathtype 0）"""
    res = []
    cur = el = None
    for o, n, rt in records(data):
        p = data[o + 4:o + n]
        if rt == 0x06:
            cur = p.rstrip(b"\0").decode()
        if cur != cell:
            continue
        if rt == 0x09:
            el = {"pt": 0}
        elif el is not None and rt == 0x0D:
            el["L"] = struct.unpack(">h", p[:2])[0]
        elif el is not None and rt == 0x21:
            el["pt"] = struct.unpack(">h", p[:2])[0]
        elif el is not None and rt == 0x0F:
            el["w"] = struct.unpack(">i", p[:4])[0] / 1000
        elif el is not None and rt == 0x10:
            v = struct.unpack(">%di" % (len(p) // 4), p)
            el["xy"] = [(v[q] / 1000, v[q + 1] / 1000) for q in range(0, len(v), 2)]
        elif rt == 0x11 and el is not None:
            if el.get("L") == layer:
                if el["pt"] not in pathtypes:
                    sys.exit("fix_io_lib: unexpected path type %d in %s" % (el["pt"], cell))
                res.append((el["w"], el["xy"]))
            el = None
    return res


def xform(x, y, ox, oy, a, r):
    import math
    if r:
        y = -y
    c, s = round(math.cos(math.radians(a))), round(math.sin(math.radians(a)))
    return ox + x * c - y * s, oy + x * s + y * c


# gen_Buses 裡四條 2 um 寬的 M4 垂直電源線（由左到右 VDD、VDDIO、VSS、VSSIO，見 gen_Buses 的文字），
# 從 PAD 內部的電源環一路拉到 PAD 靠 core 的那一邊。LEF 完全沒有寫這四條線，
# 只在 cell 兩側接縫寫了 0.19 um 的 M4／M5 pin（GDS 在那裡沒有金屬）。
BUS_NETS = [(7.684, "VDD"), (14.149, "VDDIO"), (20.418, "VSS"), (27.494, "VSSIO")]


def fix_lef(src_lef, gds, dst):
    data = Path(gds).read_bytes()
    srefs = gds_srefs(data)
    straps = {}
    for bus in ("gen_Buses", "gen_buses"):
        ps = gds_paths(data, bus, 17)
        got = sorted(round(xy[0][0], 3) for w, xy in ps)
        if got != [x for x, _ in BUS_NETS] or any(w != 2.0 for w, _ in ps):
            sys.exit("fix_io_lib: %s M4 straps differ from expected %s: %s" % (bus, BUS_NETS, got))
        straps[bus] = ps
    lines = Path(src_lef).read_text().splitlines(keepends=True)
    out = []
    macro = None
    size = None
    added = 0
    rects = {}
    for l in lines:
        w = l.split()
        if w[:1] == ["MACRO"]:
            macro = w[1]
            rects = {}
            for nm, ox, oy, a, r in srefs.get(macro, []):
                if nm not in straps:
                    continue
                for wd, xy in straps[nm]:
                    (x0, y0), (x1, y1) = xy
                    net = dict(BUS_NETS)[round(x0, 3)]
                    p0 = xform(x0, y0, ox, oy, a, r)
                    p1 = xform(x1, y1, ox, oy, a, r)
                    h = wd / 2
                    if abs(p0[0] - p1[0]) < 1e-6:   # 垂直
                        bb = (p0[0] - h, min(p0[1], p1[1]), p0[0] + h, max(p0[1], p1[1]))
                    else:
                        bb = (min(p0[0], p1[0]), p0[1] - h, max(p0[0], p1[0]), p0[1] + h)
                    rects.setdefault(net, []).append(bb)
        if w[:1] == ["SIZE"] and macro:
            size = (float(w[1]), float(w[3]))
        if w[:2] and w[0] == "END" and len(w) == 2 and w[1] in rects and macro:
            for bb in rects.pop(w[1]):
                x1, y1, x2, y2 = (max(0.0, bb[0]), max(0.0, bb[1]), min(size[0], bb[2]), min(size[1], bb[3]))
                out.append("    PORT\n      LAYER M4 ;\n        RECT %.4f %.4f %.4f %.4f ;\n    END\n" % (x1, y1, x2, y2))
                added += 1
        out.append(l)
    Path(dst).write_text("".join(out))
    log("LEF added %d M4 power-strap ports (gen_Buses VDD/VDDIO/VSS/VSSIO, from GDS)" % added)


# ---------------------------------------------------------------- DRC runset
def fix_drc(src, dst):
    t = Path(src).read_text()
    old = '@ "M9.W.2: Maximum M9 width must be 5";\n\t\twide (m9,distance>5);'
    new = '@ "M9.W.2: Maximum M9 width must be 10 (MT.W.2, top metal)";\n\t\twide (m9,distance>10);'
    if t.count(old) != 1:
        sys.exit("fix_io_lib: M9.W.2 rule text not found exactly once in %s" % src)
    Path(dst).write_text(t.replace(old, new))
    log("DRC M9.W.2 max width 5 -> 10 um (design rule manual MT.W.2)")


if __name__ == "__main__":
    if len(sys.argv) != 6:
        sys.exit(__doc__)
    io_gds, io_cdl, runset, io_lef, out = sys.argv[1:]
    od = Path(out)
    od.mkdir(parents=True, exist_ok=True)
    fix_gds(io_gds, od / "saed32_stdio_wb_fixed.gds")
    fix_cdl(io_cdl, od / "saedio_std_wb_fixed.cdl")
    fix_drc(runset, od / "drc_rules_fixed.rs")
    fix_lef(io_lef, od / "saed32_stdio_wb_fixed.gds", od / "saed32_io_wb_fixed.lef")
    (od / "fix_io_lib.log").write_text("\n".join(LOG) + "\n")
    print("FIX_IO_LIB_PASS")
