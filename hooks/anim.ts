// anim.ts — /ic_flow 面板下方的小動畫（圖由 gen.py 產生並檢查過框線對齊）
//   build    由左到右一欄一欄「組裝」出來，組完停一下再重來
//   scan     一條亮柱由左掃到右（STA：訊號沿路徑傳）
//   magnify  圓形放大鏡在晶片上左右來回掃（DRC）
//   wave     波形往左捲動（RTL／Gate-level sim）
//   blink    整張圖閃爍（全部完成／失敗）

export type Anim = {
  mode: 'build' | 'scan' | 'magnify' | 'wave' | 'blink'
  caption: string
  art: string[]
  color?: string
}

// 一行畫的一段：hot = 反白（亮柱、放大鏡裡），lens = 放大鏡框
export type Seg = { text: string; hot?: boolean; lens?: boolean }
export type Frame = { lines: Seg[][]; caption: string; color?: string; dim?: boolean }

const PATH = ["  ┌────┐    ┌────┐    ┌────┐    ┌────┐    ┌────┐", " ─┤ FF ├────┤ &  ├────┤ ≥1 ├────┤ ⊕  ├────┤ FF ├─", "  └────┘    └────┘    └────┘    └────┘    └────┘", "  launch ────────── data path ────────── capture"]
const WAVE = ['clk', 'reset', 'X', 'valid']

export const ANIMS: Record<string, Anim> = {
  pad: { mode: 'build', caption: '在核心四周擺 IO PAD…', art: [" ▣ ▣ ▣ ▣ ▣ ▣ ▣ ▣ ▣ ▣", " ▣ ┌─────────────┐ ▣", " ▣ │             │ ▣", " ▣ │    CORE     │ ▣", " ▣ │             │ ▣", " ▣ └─────────────┘ ▣", " ▣ ▣ ▣ ▣ ▣ ▣ ▣ ▣ ▣ ▣"] },
  rtl_sim: { mode: 'wave', caption: 'RTL 模擬中：送 pattern、比對輸出…', art: WAVE },
  synthesis: { mode: 'build', caption: '把 RTL 組成 DFF 與邏輯閘…', art: [" a ──┐  ┌────┐     ┌───────┐", "     ├──┤ &  ├─────┤D     Q├────┐", " b ──┘  └────┘     │  DFF  │    │   ┌────┐", "                   │>      │    └───┤    │", " c ──┐  ┌────┐     └───────┘        │ ⊕  ├── out", "     ├──┤ ≥1 ├──────────────────────┤    │", " d ──┘  └────┘                      └────┘"] },
  formality: { mode: 'build', caption: '逐一比對 compare point：RTL ≡ netlist', art: ["   RTL                 NETLIST", " ┌──────────┐       ┌────┐ ┌────┐ ┌────┐", " │ always @ │  ≡≡≡  │ &  │ │ ≥1 │ │ FF │", " │ if/else  │       └────┘ └────┘ └────┘", " └──────────┘", " compare points  ✓ ✓ ✓ ✓ ✓ ✓ ✓ ✓ ✓"] },
  sta: { mode: 'scan', caption: '沿著時序路徑算 slack（三個 corner）…', art: PATH },
  gate_sim: { mode: 'wave', caption: 'Gate-level sim：每顆 cell 都帶 SDF 延遲…', art: WAVE },
  ndm: { mode: 'build', caption: '建 NDM：把 cell 的 LEF 與 timing 包成 library…', art: ["  ┌───────────────────────────┐", "  │ stdcell_rvt.ndm   ▤ ▤ ▤ ▤ │", "  ├───────────────────────────┤", "  │ io.ndm            ▣ ▣ ▣ ▣ │", "  └───────────────────────────┘"] },
  apr: { mode: 'build', caption: 'Placement → CTS → Route：cell 由左到右擺進去…', art: [" ┌───────────────────────────────────┐", " │ ▤ ▤▤▤▤ ▤▤▤▤ ▤ ▤▤ ▤▤▤▤ ▤▤▤▤ ▤▤▤ ▤▤ │", " │═══════════════════════════════════│", " │ ▤▤▤▤ ▤▤▤▤ ▤▤▤▤ ▤▤ ▤▤ ▤▤▤▤ ▤▤ ▤ ▤▤ │", " │═══════════════════════════════════│", " │ ▤▤▤▤ ▤▤▤ ▤▤▤ ▤▤ ▤▤▤▤ ▤ ▤▤▤ ▤▤▤▤ ▤ │", " └───────────────────────────────────┘"] },
  eco: { mode: 'build', caption: '推不動的 net 插 buffer…', art: [" ┌────┐                          ┌────┐", " │ FF ├─────────────┬────────────┤    │", " └────┘             │            └────┘", "                 ┌──┴──┐", "                 │  ▷  │  NBUFFX4", "                 └─────┘"] },
  finish: { mode: 'build', caption: '補 filler、寫出 GDS 與 netlist…', art: [" ┌───────────────────────────────────┐", " │ ▤▤░▤▤▤░▤░▤▤▤░▤▤░▤░▤▤▤▤░▤▤▤▤░▤░▤░▤░│", " │═══════════════════════════════════│", " │ ▤▤░▤▤▤▤░▤▤▤▤░▤▤▤░▤▤▤▤░▤▤░▤▤▤▤░▤▤░░│", " └───────────────────────────────────┘", "            → routed_full.gds"] },
  drc_patch: { mode: 'build', caption: '把太細的 M1 補成合法寬度…', art: [" ┌────────────────┐", " │ █ █ ▌ ███ █ ██ │", " │ █▄█▄▌▄█▄█▄█▄██ │  ← M1.W.2.1 細條", " │ ▀▀▀▀▀▀▀▀▀▀▀▀▀▀ │  補成合法寬度", " └────────────────┘"] },
  drc: { mode: 'magnify', caption: '放大鏡一區一區檢查 design rule（404 條）…', art: [" ┌───────────────────────────────────┐", " │ ▀▀ ███ ▄▄▄ ███ ▄▄▄ ▄▄▄ ▄▄▄ ▀▀ ██  │", " │ █ ▄▄▄ ██ █ ██ ███ ▌ █ ▌ ▀▀ ██ ▀▀  │", " │ ██ ▄▄▄ █ ▌ ███ █ ▌ █ ██ █ ▀▀ ▀▀ ▌ │", " │ █ █ ██ ██ █ █ █ █ ███ ███ █ ▀▀ ▄▄ │", " └───────────────────────────────────┘"] },
  lvs: { mode: 'build', caption: '版圖萃取出的電晶體 ⇄ 電路圖，逐項配對…', art: ["  layout             schematic", "  NMOS ▮▮▮▮▮▮▮▮  ⇄  ▮▮▮▮▮▮▮▮  ✓", "  PMOS ▮▮▮▮▮▮▮▮  ⇄  ▮▮▮▮▮▮▮▮  ✓", "  RES  ▮▮        ⇄  ▮▮        ✓", "  nets ━━━━━━━━  ⇄  ━━━━━━━━  ✓"] },
  starrc: { mode: 'build', caption: '萃取每條線的 R 與 C…', art: [" ───┬──/\\/\\/──┬──/\\/\\/──┬──/\\/\\/──┬───", "    ═         ═         ═         ═", "    ┴         ┴         ┴         ┴", "   Cmax        nominal         Cmin"] },
  pt_post: { mode: 'scan', caption: '用實際 RC 重算 slack…', art: PATH },
  signoff_eco: { mode: 'build', caption: '把太小的 cell 換大一號…', art: [" ┌──────┐        ┌────────┐", " │NAND2 │  ───▶  │ NAND2  │", " │  X1  │        │   X2   │", " └──────┘        └────────┘"] },
  fm_post: { mode: 'build', caption: '繞線後的 netlist 還等於 RTL 嗎？', art: ["   RTL                 ROUTED NETLIST", " ┌──────────┐       ┌────┐ ┌────┐ ┌────┐ ┌────┐", " │ always @ │  ≡≡≡  │ &  │ │ ▷  │ │ FF │ │ ▷  │", " │ if/else  │       └────┘ └────┘ └────┘ └────┘", " └──────────┘", " compare points  ✓ ✓ ✓ ✓ ✓ ✓ ✓ ✓ ✓"] },
  gate_post: { mode: 'wave', caption: '繞線後 SDF 模擬：真正的線延遲…', art: WAVE },
  done: { mode: 'blink', caption: '全部跑完！', color: 'success', art: ["     ┃┃┃┃┃┃┃┃┃┃┃┃", "   ━┏━━━━━━━━━━━━┓━", "   ━┃   ✓ DONE   ┃━", "   ━┃ tape-out?  ┃━", "   ━┗━━━━━━━━━━━━┛━", "     ┃┃┃┃┃┃┃┃┃┃┃┃"] },
  fail: { mode: 'blink', caption: '有階段失敗，先看那一列的 log', color: 'error', art: ["    ┏━━━━━━━━━━━━┓", "    ┃     ✗      ┃", "    ┃    FAIL    ┃", "    ┗━━━━━━━━━━━━┛"] },
}

const chars = (s: string) => [...s]
const widthOf = (art: string[]) => Math.max(...art.map(l => chars(l).length))

// 每格一個字與它的樣式，最後把相同樣式的字併成一段
type Cell = { ch: string; hot?: boolean; lens?: boolean }
const toSegs = (cells: Cell[]): Seg[] => {
  const out: Seg[] = []
  for (const c of cells) {
    const last = out[out.length - 1]
    if (last && !!last.hot === !!c.hot && !!last.lens === !!c.lens) last.text += c.ch
    else out.push({ text: c.ch, hot: c.hot, lens: c.lens })
  }
  return out
}
const grid = (art: string[]): Cell[][] => {
  const w = widthOf(art)
  return art.map(l => chars(l.padEnd(w)).map(ch => ({ ch })))
}

// 由左到右：第 k 格顯示前 k/STEPS 的欄
function build(a: Anim, f: number): Seg[][] {
  const STEPS = 16, HOLD = 6
  const w = widthOf(a.art)
  const k = f % (STEPS + HOLD)
  const upto = Math.ceil((w * Math.min(k + 1, STEPS)) / STEPS)
  return grid(a.art).map(row => toSegs(row.map((c, i) => (i < upto ? c : { ch: ' ' }))))
}

function scan(a: Anim, f: number): Seg[][] {
  const w = widthOf(a.art)
  const col = f % (w + 4)
  return grid(a.art).map(row => toSegs(row.map((c, i) => (i === col ? { ch: c.ch === ' ' ? '│' : c.ch, hot: true } : c))))
}

// 放大鏡：鏡框 9 寬，蓋在晶片第 1–4 行，柄在右下；左右來回（ping-pong）
function magnify(a: Anim, f: number): Seg[][] {
  const g = grid(a.art)
  const w = widthOf(a.art)
  const LW = 9
  // 鏡框與柄都留在晶片框線內：x 從 2 到 w - LW - 2
  const span = Math.max(1, w - LW - 4)
  const p = f % (2 * span)
  const x = 2 + (p < span ? p : 2 * span - p)
  const put = (r: number, c: number, cell: Cell) => { if (g[r] && c >= 0 && c < w) g[r][c] = cell }
  const lens = (ch: string): Cell => ({ ch, lens: true })
  put(1, x, lens('╭')); put(1, x + LW - 1, lens('╮'))
  put(4, x, lens('╰')); put(4, x + LW - 1, lens('╯'))
  for (let c = x + 1; c < x + LW - 1; c++) { put(1, c, lens('─')); put(4, c, lens('─')) }
  for (const r of [2, 3]) {
    put(r, x, lens('│')); put(r, x + LW - 1, lens('│'))
    for (let c = x + 1; c < x + LW - 1; c++) if (g[r] && g[r][c]) g[r][c] = { ch: g[r][c].ch, hot: true }
  }
  put(5, x + LW, lens('╲'))
  return g.map(toSegs)
}

// 波形：每個訊號一串固定的值，每個週期 4 格，往左捲動
const BITS: Record<string, number[]> = {
  reset: [1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  X: [0, 3, 3, 10, 7, 7, 1, 12, 5, 5, 9, 2, 14, 6, 6, 11],
  valid: [0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0],
}
function waveLine(sig: string, f: number, w: number): string {
  let s = ''
  if (sig === 'clk') {
    while (s.length < w + 70) s += '▔▔▁▁'
  } else if (sig === 'X') {
    const v = BITS.X
    v.forEach((x, i) => { s += (i && x !== v[i - 1] ? '╳' : '═') + x.toString(16).toUpperCase() + '══' })
    while (s.length < w + 70) s += s
  } else {
    const v = BITS[sig] ?? []
    v.forEach((b, i) => { s += (i && b !== v[i - 1] ? (b ? '╱' : '╲') : b ? '▔' : '▁') + (b ? '▔▔▔' : '▁▁▁') })
    while (s.length < w + 70) s += s
  }
  const off = f % 64
  return chars(s).slice(off, off + w).join('')
}

export function frameOf(stage: string, f: number, width: number): Frame {
  const a = ANIMS[stage] ?? ANIMS.done
  let lines: Seg[][]
  if (a.mode === 'build') lines = build(a, f)
  else if (a.mode === 'scan') lines = scan(a, f)
  else if (a.mode === 'magnify') lines = magnify(a, f)
  else if (a.mode === 'wave') {
    const w = Math.max(16, Math.min(44, width - 8))
    lines = a.art.map(sig => [{ text: (sig + '      ').slice(0, 6) + ' ' + waveLine(sig, f, w) }])
  } else lines = a.art.map(l => [{ text: l }])
  return { lines, caption: a.caption, color: a.color, dim: a.mode === 'blink' && f % 4 >= 2 }
}

export function heightOf(stage: string): number {
  return (ANIMS[stage] ?? ANIMS.done).art.length + 1
}
