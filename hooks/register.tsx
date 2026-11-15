import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { FlowData, FlowRow, HistoryItem } from '../types'
import { frameOf, heightOf } from './anim'

// /ic_flow                   右側面板，自動顯示最近有動的專案（正在跑的優先），跟著切換
// /ic_flow <專案路徑>        鎖定某個專案；面板下方的歷史可按 1-5 切換
// /ic_flow close             關閉面板
// /ic_flow text [專案路徑]   純文字快照印在對話區
// 資料來自專案的 runs/（flow_dashboard.py --json），表格判定與 run_stage.sh 一致。
const PANE = 'ic-flow'
const project = atom({ plugin: 'ic-flow', key: 'project' } as const, '', { shape: 'project-1' })
const data = atom({ plugin: 'ic-flow', key: 'data' } as const, null, { shape: 'data-1' })
const error = atom({ plugin: 'ic-flow', key: 'error' } as const, '', { shape: 'error-1' })
// 動畫的格數（面板開著時每 0.4 秒加一）
const frame = atom({ plugin: 'ic-flow', key: 'frame' } as const, 0, { shape: 'frame-1' })
// 跑過的專案（flow_dashboard.py --history，登記在 ~/.claude/ic-flow/projects.txt）
const history = atom({ plugin: 'ic-flow', key: 'history' } as const, [], { shape: 'history-1' })
// true = 自動跟著最近有動的專案；false = 使用者指定了某個專案
const follow = atom({ plugin: 'ic-flow', key: 'follow' } as const, true, { shape: 'follow-1' })
// 點選的階段 id（'' = 沒選）：播它的動畫、下方顯示它的詳細資訊；再點一次取消
const selected = atom({ plugin: 'ic-flow', key: 'selected' } as const, '', { shape: 'selected-1' })

// 舊版 JSON 沒有 id：用表格名稱的第一個字對回階段
const NAME2ID: Record<string, string> = {
  PAD_planning: 'pad', RTL_coding: 'rtl_sim', Synthesis: 'synthesis', Formality: 'formality',
  STA_prelayout: 'sta', Gate_sim: 'gate_sim', NDM: 'ndm', APR: 'apr', APR_ECO: 'eco', Finish: 'finish',
  DRC_patch: 'drc_patch', DRC: 'drc', LVS: 'lvs', PEX: 'starrc', STA_postroute: 'pt_post',
  Signoff_ECO: 'signoff_eco', Formality_post: 'fm_post', Gate_post: 'gate_post',
}
// 要播哪一段：正在跑的階段 > 全部完成／PAD_LIMITED／失敗；還沒跑完又沒在跑就不播
function animStage(d: FlowData): string | null {
  const run = d.rows.find(r => r.status === 'RUNNING')
  if (run) return run.id ?? NAME2ID[run.name.split(' ')[0]] ?? null
  if (d.overall === 'PASS') return 'done'
  if (d.overall === 'PAD_LIMITED') return 'limited'
  if (d.overall === 'FAIL') return 'fail'
  return null
}

// 終端機顯示寬度：中日韓全形字佔兩格
const wide = /[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]/
const width = (s: string) => [...s].reduce((n, c) => n + (wide.test(c) ? 2 : 1), 0)
const fit = (s: string, n: number) => {
  let out = ''
  for (const c of s) {
    if (width(out + c) > n - (width(s) > n ? 1 : 0)) return out + '…' + ' '.repeat(Math.max(0, n - width(out) - 1))
    out += c
  }
  return out + ' '.repeat(Math.max(0, n - width(out)))
}

// 正在跑那一列的小動畫：狀態欄前的轉圈、關鍵數字欄來回跑的進度條
const SPIN = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
function busyBar(f: number, w: number): string {
  const n = Math.max(6, Math.min(24, w - 2)), len = 4
  const span = n - len, p = f % (span * 2), x = p <= span ? p : span * 2 - p
  return '▱'.repeat(x) + '▰'.repeat(len) + '▱'.repeat(span - x)
}

const STATUS_COLOR: Record<string, string> = {
  PASS: 'success', FAIL: 'error', PAD_LIMITED: 'warning', RUNNING: 'suggestion',
}
const STATUS_TEXT: Record<string, string> = {
  PASS: 'PASS', FAIL: 'FAIL', PAD_LIMITED: 'PAD_LIMITED', RUNNING: 'RUNNING',
  SKIP: 'skip', NOTRUN: '-', NOTNEEDED: 'not needed',
}

// 找 flow_dashboard.py：同一個 plugin 附的 skill > ~/.claude/skills 裡的 skill > 專案自己複製的版本
// （舊專案複製的版本可能沒有 --json）。參數：$1 = plugin 根目錄，$2 = 專案目錄，其餘傳給腳本
const RUN_DASH =
  'T=skills/digital-ic-flow/templates/00_common/flow_dashboard.py; S="$1/$T"; shift; ' +
  '[ -f "$S" ] || S="$HOME/.claude/$T"; [ -f "$S" ] || S="$1/scripts/flow_dashboard.py"; shift; exec python3 "$S" "$@"'
const dash = ($: EngineInterface, dir: string, ...args: string[]) =>
  ['sh', '-c', RUN_DASH, 'ic_flow', $.plugin.root, dir, ...args]

// 讀專案歷史；跟隨模式下順便切到最近有動的專案
async function refreshHistory($: EngineInterface): Promise<void> {
  try {
    const ran = await $.process.run(dash($, '/nonexistent', '--history'), { timeoutMs: 30000 })
    const line = ran.stdout.split('\n').find(l => l.startsWith('['))
    if (!line) return
    const list = JSON.parse(line) as HistoryItem[]
    await update($, history, () => list)
    if ((await read($, follow)) && list.length > 0 && list[0].path !== (await read($, project))) {
      await update($, project, () => list[0].path)
    }
  } catch {
    // 歷史讀不到不影響主表
  }
}

const rowId = (r: FlowRow) => r.id ?? NAME2ID[r.name.split(' ')[0]] ?? r.name

// 切到歷史裡的某個專案（按鈕或數字鍵）
async function pick($: EngineInterface, path: string): Promise<void> {
  await update($, follow, () => false)
  await update($, selected, () => '')
  await update($, project, () => path)
  await refresh($)
}

// 讀一次流程狀態；成功寫 data，失敗寫 error
async function refresh($: EngineInterface): Promise<void> {
  const dir = await read($, project)
  if (!dir) return
  try {
    const ran = await $.process.run(dash($, dir, dir, '--json'), { timeoutMs: 20000 })
    if (ran.exitCode !== 0) {
      await update($, error, () => (ran.stderr || ran.stdout).trim().split('\n').slice(-3).join('\n'))
      return
    }
    const line = ran.stdout.split('\n').find(l => l.startsWith('{'))
    if (!line) {
      await update($, error, () => 'flow_dashboard.py 沒有輸出 JSON：' + ran.stdout.trim().split('\n').slice(-1)[0])
      return
    }
    const parsed = JSON.parse(line) as FlowData
    await update($, data, () => parsed)
    await update($, error, () => '')
  } catch (err) {
    await update($, error, () => String(err))
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'ic_flow',
      description: 'IC design flow 面板（Esc 關閉）：/ic_flow [專案路徑]；/ic_flow text 印純文字表',
    })
    // 面板開著才動：每 0.4 秒推一格動畫，每 5 秒重讀一次流程狀態
    let tick = 0
    $.clock.every(400, () => {
      void (async () => {
        const isUp = (await $.ui.panes()).some(pane => pane.id === PANE)
        if (!isUp) return
        tick += 1
        await update($, frame, n => (n + 1) % 100000)
        if (tick % 12 === 0) {
          await refreshHistory($)
          await refresh($)
        }
      })()
    })
    return next(e)
  })

  on('command.run', { command: 'ic_flow' }, async ($, e) => {
    // 參數：[text|close] [專案路徑]；專案：命令列給的路徑 > 上次用的 > 目前工作目錄
    const words = e.args.trim().split(/\s+/).filter(Boolean)
    const mode = ['pane', 'text', 'close', 'live'].includes(words[0] ?? '') ? (words.shift() as string) : 'pane'
    if (mode === 'close') {
      if ((await $.ui.panes()).some(pane => pane.id === PANE)) await $.ui.close({ id: PANE })
      return { text: 'IC design flow 面板已關閉。' }
    }
    let dir = (words[0] ?? '').replace(/\/+$/, '')
    if (!dir) {
      // 沒給路徑：跟隨最近有動的專案；歷史是空的才看目前目錄
      await update($, follow, () => true)
      await refreshHistory($)
      dir = (await read($, history))[0]?.path ?? (await $.session.cwd())
    } else {
      await update($, follow, () => false)
    }
    if (!dir.startsWith('/')) dir = `${await $.session.cwd()}/${dir}`
    const has = await $.process.run(['test', '-f', `${dir}/scripts/flow_config.tcl`])
    if (has.exitCode !== 0) {
      return {
        text: `找不到 ${dir}/scripts/flow_config.tcl。第一次請用 /ic_flow <專案路徑>（專案要有 scripts/ 與 runs/）；之後跑過的專案會自動記住。`,
      }
    }
    await update($, project, () => dir)
    if (mode === 'text') {
      const ran = await $.process.run(dash($, dir, dir, '--text'),
        { timeoutMs: 20000, env: { NO_COLOR: '1' } })
      return { text: (ran.stdout || ran.stderr).replace(/^\n+/, '').trimEnd() }
    }
    await refresh($)
    await refreshHistory($)
    if (!(await read($, follow))) await update($, project, () => dir)   // refreshHistory 不會改掉指定的專案
    const rows = ((await read($, data))?.rows.length ?? 18) + 20
    // 要求最寬（Claude Code 上限是畫面的 45%）；面板窄時表格自動改精簡排版
    await $.ui.open({ id: PANE, title: 'IC design flow', focus: true, closeOnEscape: true, rows, columns: 400 })
    const mode2 = (await read($, follow)) ? '自動跟隨最近的專案' : '已鎖定此專案（/ic_flow 不加路徑回到自動）'
    return { text: `IC design flow：${await read($, project)}（${mode2}；每 5 秒更新，Esc 關閉）` }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const d = await read($, data)
    const err = await read($, error)
    if (!d) return <Text color="error">{err || '還沒有資料：用 /ic_flow <專案路徑> 開啟。'}</Text>
    // 窄的時候（右側面板常見）去掉括號裡的子步驟、拿掉耗時欄
    const cols = Math.max(40, e.props.bodyColumns ?? e.viewport?.columns ?? 120)
    const narrow = cols < 100
    const W = { name: narrow ? 18 : 44, status: 12, time: narrow ? 0 : 9 }
    const keysW = Math.max(10, Math.min(44, cols - W.name - W.status - W.time - 4))
    const total = W.name + W.status + keysW + W.time + 3
    const rule = '─'.repeat(total)
    let last = ''
    const lines: unknown[] = []
    const sel = await read($, selected)
    const f = await read($, frame)
    const selRow = d.rows.find(r => rowId(r) === sel)
    for (const r of d.rows) {
      if (r.phase !== last) {
        last = r.phase
        lines.push(<Text weight="bold">{fit(`── ${r.phase} `, total).replace(/ +$/, m => '─'.repeat(width(m)))}</Text>)
      }
      // 正在跑的那一列：▶ 標記、粗體、狀態欄反白
      const running = r.status === 'RUNNING'
      const name = (running ? '▶ ' : '') + (narrow ? r.name.replace(/ \(.*\)$/, '') : r.name) + (r.fix ? ' *' : '')
      const time = r.time + (r.runs > 1 ? ` x${r.runs}` : '')
      const quiet = ['NOTRUN', 'SKIP', 'NOTNEEDED'].includes(r.status)
      const bold = running || r.status === 'FAIL'
      const id = rowId(r)
      const isSel = id === sel
      lines.push(
        <Button key={`s-${id}`} plain label={r.name} onPress={() => update($, selected, cur => (cur === id ? '' : id))}>
          <Text
            dimColor={quiet && !isSel}
            weight={running || isSel ? 'bold' : 'regular'}
            color={isSel ? 'claude' : running ? 'suggestion' : undefined}
          >
            {fit((isSel ? '▸ ' : '') + name, W.name)}{' '}
          </Text>
          <Text
            color={running ? 'inverseText' : STATUS_COLOR[r.status]}
            backgroundColor={running ? 'suggestion' : undefined}
            dimColor={quiet}
            weight={bold ? 'bold' : 'regular'}
          >
            {fit((running ? SPIN[f % SPIN.length] + ' ' : '') + (STATUS_TEXT[r.status] ?? r.status), W.status)}
          </Text>
          {running && !r.keys
            ? <Text color="suggestion"> {fit(busyBar(f, keysW), keysW)} </Text>
            : <Text dimColor={quiet} weight={running ? 'bold' : 'regular'}> {fit(r.keys, keysW)} </Text>}
          {W.time ? <Text dimColor>{fit(time, W.time)}</Text> : null}
        </Button>,
      )
    }
    // 歷史：最近 5 個專案，按數字鍵或點擊切換
    const hist = (await read($, history)).slice(0, 5)
    const histView = hist.length === 0 ? null : (
      <Box flexDirection="column" marginTop={1}>
        <Text weight="bold">History</Text>
        {hist.map((item, i) => {
          const isCur = item.path === d.project
          const st = item.overall === 'RUNNING' ? `RUNNING ${item.running}` : item.headline.replace('ALL_STAGES_', '')
          return (
            <Button
              key={`h${i}`}
              hotkey={String(i + 1)}
              plain
              label={`${item.name} ${item.usePad ? 'PAD' : 'core'}`}
              onPress={() => pick($, item.path)}
            >
              <Text weight={isCur ? 'bold' : 'regular'} color={isCur ? 'suggestion' : undefined}>
                {isCur ? '●' : ' '} {fit(item.name, 16)} {fit(item.usePad ? 'PAD' : 'core', 5)}
              </Text>
              <Text color={STATUS_COLOR[item.overall]}>{fit(st, 24)}</Text>
              <Text dimColor> {item.lastText}</Text>
            </Button>
          )
        })}
      </Box>
    )
    // 點選的階段：說明、通過標準、產出、關鍵數字、log 結果行
    let detailView: unknown = null
    let detailRows = 0
    if (selRow) {
      const dt = selRow.detail
      const body: unknown[] = []
      // 左欄固定寬的粗體英文標籤，右欄內容；內容折行時仍對齊右欄
      const LW = 10
      const field = (label: string, ...vals: { text: string; color?: string; bold?: boolean }[]) => {
        body.push(
          <Box flexDirection="row">
            <Box width={LW} flexShrink={0}><Text weight="bold">{label}</Text></Box>
            <Box flexDirection="column" flexShrink={1}>
              {vals.map(v => <Text color={v.color} weight={v.bold ? 'bold' : 'regular'}>{v.text}</Text>)}
            </Box>
          </Box>,
        )
      }
      const st = STATUS_TEXT[selRow.status] ?? selRow.status
      const title = dt ? `${dt.title} · ${dt.tool}` : selRow.name
      body.push(<Text weight="bold">{fit(`── ▸ ${title} `, total).replace(/ +$/, m => '─'.repeat(width(m)))}</Text>)
      const extra = [selRow.time ? `time ${selRow.time}` : '', selRow.runs > 1 ? `runs ${selRow.runs}` : ''].filter(Boolean)
      field('Status', { text: st + (extra.length ? `   (${extra.join(', ')})` : ''), color: STATUS_COLOR[selRow.status], bold: true })
      if (dt) {
        if (dt.explain) field('What', { text: dt.explain })
        field('Pass', { text: dt.crit })
        const trig = dt.output.startsWith('觸發')
        field(trig ? 'Trigger' : 'Output', { text: dt.output.replace(/^(產出 → |觸發：)/, ''), color: trig ? 'warning' : undefined })
        if (dt.metrics.length) field('Numbers', ...dt.metrics.map(([k, v]) => ({ text: `${k}  ${v}` })))
        if (dt.tail.length) {
          field('Results', ...dt.tail.map(t => ({
            text: t, color: /FAIL|Error|ERROR/.test(t) ? 'error' : /PASS/.test(t) ? 'success' : undefined,
          })))
        }
        if (dt.log) field('Log', { text: dt.log, color: 'subtle' })
      } else {
        body.push(<Text dimColor>（這個專案的 flow_dashboard.py 太舊，沒有階段詳細資訊）</Text>)
      }
      body.push(<Text dimColor>再點一次同一列取消選取</Text>)
      // 長的說明文字會折行：粗估每行字寬
      detailRows = body.length + 1 + (dt ? dt.metrics.length + dt.tail.length : 0) +
        Math.floor(width((dt?.explain ?? '') + (dt?.output ?? '') + (dt?.log ?? '')) / Math.max(20, total - 12))
      detailView = <Box flexDirection="column" marginTop={1}>{body}</Box>
    }
    // 下方空間夠才畫動畫（表格約 rows + 分區線 + 8 行，加上歷史與詳細資訊）
    let anim: unknown = null
    const stage = selRow ? rowId(selRow) : animStage(d)
    const room = (e.props.scroll?.bodyRows ?? 0) -
      (lines.length + 8 + (err ? 1 : 0) + (hist.length ? hist.length + 2 : 0) + detailRows)
    // 點選了階段就一定播（面板可捲動）；沒點選時空間夠才播
    if (stage && (selRow || room >= heightOf(stage) + 2)) {
      const fr = frameOf(stage, f, cols)
      anim = (
        <Box flexDirection="column" marginTop={1}>
          {fr.lines.map(segs => (
            <Box flexDirection="row">
              {segs.map(s => (
                <Text
                  color={s.hot ? 'inverseText' : s.lens ? 'claude' : fr.color ?? 'suggestion'}
                  backgroundColor={s.hot ? 'suggestion' : undefined}
                  dimColor={fr.dim}
                  weight={s.lens || (fr.color && !fr.dim) ? 'bold' : 'regular'}
                >
                  {s.text}
                </Text>
              ))}
            </Box>
          ))}
          <Text dimColor>{fr.caption}</Text>
        </Box>
      )
    }
    return (
      <Box flexDirection="column">
        <Text weight="bold">
          {d.design} — {d.usePad ? 'USE_PAD 1 (IO PAD)' : 'USE_PAD 0 (core)'}  top={d.top}
        </Text>
        <Text weight="bold">{rule}</Text>
        <Text dimColor>
          {fit(narrow ? 'Stage' : 'Stage (steps)', W.name)} {fit('Status', W.status)} {fit('Key numbers', keysW)} {W.time ? fit('Time', W.time) : ''}
        </Text>
        {lines}
        <Text weight="bold">{rule}</Text>
        <Text>
          <Text color={STATUS_COLOR[d.overall] ?? 'text'} weight="bold">{d.headline}</Text>  {d.sub}
        </Text>
        {err ? <Text color="error">更新失敗：{err}</Text> : null}
        <Text dimColor>Updates every 5 s ({d.generated})</Text>
        {anim}
        {detailView}
        {histView}
        {/* 最下面：按 Esc、q 或點這顆都會關閉面板 */}
        <Box flexDirection="row" marginTop={1}>
          <Button key="esc" hotkey="q" label="Esc 關閉" onPress={() => $.ui.close({ id: PANE })} />
          <Text dimColor>  （或按 Esc／q）</Text>
        </Box>
      </Box>
    )
  })
}
