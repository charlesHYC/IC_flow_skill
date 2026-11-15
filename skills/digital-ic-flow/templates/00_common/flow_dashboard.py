#!/usr/bin/env python3
"""flow_dashboard.py — 依 design flow 順序產生專案儀表板（只用 Python 標準函式庫）

  python3 scripts/flow_dashboard.py <proj>      → 寫出 <proj>/runs/dashboard.html

run_stage.sh 每個階段結束都會自動呼叫，run_all.sh 結束時（含中途 STOP）也會呼叫，
所以流程跑到一半時打開也看得到目前進度（執行中會每 30 秒自動重新整理）。

資料來源（全部是流程本身寫出的檔案，儀表板不自己判定通過與否）：
  runs/<stage>/status.txt      run_stage.sh 寫的結果：PASS / FAIL / PAD_LIMITED / SKIP / RUNNING
  runs/stage_history.log       這一輪每次執行的紀錄（修正回圈會讓同一階段跑好幾次）
  各階段 console log 與報告     slack、面積、DRC/LVS 分類、ECO 動作等數字
沒有 status.txt 的舊專案，改用 log 裡的成功標記推斷（與 run_stage.sh 的判定相同）。
"""
import html
import os
import re
import sys
import time
from pathlib import Path

ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
TEXT = "--text" in sys.argv          # 另外在終端機印出流程表格
JSON = "--json" in sys.argv          # 只印 JSON（Claude Code 的 /flow 面板讀這個），不寫 HTML
PROJ = Path(ARGS[0] if ARGS else ".").resolve()
RUNS = PROJ / "runs"


def read(path):
    try:
        return Path(path).read_text(errors="replace")
    except OSError:
        return ""


def cfg(name, default=""):
    m = re.search(r"^\s*set\s+%s\s+(\S+)" % name, read(PROJ / "scripts" / "flow_config.tcl"), re.M)
    return m.group(1) if m else default


def result_lines(text, prefix):
    """工具會把 tcl 指令印回 log，只取行首是 prefix 的真正輸出"""
    return [l.strip() for l in text.splitlines() if l.startswith(prefix)]


def use_pad():
    """實際跑的模式：環境變數 > run_stage.sh 記錄的 flow_mode.txt > 舊專案看 pad 階段有沒有產生 wrapper > config"""
    if os.environ.get("USE_PAD"):
        return os.environ["USE_PAD"] == "1"
    m = re.search(r"USE_PAD=([01])", read(RUNS / "flow_mode.txt"))
    if m:
        return m.group(1) == "1"
    if "PAD_WRAPPER" in read(RUNS / "pad/console.log"):
        return True
    return cfg("USE_PAD", "0") == "1"


USE_PAD = use_pad()
DESIGN = cfg("DESIGN", "?")
TOP = DESIGN + "_chip" if USE_PAD else DESIGN

# ---------------- 流程定義：順序就是 design flow ----------------
# (id, 編號, 名稱, 工具, 通過標準, log, 成功標記, 種類)
#   種類 main = 必經階段；fix = 修正回圈（只有上一步發現問題才會跑）；pad = 只有 USE_PAD=1
PHASES = [
    ("設計決策", [
        ("pad", "0", "PAD wrapper＋PAD 延遲 model", "pad_tools.py",
         "由 RTL port 產生 wrapper，從 IO library 查出 PAD 延遲", "pad/console.log", "PAD_PASS|GATE_SIM_PASS", "pad"),
    ]),
    ("前段：功能與合成", [
        ("rtl_sim", "1", "RTL 模擬", "VCS", "tb 印出 PASS、mismatch = 0", "rtl_sim/console.log", "ALL PASS", "main"),
        ("synthesis", "2", "邏輯合成", "Design Compiler", "slack ≥ 0、無 constraint 違規", "synthesis/console.log", "DC_PASS", "main"),
        ("formality", "3", "等價驗證", "Formality", "Verification SUCCEEDED", "formality/console.log", "FM_PASS", "main"),
        ("sta", "4", "佈局前 STA", "PrimeTime ×3 corner", "每個 corner setup／hold ≥ 0", "sta/console_slow.log", "STA_PASS", "main"),
        ("gate_sim", "5", "閘級模擬＋SDF", "VCS", "功能 PASS、SDF 0 error、只容許已知 warning", "gate_sim/console.log", "GATE_SIM_PASS", "main"),
    ]),
    ("後段：APR", [
        ("ndm", "6-0", "建 NDM library", "ICC2 lm_shell", "library 建立完成", "ndm/console.log", "NDM_PASS", "main"),
        ("apr", "6", "floorplan → route", "IC Compiler II", "繞線 0 DRC／open／short", "apr/console.log", "APR_ROUTED", "main"),
        ("eco", "6", "APR ECO", "IC Compiler II", "max_cap／transition 清乾淨、PG 無浮接", "apr/eco_console.log", "APR_PASS", "main"),
        ("finish", "6", "filler、GDS、netlist", "IC Compiler II", "GDS 與兩份 netlist 寫出", "finish/console.log", "FINISH_PASS", "main"),
        ("drc_patch", "7a′", "M1 細條補丁", "IC Compiler II", "ICV 的 M1 錯誤全部補上", "apr/drc_patch_console.log", "DRC_PATCH_PASS", "fix"),
    ]),
    ("Signoff", [
        ("drc", "7a", "DRC", "IC Validator", "RESULTS: CLEAN（PAD 模式：核心區 0 錯誤）", "drc/console.log", "DRC_PASS|DRC_PAD_LIMITED", "main"),
        ("lvs", "7b", "LVS（電晶體層級）", "IC Validator", "Final comparison PASS（PAD 模式：MOS／電阻全對上）", "lvs/console.log", "LVS_PASS|LVS_PAD_LIMITED", "main"),
        ("starrc", "8", "寄生萃取", "StarRC ×3 corner", "每個 corner SPEF 產生", "starrc/console.log", "STARRC_PASS", "main"),
        ("pt_post", "9a", "繞線後 STA", "PrimeTime ×3 corner", "實際 RC 下 setup／hold ≥ 0、無違規", "pt_post/console_slow.log", "POSTROUTE_STA_PASS", "main"),
        ("signoff_eco", "9a′", "Signoff ECO", "IC Compiler II", "修掉 StarRC＋PT 看到的違規", "apr/signoff_eco_console.log", "SIGNOFF_ECO_PASS", "fix"),
        ("fm_post", "9b", "繞線後等價驗證", "Formality", "RTL vs routed netlist SUCCEEDED", "fm_post/console.log", "FM_POST_PASS", "main"),
        ("gate_post", "9c", "繞線後 SDF 模擬", "VCS", "功能 PASS、SDF 0 error", "gate_post/console.log", "GATE_SIM_PASS", "main"),
    ]),
]


# 每一步交給下一步的東西（讓流程的資料流看得出來）；修正回圈寫觸發條件
OUTPUT = {
    "pad": "{top}.v、io_pad_sim.v（帶延遲 PAD model）、pad_plan.tcl",
    "rtl_sim": "功能基準（之後每一步都和它比）",
    "synthesis": "{top}_syn.v、.sdc、.svf、.sdf",
    "formality": "netlist ≡ RTL 的證明",
    "sta": "{design}_<corner>.sdf（給閘級模擬）",
    "gate_sim": "含延遲的功能確認",
    "ndm": "stdcell_rvt.ndm（PAD 模式加 io.ndm）",
    "apr": "routed block",
    "eco": "乾淨的 routed block",
    "finish": "routed_full.gds、routed.v、routed_pg.v",
    "drc": "DRC 結果（PAD 模式另有 drc_classified.rpt）",
    "lvs": "LVS 結果（PAD 模式另有 lvs_classified.rpt）",
    "starrc": "{top}.spef ×3 corner",
    "pt_post": "{design}_postroute_<corner>.sdf",
    "fm_post": "routed netlist ≡ RTL 的證明",
    "gate_post": "最終功能確認",
}
TRIGGER = {
    "drc_patch": "觸發：DRC 有 M1 細條錯誤 → 補丁 → finish → DRC",
    "signoff_eco": "觸發：繞線後 STA 有違規 → ECO → finish → DRC → LVS → StarRC → STA",
}


# 這一步在做什麼（給 /ic_flow 面板點選階段時顯示，教學用的白話說明）
EXPLAIN = {
    "pad": "依 RTL 的 port 產生晶片 top（每個 port 接一顆 IO PAD），並從 IO library 查表算出 PAD 延遲，讓 RTL 模擬就帶 PAD 延遲。",
    "rtl_sim": "用官方 testbench 跑 RTL，確認功能正確；之後每一步都要跟這個結果一致。",
    "synthesis": "Design Compiler 依 SDC 時序約束，把 RTL 對應成 standard cell 組成的 gate-level netlist。",
    "formality": "不跑模擬，用數學方法證明合成出的 netlist 與 RTL 功能相同（逐一比對 compare point）。",
    "sta": "PrimeTime 在 slow／typical／fast 三個 corner 算每條路徑的 setup／hold slack，並寫出給閘級模擬的 SDF。",
    "gate_sim": "netlist 加上 SDF 延遲再跑一次 testbench，確認帶真實 cell 延遲時功能仍正確。",
    "ndm": "把 standard cell（與 IO PAD）的 LEF 外框和 timing 打包成 ICC2 用的 NDM library。",
    "apr": "ICC2 做 floorplan、電源網路、placement、CTS（時脈樹）與 routing，這一步只要求繞線乾淨。",
    "eco": "繞線後依報告自動在推不動的 net 插 buffer，清掉 max_cap／max_transition，並做 APR 最終判定。",
    "finish": "補 filler cell、寫出 GDS 與 netlist（含／不含電源接腳兩份），交給 signoff。",
    "drc_patch": "ICV 抓到 M1 太細的錯誤時，在 ICC2 補金屬成合法寬度，再回 finish → DRC。",
    "drc": "IC Validator 依製程規則逐條檢查 GDS（線寬、間距、密度…）。",
    "lvs": "從版圖萃取出電晶體與連線，和 CDL 電路圖逐項比對是否一致。",
    "starrc": "StarRC 從版圖萃取每條線的寄生電阻與電容，三個 RC corner 各寫一份 SPEF。",
    "pt_post": "PrimeTime 用 StarRC 的實際 RC 重算 slack 與 max_cap／transition，並寫出繞線後的 SDF。",
    "signoff_eco": "繞線後 STA 仍有違規時，自動換大顆 cell 或插 buffer，之後重跑 finish → DRC → LVS → StarRC → STA。",
    "fm_post": "證明繞線後的 netlist（含 CTS、ECO 加入的 buffer）仍與 RTL 功能相同。",
    "gate_post": "繞線後 netlist＋實際 RC 的 SDF 再跑一次 testbench，最終功能確認。",
}


def log_tail(path, n=6):
    """腳本自己印的結果行（DC_SLACK、PAD_DELAY、rtl RI=5 PASS…）最後 n 行；找不到才用 log 最後幾行"""
    lines = [l.rstrip() for l in read(path).splitlines() if l.strip()]
    tags = [l for l in lines if re.match(r"^[A-Z][A-Z0-9]*_[A-Z0-9_]*\b", l)
            and not re.search(r"_[RHL]VT$|^(START|END)_(FUNC|CMD)", l)
            or re.search(r"\b(PASS|FAIL)\b( \(.*\))?$", l) and not l.startswith("[")]
    return [l[:160] for l in (tags or lines)[-n:]]


# 終端機表格用的名稱：階段 (做什麼)
TERM_NAME = {
    "pad": "PAD_planning (pad_wrapper, pad_delay_model)",
    "rtl_sim": "RTL_coding (vcs_simulation)",
    "synthesis": "Synthesis (design_compiler_synthesis)",
    "formality": "Formality (function_checking)",
    "sta": "STA_prelayout (primetime_3corner)",
    "gate_sim": "Gate_sim (vcs_sdf_simulation)",
    "ndm": "NDM (icc2_library_build)",
    "apr": "APR (floorplan_place_cts_route)",
    "eco": "APR_ECO (maxcap_transition_fix)",
    "finish": "Finish (filler_gds_netlist)",
    "drc_patch": "DRC_patch (m1_patch)",
    "drc": "DRC (icv_drc)",
    "lvs": "LVS (icv_lvs_transistor)",
    "starrc": "PEX (starrc_extraction)",
    "pt_post": "STA_postroute (primetime_spef)",
    "signoff_eco": "Signoff_ECO (sizing_buffering)",
    "fm_post": "Formality_post (routed_vs_rtl)",
    "gate_post": "Gate_post (vcs_postroute_sdf)",
}


def history():
    h = {}
    for line in read(RUNS / "stage_history.log").splitlines():
        f = line.split()
        if len(f) >= 4:
            h.setdefault(f[0], []).append((f[1], int(f[2]), int(f[3])))
    return h


HIST = history()


def run_all_view():
    """run_all.log：每個階段「最後一次」的結果；最後一個開始但還沒有結果的階段 = 執行中"""
    text = read(RUNS / "run_all.log") or read(PROJ / "run_all.log")
    res, cur = {}, None
    for line in text.splitlines():
        m = re.match(r"^=== (\w+) ", line)
        if m:
            cur = m.group(1); res[cur] = "RUNNING"; continue
        m = re.match(r"^(\w+) (PASS|PAD_LIMITED|SKIP)$", line)
        if m and m.group(1) == cur:
            res[cur] = m.group(2)
        elif cur in ("sta", "pt_post") and re.match(r"^(POST )?STA PASS$", line):
            res[cur] = "PASS"   # 這兩個階段印的是 STA PASS／POST STA PASS
        elif cur and re.match(r"^(FAIL|STOP|.*\bFAIL\b)", line) and res.get(cur) == "RUNNING":
            res[cur] = "FAIL"
    # 只有最後一個階段可能還在跑；更早的「RUNNING」代表沒印出結果（多半是 FAIL）
    for k, v in res.items():
        if v == "RUNNING" and k != cur:
            res[k] = "FAIL"
    if cur and res.get(cur) == "RUNNING" and re.search(r"^(ALL_STAGES|STOP)", text, re.M):
        res[cur] = "FAIL"
    return res


RUN_ALL = run_all_view()


def status(sid, log, marker):
    st = read(RUNS / sid / "status.txt").split()
    if st:
        return st[0], (int(st[2]) if len(st) > 2 else None), (int(st[1]) if len(st) > 1 else None)
    if sid in RUN_ALL:
        return RUN_ALL[sid], None, None
    # 舊專案：用成功標記推斷
    text = read(RUNS / log)
    if not text:
        return "NOTRUN", None, None
    if re.search(r"^[A-Z]*_PAD_LIMITED", text, re.M):
        return "PAD_LIMITED", None, None
    if re.search(r"^(%s)" % marker, text, re.M):
        return "PASS", None, None
    return "FAIL", None, None


# ---------------- 各階段的關鍵數字 ----------------
def slack_table(stage, prefix):
    rows = {}
    for c in ("slow", "typical", "fast"):
        for l in result_lines(read(RUNS / stage / ("console_%s.log" % c)), prefix):
            m = re.search(r"setup=(-?[\d.]+) hold=(-?[\d.]+)", l)
            if m:
                rows[c] = (float(m.group(1)), float(m.group(2)))
    return rows


PRE = slack_table("sta", "STA_SLACK")
POST = slack_table("pt_post", "POSTROUTE_SLACK")


def worst(rows, i):
    return min(v[i] for v in rows.values()) if rows else None


def ns(v):
    return "—" if v is None else "%+.3f ns" % v


def metric(sid):
    """回傳 [(標籤, 值)]，卡片上顯示"""
    out = []
    if sid == "pad":
        t = read(RUNS / "pad/console.log")
        m = re.search(r"PAD_WRAPPER \S+: (\d+) signal pads(?: \((\d+) in, (\d+) out\))?", t)
        if m:
            out.append(("訊號 PAD", m.group(1) + (" (%s in / %s out)" % (m.group(2), m.group(3)) if m.group(2) else "")))
        for l in result_lines(t, "PAD_DELAY"):
            m = re.search(r"PAD_DELAY (\S+) (\S+) rise/fall = ([\d.]+)/([\d.]+)", l)
            if m:
                out.append((m.group(1), "%s / %s ns" % (m.group(3), m.group(4))))
    elif sid == "synthesis":
        for l in result_lines(read(RUNS / "synthesis/console.log"), "DC_SLACK"):
            m = re.search(r"setup=(-?[\d.]+) cell_area=([\d.]+)", l)
            if m:
                out += [("核心面積", "%.1f µm²" % float(m.group(2))), ("DC setup", "%+.3f ns" % float(m.group(1)))]
    elif sid == "sta" and PRE:
        out += [("worst setup", ns(worst(PRE, 0))), ("worst hold", ns(worst(PRE, 1)))]
    elif sid == "pt_post" and POST:
        out += [("worst setup", ns(worst(POST, 0))), ("worst hold", ns(worst(POST, 1)))]
    elif sid in ("gate_sim", "gate_post"):
        for l in result_lines(read(RUNS / sid / "console.log"), "SDF_NOTE"):
            m = re.search(r"SDF_NOTE (\w+): removal-check warnings=(\d+)", l)
            if m:
                out.append(("%s $removal" % m.group(1), m.group(2)))
    elif sid == "apr":
        t = read(RUNS / "apr/console.log")
        m = re.search(r"^PAD_FLOORPLAN pads=(\d+) \S+ die=(\S+) core=(\S+)", t, re.M)
        if m:
            out += [("die", m.group(2).replace("um", " µm")), ("core", m.group(3).replace("um", " µm")), ("PAD", m.group(1))]
        n = len(result_lines(t, "PAD_PG_STITCH pg_"))
        if n:
            out.append(("PAD→ring 接線", str(n)))
    elif sid == "eco":
        t = read(RUNS / "apr/eco_console.log")
        m = re.search(r"^ECO inserted (\d+) buffers", t, re.M)
        out.append(("插入 buffer", m.group(1) if m else "0"))
    elif sid == "drc_patch":
        m = re.findall(r"^DRC_PATCH: patched (\d+) / (\d+)", read(RUNS / "apr/drc_patch_console.log"), re.M)
        if m:
            out.append(("補丁（最後一次）", "%s / %s" % m[-1]))
    elif sid == "signoff_eco":
        t = read(RUNS / "apr/signoff_eco_console.log")
        out.append(("最後一次動作", str(len(result_lines(t, "SIZE")) + len(result_lines(t, "BUFFER")))))
    elif sid == "drc":
        t = read(RUNS / "drc/console.log")
        m = re.search(r"^DRC_CLASSIFY io_ring=(\d+).*stitch=(\d+).*core=(\d+)", t, re.M)
        if m:
            out += [("核心區", m.group(3)), ("IO ring", m.group(1)), ("PAD 接縫", m.group(2))]
        elif re.search(r"^DRC_PASS", t, re.M):
            out.append(("結果", "CLEAN"))
    elif sid == "lvs":
        t = read(RUNS / "lvs/lvs_classified.rpt")
        mos = sum(int(x) for x in re.findall(r"^[NP]MOS\[\w+\] matched=(\d+)", t, re.M))
        res = sum(int(x) for x in re.findall(r"^RES\[\w+\] matched=(\d+)", t, re.M))
        if mos:
            out += [("MOS 對上", "{:,}".format(mos)), ("電阻對上", str(res))]
        elif re.search(r"^LVS_PASS", read(RUNS / "lvs/console.log"), re.M):
            out.append(("結果", "PASS"))
    elif sid == "starrc":
        n = len(result_lines(read(RUNS / "starrc/console.log"), "SPEF"))
        if n:
            out.append(("SPEF corner", str(n)))
    return out


# ---------------- HTML ----------------
LABEL = {"PASS": "PASS", "FAIL": "FAIL", "PAD_LIMITED": "PAD_LIMITED", "SKIP": "略過",
         "RUNNING": "執行中", "NOTRUN": "未執行", "NOTNEEDED": "不需要"}
E = html.escape


def card(s, st, dur, runs):
    sid, num, name, tool, crit, log, marker, kind = s
    ms = "".join('<div class="kv"><span>%s</span><b>%s</b></div>' % (E(k), E(v)) for k, v in metric(sid))
    meta = []
    if dur is not None and st not in ("RUNNING", "SKIP"):
        meta.append("%d 分 %02d 秒" % divmod(dur, 60) if dur >= 60 else "%d 秒" % dur)
    if len(runs) > 1:
        meta.append("這一輪跑了 %d 次" % len(runs))
    if sid in TRIGGER:
        flow = '<p class="out trig">%s</p>' % E(TRIGGER[sid])
    else:
        flow = '<p class="out">產出 → %s</p>' % E(OUTPUT.get(sid, "").format(top=TOP, design=DESIGN))
    logp = RUNS / log
    link = '<a href="%s">log</a>' % E(os.path.relpath(logp, RUNS)) if logp.exists() else ""
    return ('<article class="stage s-%s%s"><header><span class="num">%s</span><span class="pill">%s</span></header>'
            '<h3>%s</h3><p class="tool">%s</p><p class="crit">%s</p>%s%s<footer>%s%s</footer></article>'
            % (st.lower(), " fix" if kind == "fix" else "", E(num), LABEL[st], E(name), E(tool), E(crit), ms, flow,
               E(" · ".join(meta)), (" · " if meta and link else "") + link))


ROWS = []   # (stage 定義, 狀態, 耗時, 這一輪執行次數)，終端機表格用


def width(s):
    import unicodedata
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def pad(s, n):
    return s + " " * max(0, n - width(s))


def cut(s, n):
    out = ""
    for c in s:
        if width(out + c) > n - 1:
            return out + "…"
        out += c
    return out


def text_keys(sid):
    """終端機表格的關鍵數字：英文縮寫，一列放得下"""
    m = dict(metric(sid))
    if sid == "pad":
        d = [v.replace(" ns", "").replace(" ", "") for k, v in metric(sid) if k not in ("訊號 PAD",)]
        n = m.get("訊號 PAD", "").split(" ")[0]
        r2 = lambda x: "/".join("%.2f" % float(v) for v in x.split("/"))
        return "pads %s, in %s, out %s ns" % (n, r2(d[0]), r2(d[1])) if len(d) >= 2 else ""
    if sid == "synthesis" and m:
        return "area %s, setup %s" % (m["核心面積"].replace(" µm²", ""), m["DC setup"])
    if sid in ("sta", "pt_post") and m:
        return "setup %s / hold %s ns" % (m["worst setup"].replace(" ns", ""), m["worst hold"].replace(" ns", ""))
    if sid in ("gate_sim", "gate_post") and m:
        return "SDF $removal warn %s" % "/".join(v for k, v in metric(sid))
    if sid == "apr" and m:
        return "die %s, core %s" % (m.get("die", ""), m.get("core", ""))
    if sid == "eco":
        return "buffers +%s" % m.get("插入 buffer", "0")
    if sid == "drc_patch" and m:
        return "M1 patched %s" % m["補丁（最後一次）"]
    if sid == "signoff_eco" and m:
        return "cells changed %s" % m["最後一次動作"]
    if sid == "drc":
        if "核心區" in m:
            return "core %s, io_ring %s, stitch %s" % (m["核心區"], m["IO ring"], m["PAD 接縫"])
        return "CLEAN" if m else ""
    if sid == "lvs":
        if "MOS 對上" in m:
            return "MOS %s, RES %s matched" % (m["MOS 對上"], m["電阻對上"])
        return "PASS" if m else ""
    if sid == "starrc" and m:
        return "SPEF x%s corners" % m["SPEF corner"]
    return ""


def text_table(headline, overall):
    color = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
    C = {"PASS": "32", "FAIL": "31;1", "PAD_LIMITED": "33", "RUNNING": "30;46;1",
         "SKIP": "2", "NOTRUN": "2", "NOTNEEDED": "2"}
    TXT = {"PASS": "PASS", "FAIL": "FAIL", "PAD_LIMITED": "PAD_LIMITED", "RUNNING": "RUNNING",
           "SKIP": "skip", "NOTRUN": "-", "NOTNEEDED": "not needed"}

    def paint(st, s):
        return "\033[%sm%s\033[0m" % (C[st], s) if color else s
    W = [44, 11, 40, 8]
    line = lambda l, m, r: l + m.join("─" * (w + 2) for w in W) + r
    out = ["", "  %s design flow — %s   top=%s" % (DESIGN, "USE_PAD 1 (with IO PAD)" if USE_PAD else "USE_PAD 0 (core only)", TOP),
           line("┌", "┬", "┐"),
           "│ " + " │ ".join(pad(h, w) for h, w in zip(("Stage (steps)", "Status", "Key numbers", "Time"), W)) + " │"]
    phase_of = {s[0]: ph for ph, items in PHASES for s in items}
    last = None
    for s, st, dur, n in ROWS:
        if phase_of[s[0]] != last:
            last = phase_of[s[0]]
            out.append(line("├", "┼", "┤"))
        running = st == "RUNNING"
        name = ("▶ " if running else "") + TERM_NAME.get(s[0], s[2]) + (" *" if s[7] == "fix" else "")
        keys = text_keys(s[0]) if st not in ("NOTRUN", "SKIP", "NOTNEEDED") else ""
        tm = "" if dur is None or st in ("RUNNING", "SKIP") else ("%d:%02d" % divmod(dur, 60))
        if n > 1:
            tm += " x%d" % n
        cells = [pad(cut(name, W[0]), W[0]), paint(st, pad(TXT[st], W[1])),
                 pad(cut(keys, W[2]), W[2]), pad(tm, W[3])]
        if running and color:   # 正在跑的那一列整列粗體
            cells = ["\033[1m%s\033[0m" % c if i != 1 else c for i, c in enumerate(cells)]
        out.append("│ " + " │ ".join(cells) + " │")
    out.append(line("└", "┴", "┘"))
    out.append("  " + paint({"pass": "PASS", "fail": "FAIL", "pad_limited": "PAD_LIMITED", "running": "RUNNING"}.get(overall, "NOTRUN"), headline[0]) + "  " + headline[1])
    out.append("  * = 修正回圈（上一步發現問題才會跑）   xN = 這一輪跑了 N 次   詳細：runs/dashboard.html")
    print("\n".join(out))


def stage_detail(s, st):
    sid, num, name, tool, crit, log, marker, kind = s
    logp = RUNS / log
    ran = st not in ("NOTRUN", "SKIP", "NOTNEEDED")
    return {
        "num": num, "title": name, "tool": tool, "explain": EXPLAIN.get(sid, ""), "crit": crit,
        "output": TRIGGER.get(sid) or "產出 → " + OUTPUT.get(sid, "").format(top=TOP, design=DESIGN),
        "metrics": [[k, v] for k, v in metric(sid)] if ran else [],
        "log": str(logp) if logp.exists() else "",
        "tail": log_tail(logp) if ran and logp.exists() else [],
    }


def json_out(headline, overall):
    import json
    phase_of = {s[0]: ph for ph, items in PHASES for s in items}
    rows = []
    for s, st, dur, n in ROWS:
        rows.append({
            "id": s[0], "phase": phase_of[s[0]], "name": TERM_NAME.get(s[0], s[2]), "status": st,
            "keys": text_keys(s[0]) if st not in ("NOTRUN", "SKIP", "NOTNEEDED") else "",
            "time": "" if dur is None or st in ("RUNNING", "SKIP") else "%d:%02d" % divmod(dur, 60),
            "runs": n, "fix": s[7] == "fix",
            "detail": stage_detail(s, st)})
    print(json.dumps({"design": DESIGN, "usePad": USE_PAD, "top": TOP, "overall": overall.upper(),
                      "headline": headline[0], "sub": headline[1], "project": str(PROJ),
                      "generated": time.strftime("%H:%M:%S"), "rows": rows}, ensure_ascii=False))


def main():
    stages, overall = [], "PASS"
    body = []
    for phase, items in PHASES:
        cards = []
        for s in items:
            sid, kind = s[0], s[7]
            st, dur, _ = status(sid, s[5], s[6])
            if kind == "pad" and not USE_PAD:
                st = "SKIP"
            if kind == "fix" and st == "NOTRUN":
                st = "NOTNEEDED"
            stages.append((s, st))
            ROWS.append((s, st, dur, len(HIST.get(sid, []))))
            cards.append(card(s, st, dur, HIST.get(sid, [])))
        body.append('<section class="phase"><h2>%s</h2><div class="row">%s</div></section>' % (E(phase), "".join(cards)))
    sts = [st for s, st in stages if s[7] != "fix"]
    running = "RUNNING" in sts
    if running:
        # 修正回圈進行中時，上一次 FAIL 的階段會被重跑，所以執行中優先
        overall = "RUNNING"
    elif any(st == "FAIL" for s, st in stages):
        overall = "FAIL"
    elif "NOTRUN" in sts:
        overall = "INCOMPLETE"
    elif "PAD_LIMITED" in sts:
        overall = "PAD_LIMITED"
    first_fail = next((s for s, st in stages if st == "FAIL"), None)
    current = next((s for s, st in stages if st == "RUNNING"), None)
    headline = {
        "PASS": ("ALL_STAGES_PASS", "全部階段通過。"),
        "PAD_LIMITED": ("ALL_STAGES_DONE_PAD_LIMITED", "全部跑完；DRC／LVS 只剩 IO library 的問題，這不等於 PASS。"),
        "FAIL": ("FAIL", "停在「%s %s」，先看這個階段的 log。" % (first_fail[1], first_fail[2]) if first_fail else "有階段失敗。"),
        "RUNNING": ("RUNNING", "正在執行「%s %s」。" % (current[1], current[2]) if current else "執行中。"),
        "INCOMPLETE": ("INCOMPLETE", "還有階段沒跑。"),
    }[overall]

    # 時序表：佈局前 vs 繞線後，每個 corner
    trs = []
    for c in ("slow", "typical", "fast"):
        def cell(rows, i):
            v = rows.get(c, (None, None))[i]
            return '<td class="%s">%s</td>' % ("neg" if v is not None and v < 0 else "", ns(v))
        trs.append("<tr><th>%s</th>%s%s%s%s</tr>" % (c, cell(PRE, 0), cell(PRE, 1), cell(POST, 0), cell(POST, 1)))
    timing = ('<section class="panel wide"><h2>時序（slack）</h2><table><thead><tr><th>corner</th><th>佈局前 setup</th>'
              '<th>佈局前 hold</th><th>繞線後 setup</th><th>繞線後 hold</th></tr></thead><tbody>%s</tbody></table>'
              '<p class="note">佈局前用 wire-load 估計；繞線後用 StarRC 萃取的實際 RC。%s</p></section>'
              % ("".join(trs), "PAD 模式兩者都含 PAD 延遲與 1 pF 板級負載。" if USE_PAD else ""))

    # 執行紀錄：依時間順序列出這一輪每一次執行（看得出修正回圈）
    hist = sorted(((t0, sid, r, d) for sid, v in HIST.items() for r, t0, d in v))
    hrows = "".join('<tr><td>%s</td><td>%s</td><td><span class="pill p-%s">%s</span></td><td>%s</td></tr>'
                    % (time.strftime("%H:%M:%S", time.localtime(t0)), E(sid), r.lower(), LABEL.get(r, r),
                       "%d:%02d" % divmod(d, 60)) for t0, sid, r, d in hist)
    histp = ('<section class="panel"><h2>這一輪的執行紀錄</h2><table><thead><tr><th>開始</th><th>階段</th><th>結果</th>'
             '<th>耗時</th></tr></thead><tbody>%s</tbody></table></section>' % hrows) if hrows else ""

    limits = ""
    if USE_PAD:
        limits = ('<section class="panel warn"><h2>PAD 模式要知道的事</h2><ul>'
                  '<li><b>PAD_LIMITED 不是 PASS</b>：腳本已確認核心區 DRC 為 0、所有 MOS／電阻都對上，剩下的錯誤在 SAED32 io_std library 內（LEF／GDS／CDL 不一致）。</li>'
                  '<li>LVS 中 VDD／VSS／VDDIO／VSSIO 在 layout 併成同一個 net，是 IO library 造成的（拿掉 PAD→ring 接線也一樣）。</li>'
                  '<li>要乾淨的 DRC／LVS 證據，另外用 <code>USE_PAD 0</code> 跑核心。</li></ul></section>')

    if JSON:
        json_out(headline, overall)
        return
    refresh = '<meta http-equiv="refresh" content="30">' if overall == "RUNNING" else ""
    page = TEMPLATE % dict(
        refresh=refresh, title=E("%s %s flow" % (DESIGN, "PAD" if USE_PAD else "core")), design=E(DESIGN), top=E(TOP),
        mode="USE_PAD 1：含 IO PAD 的全晶片" if USE_PAD else "USE_PAD 0：只做核心",
        process=E(cfg("PROCESS", "?")), period=E(cfg("PERIOD", "?")), clk=E(cfg("CLK_PORT", "?")),
        overall=overall.lower(), headline=E(headline[0]), sub=E(headline[1]),
        now=time.strftime("%Y-%m-%d %H:%M:%S"), proj=E(str(PROJ)),
        phases="".join(body), timing=timing, hist=histp, limits=limits)
    (RUNS).mkdir(parents=True, exist_ok=True)
    (RUNS / "dashboard.html").write_text(page)
    if TEXT:
        text_table(headline, overall.lower())
    else:
        print("DASHBOARD %s (%s)" % (RUNS / "dashboard.html", headline[0]))


TEMPLATE = """<!doctype html>
<html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
%(refresh)s<title>%(title)s</title>
<style>
:root{--bg:#f6f7f9;--panel:#fff;--ink:#1d232b;--mute:#5d6875;--line:#dde2e8;
 --pass:#1f7a4d;--pass-bg:#e3f4ea;--fail:#b42318;--fail-bg:#fde8e6;--lim:#a15c00;--lim-bg:#fff1d6;
 --run:#1d5fb8;--run-bg:#e2edfb;--off:#7b8794;--off-bg:#eef1f4}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#12161b;--panel:#1b2128;--ink:#e6eaef;--mute:#9aa6b2;--line:#2d3540;
 --pass:#5cc98f;--pass-bg:#17352a;--fail:#ff8a7a;--fail-bg:#3d1e1b;--lim:#f2b45a;--lim-bg:#3a2c14;
 --run:#7fb2ff;--run-bg:#18304f;--off:#8794a1;--off-bg:#232a33}}
:root[data-theme="dark"]{--bg:#12161b;--panel:#1b2128;--ink:#e6eaef;--mute:#9aa6b2;--line:#2d3540;
 --pass:#5cc98f;--pass-bg:#17352a;--fail:#ff8a7a;--fail-bg:#3d1e1b;--lim:#f2b45a;--lim-bg:#3a2c14;
 --run:#7fb2ff;--run-bg:#18304f;--off:#8794a1;--off-bg:#232a33}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);
 font:14px/1.5 system-ui,-apple-system,"Segoe UI","Noto Sans TC","PingFang TC",sans-serif}
main{max-width:1240px;margin:0 auto;padding:24px 16px 48px}
.top{display:flex;flex-wrap:wrap;gap:16px;align-items:flex-end;justify-content:space-between;margin-bottom:18px}
h1{margin:0;font-size:22px}.sub{color:var(--mute);margin:2px 0 0}
.facts{display:flex;flex-wrap:wrap;gap:6px}.facts span{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:3px 9px;color:var(--mute)}
.facts b{color:var(--ink);font-weight:600}
.banner{border-radius:10px;padding:14px 18px;margin-bottom:22px;border:1px solid var(--line);background:var(--panel)}
.banner strong{font-size:18px;letter-spacing:.02em}.banner p{margin:2px 0 0;color:var(--mute)}
.o-pass{border-left:6px solid var(--pass)}.o-pass strong{color:var(--pass)}
.o-fail{border-left:6px solid var(--fail)}.o-fail strong{color:var(--fail)}
.o-pad_limited{border-left:6px solid var(--lim)}.o-pad_limited strong{color:var(--lim)}
.o-running{border-left:6px solid var(--run)}.o-running strong{color:var(--run)}
.o-incomplete{border-left:6px solid var(--off)}
.phase{margin-bottom:20px}.phase h2,.panel h2{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--mute);margin:0 0 8px}
.row{display:grid;grid-template-columns:repeat(auto-fill,minmax(205px,1fr));gap:10px}
.stage{position:relative;background:var(--panel);border:1px solid var(--line);border-top:4px solid var(--off);border-radius:8px;padding:10px 12px;display:flex;flex-direction:column}
.stage.fix{border-style:dashed;border-top-style:solid}
.stage header{display:flex;justify-content:space-between;align-items:center}
.num{font-weight:700;color:var(--mute);font-variant-numeric:tabular-nums}
.stage h3{margin:4px 0 0;font-size:15px}.tool{margin:0;color:var(--mute);font-size:12px}
.crit{margin:6px 0;font-size:12px;color:var(--mute);border-left:2px solid var(--line);padding-left:6px}
.kv{display:flex;justify-content:space-between;gap:8px;font-size:12.5px;border-top:1px dotted var(--line);padding:2px 0}
.kv span{color:var(--mute)}.kv b{font-variant-numeric:tabular-nums;font-weight:600;text-align:right}
.out{margin:6px 0 0;font-size:12px;color:var(--ink)}.out.trig{color:var(--lim)}
.stage footer{margin-top:auto;padding-top:6px;font-size:12px;color:var(--mute)}
a{color:var(--run)}
.pill{font-size:11px;font-weight:700;border-radius:999px;padding:1px 8px;background:var(--off-bg);color:var(--off)}
.s-pass{border-top-color:var(--pass)}.s-pass .pill,.p-pass{background:var(--pass-bg);color:var(--pass)}
.s-fail{border-top-color:var(--fail)}.s-fail .pill,.p-fail{background:var(--fail-bg);color:var(--fail)}
.s-pad_limited{border-top-color:var(--lim)}.s-pad_limited .pill,.p-pad_limited{background:var(--lim-bg);color:var(--lim)}
.s-running{border-top-color:var(--run)}.s-running .pill,.p-running{background:var(--run-bg);color:var(--run)}
.s-skip,.s-notneeded{opacity:.6}
.grid2{display:grid;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));gap:14px;margin-top:8px}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:12px 14px;overflow-x:auto}
.panel.wide{grid-column:1/-1}.panel.warn{border-left:4px solid var(--lim)}.panel ul{margin:0;padding-left:18px}
table{border-collapse:collapse;width:100%%;font-variant-numeric:tabular-nums}
th,td{text-align:left;padding:4px 8px;border-bottom:1px solid var(--line);white-space:nowrap}
thead th{color:var(--mute);font-weight:600;font-size:12px}td.neg{color:var(--fail);font-weight:700}
.note{color:var(--mute);font-size:12px;margin:8px 0 0}
.legend{display:flex;flex-wrap:wrap;gap:12px;color:var(--mute);font-size:12px;margin:-6px 0 18px}
code{font-size:12px}
footer.page{margin-top:24px;color:var(--mute);font-size:12px}
</style></head><body><main>
<div class="top"><div><h1>%(design)s — design flow</h1><p class="sub">%(mode)s · top = <code>%(top)s</code></p></div>
<div class="facts"><span>製程 <b>%(process)s</b></span><span>週期 <b>%(period)s ns</b></span><span>clock <b>%(clk)s</b></span></div></div>
<div class="banner o-%(overall)s"><strong>%(headline)s</strong><p>%(sub)s</p></div>
<div class="legend"><span>卡片依流程順序排列；每張卡寫出這一步的通過標準。</span><span>虛線框 = 修正回圈（上一步發現問題才會跑）</span><span>判定結果全部來自 run_stage.sh 與各階段 log，儀表板不自己判定。</span></div>
%(phases)s
<div class="grid2">%(timing)s%(limits)s%(hist)s</div>
<footer class="page">產生時間 %(now)s · <code>%(proj)s</code> · 由 scripts/flow_dashboard.py 產生</footer>
</main></body></html>
"""

# ---------------- 專案歷史（/ic_flow 面板的 history） ----------------
# 每次產生報表就把專案登記到 ~/.claude/ic-flow/projects.txt（一行一個路徑），
# --history 列出所有還存在的專案，最近有動的在前，正在跑的最前面。
REGISTRY = Path.home() / ".claude" / "ic-flow" / "projects.txt"


def register_project():
    if not (PROJ / "scripts" / "flow_config.tcl").exists():
        return
    try:
        REGISTRY.parent.mkdir(parents=True, exist_ok=True)
        known = [l for l in read(REGISTRY).splitlines() if l.strip()]
        if str(PROJ) not in known:
            with open(str(REGISTRY), "a") as f:
                f.write(str(PROJ) + "\n")
    except OSError:
        pass


def last_activity(proj):
    files = list((proj / "runs").glob("*/status.txt")) + [proj / "runs" / "stage_history.log",
                                                           proj / "runs" / "run_all.log", proj / "run_all.log"]
    times = [f.stat().st_mtime for f in files if f.exists()]
    return max(times) if times else 0


def history_out():
    import json
    import subprocess
    out = []
    for line in read(REGISTRY).splitlines():
        proj = Path(line.strip())
        if not line.strip() or not (proj / "scripts" / "flow_config.tcl").exists():
            continue
        try:
            js = subprocess.run([sys.executable, __file__, str(proj), "--json"], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, timeout=20).stdout.decode("utf-8", "replace")
            d = json.loads(next(l for l in js.splitlines() if l.startswith("{")))
        except Exception:
            continue
        last = last_activity(proj)
        cur = next((r["name"].split(" ")[0] for r in d["rows"] if r["status"] == "RUNNING"), "")
        out.append({"path": str(proj), "name": proj.name, "design": d["design"], "usePad": d["usePad"],
                    "overall": d["overall"], "headline": d["headline"], "running": cur,
                    "last": last, "lastText": time.strftime("%m-%d %H:%M", time.localtime(last)) if last else "-"})
    out.sort(key=lambda h: (h["overall"] != "RUNNING", -h["last"]))
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    if "--history" in sys.argv:
        history_out()
    else:
        register_project()
        main()
