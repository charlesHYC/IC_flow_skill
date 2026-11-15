import { expect, test } from 'claude-code/testing'

// full_pad1（geofence，USE_PAD=1）實際跑出的 flow_dashboard.py --json
const JSON_OUT = '{"design": "geofence", "usePad": true, "top": "geofence_chip", "overall": "PAD_LIMITED", "headline": "ALL_STAGES_DONE_PAD_LIMITED", "sub": "全部跑完；DRC／LVS 只剩 IO library 的問題，這不等於 PASS。", "project": "/proj/full_pad1", "generated": "21:45:08", "rows": [{"phase": "設計決策", "name": "PAD_planning (pad_wrapper, pad_delay_model)", "status": "PASS", "keys": "pads 24, in 0.42/0.34, out 1.23/1.36 ns", "time": "", "runs": 0, "fix": false}, {"phase": "前段：功能與合成", "name": "RTL_coding (vcs_simulation)", "status": "PASS", "keys": "", "time": "", "runs": 0, "fix": false}, {"phase": "前段：功能與合成", "name": "Synthesis (design_compiler_synthesis)", "status": "PASS", "keys": "area 6013.8, setup +8.589 ns", "time": "", "runs": 0, "fix": false}, {"phase": "前段：功能與合成", "name": "Formality (function_checking)", "status": "PASS", "keys": "", "time": "", "runs": 0, "fix": false}, {"phase": "前段：功能與合成", "name": "STA_prelayout (primetime_3corner)", "status": "PASS", "keys": "setup +8.589 / hold +0.038 ns", "time": "", "runs": 0, "fix": false}, {"phase": "前段：功能與合成", "name": "Gate_sim (vcs_sdf_simulation)", "status": "PASS", "keys": "SDF $removal warn 17/17", "time": "", "runs": 0, "fix": false}, {"phase": "後段：APR", "name": "NDM (icc2_library_build)", "status": "PASS", "keys": "", "time": "", "runs": 0, "fix": false}, {"phase": "後段：APR", "name": "APR (floorplan_place_cts_route)", "status": "PASS", "keys": "die 920 µm, core 240 µm", "time": "", "runs": 0, "fix": false}, {"phase": "後段：APR", "name": "APR_ECO (maxcap_transition_fix)", "status": "PASS", "keys": "buffers +6", "time": "", "runs": 0, "fix": false}, {"phase": "後段：APR", "name": "Finish (filler_gds_netlist)", "status": "PASS", "keys": "", "time": "0:18", "runs": 1, "fix": false}, {"phase": "後段：APR", "name": "DRC_patch (m1_patch)", "status": "PASS", "keys": "M1 patched 4 / 4", "time": "", "runs": 0, "fix": true}, {"phase": "Signoff", "name": "DRC (icv_drc)", "status": "PAD_LIMITED", "keys": "core 0, io_ring 2120, stitch 4", "time": "3:40", "runs": 1, "fix": false}, {"phase": "Signoff", "name": "LVS (icv_lvs_transistor)", "status": "PAD_LIMITED", "keys": "MOS 25,640, RES 8 matched", "time": "0:24", "runs": 2, "fix": false}, {"phase": "Signoff", "name": "PEX (starrc_extraction)", "status": "PASS", "keys": "SPEF x3 corners", "time": "3:45", "runs": 2, "fix": false}, {"phase": "Signoff", "name": "STA_postroute (primetime_spef)", "status": "PASS", "keys": "setup +22.877 / hold +0.016 ns", "time": "0:18", "runs": 2, "fix": false}, {"phase": "Signoff", "name": "Signoff_ECO (sizing_buffering)", "status": "PASS", "keys": "cells changed 12", "time": "0:20", "runs": 1, "fix": true}, {"phase": "Signoff", "name": "Formality_post (routed_vs_rtl)", "status": "PASS", "keys": "", "time": "2:31", "runs": 1, "fix": false}, {"phase": "Signoff", "name": "Gate_post (vcs_postroute_sdf)", "status": "PASS", "keys": "SDF $removal warn 17/17", "time": "0:07", "runs": 1, "fix": false}]}'

const PANE = {
  plugin: 'ic-flow',
  component: 'Pane',
  requestId: 'ic-flow',
  props: { title: 'IC design flow', isFocused: true, bodyColumns: 120, placement: 'inline', scroll: { offset: 0, bodyRows: 40 }, view: {} },
} as const

test('/ic_flow 讀專案狀態並畫出流程表', async ($, on) => {
  let opened: unknown = null
  on('command.register', () => ({ value: { command: 'ic_flow' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/proj' }))
  on('process.run', (_, e) => ({
    value: (e as { argv: string[] }).argv[0] === 'test'
      ? { exitCode: 0, stdout: '', stderr: '' }
      : { exitCode: 0, stdout: JSON_OUT, stderr: '' },
  }))
  on('ui.open', (_, e) => { opened = e; return { value: { isPlaced: true } } })

  await $.session.start({ cwd: '/proj', surface: 'terminal', isInteractive: true })
  const ran = await $.command.run({ command: 'ic_flow', args: '/proj' })
  expect(ran.text).toContain('/proj')
  expect(opened).toMatchObject({ id: 'ic-flow', focus: true, closeOnEscape: true })

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.find({ type: 'Text', text: /RTL_coding \(vcs_simulation\)/ }))).toBeDefined()
    expect((await ui.find({ type: 'Text', text: /Synthesis \(design_compiler_synthesis\)/ }))).toBeDefined()
    expect((await ui.find({ type: 'Text', text: /^PAD_LIMITED/ }))).toBeDefined()
    expect((await ui.find({ type: 'Text', text: /ALL_STAGES_DONE_PAD_LIMITED/ }))).toBeDefined()
    await ui.unmount()
  }
  // 停靠在側邊（約 45% 寬）時改用精簡排版：名稱不含括號裡的子步驟
  const narrow = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, bodyColumns: 80, placement: 'dock' } })
  expect(await narrow.find({ type: 'Text', text: /^RTL_coding +$/ })).toBeDefined()
  expect(await narrow.find({ type: 'Text', text: /vcs_simulation/ })).toBeUndefined()
  expect(await narrow.find({ type: 'Text', text: /^PAD_LIMITED/ })).toBeDefined()
  await narrow.unmount()
})

test('找不到專案時回報，不開面板', async ($, on) => {
  let opened = false
  on('command.register', () => ({ value: { command: 'ic_flow' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/nowhere' }))
  on('process.run', () => ({ value: { exitCode: 1, stdout: '', stderr: '' } }))
  on('ui.open', () => { opened = true; return { value: { isPlaced: true } } })
  await $.session.start({ cwd: '/nowhere', surface: 'terminal', isInteractive: true })
  const ran = await $.command.run({ command: 'ic_flow', args: '' })
  expect(ran.text).toContain('找不到')
  expect(opened).toBe(false)
})

test('/ic_flow text 把整張表印在對話區，不開面板', async ($, on) => {
  let opened = false
  let argv: string[] = []
  on('command.register', () => ({ value: { command: 'ic_flow' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/proj' }))
  on('process.run', (_, e) => {
    argv = (e as { argv: string[] }).argv
    return { value: argv[0] === 'test'
      ? { exitCode: 0, stdout: '', stderr: '' }
      : { exitCode: 0, stdout: '\n  geofence design flow\n│ RTL_coding (vcs_simulation) │ PASS │\n', stderr: '' } }
  })
  on('ui.open', () => { opened = true; return { value: { isPlaced: true } } })
  await $.session.start({ cwd: '/proj', surface: 'terminal', isInteractive: true })
  const ran = await $.command.run({ command: 'ic_flow', args: 'text /proj' })
  expect(ran.text).toContain('RTL_coding (vcs_simulation)')
  expect(argv).toContain('--text')
  expect(opened).toBe(false)
})


test('正在跑的階段：▶ 標記、粗體、狀態反白', async ($, on) => {
  const running = JSON_OUT.replace(
    '"name": "STA_postroute (primetime_spef)", "status": "PASS"',
    '"name": "STA_postroute (primetime_spef)", "status": "RUNNING"')
    .replace('"keys": "setup +22.877 / hold +0.016 ns"', '"keys": ""')
  expect(running).not.toBe(JSON_OUT)
  on('command.register', () => ({ value: { command: 'ic_flow' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/proj' }))
  on('process.run', (_, e) => ({
    value: (e as { argv: string[] }).argv[0] === 'test'
      ? { exitCode: 0, stdout: '', stderr: '' }
      : { exitCode: 0, stdout: running, stderr: '' },
  }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  await $.session.start({ cwd: '/proj', surface: 'terminal', isInteractive: true })
  await $.command.run({ command: 'ic_flow', args: '/proj' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const name = await ui.find({ type: 'Text', text: /^▶ STA_postroute/ })
  expect(name).toBeDefined()
  expect(name?.props.weight).toBe('bold')
  const st = await ui.find({ type: 'Text', text: /^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] RUNNING/ })
  expect(st?.props.backgroundColor).toBe('suggestion')
  // 關鍵數字還沒出來時，那一欄是來回跑的進度條
  expect(await ui.find({ type: 'Text', text: /▱*▰▰▰▰▱*/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^▶ RTL_coding/ })).toBeUndefined()
  await ui.unmount()
})

test('下方有空間時播正在跑階段的動畫，空間不夠就不播', async ($, on) => {
  const running = JSON_OUT.replace(
    '"name": "Synthesis (design_compiler_synthesis)", "status": "PASS"',
    '"name": "Synthesis (design_compiler_synthesis)", "status": "RUNNING"')
  expect(running).not.toBe(JSON_OUT)
  on('command.register', () => ({ value: { command: 'ic_flow' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/proj' }))
  on('process.run', (_, e) => ({
    value: (e as { argv: string[] }).argv[0] === 'test'
      ? { exitCode: 0, stdout: '', stderr: '' }
      : { exitCode: 0, stdout: running, stderr: '' },
  }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  await $.session.start({ cwd: '/proj', surface: 'terminal', isInteractive: true })
  await $.command.run({ command: 'ic_flow', args: '/proj' })

  const tall = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, scroll: { offset: 0, bodyRows: 60 } } })
  expect(await tall.find({ type: 'Text', text: /組成 DFF 與邏輯閘/ })).toBeDefined()
  await tall.unmount()

  const short = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, scroll: { offset: 0, bodyRows: 30 } } })
  expect(await short.find({ type: 'Text', text: /組成 DFF 與邏輯閘/ })).toBeUndefined()
  expect(await short.find({ type: 'Text', text: /^▶ Synthesis/ })).toBeDefined()
  await short.unmount()
})

test('全部跑完（PAD_LIMITED）播完成動畫', async ($, on) => {
  on('command.register', () => ({ value: { command: 'ic_flow' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/proj' }))
  on('process.run', (_, e) => ({
    value: (e as { argv: string[] }).argv[0] === 'test'
      ? { exitCode: 0, stdout: '', stderr: '' }
      : { exitCode: 0, stdout: JSON_OUT, stderr: '' },
  }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  await $.session.start({ cwd: '/proj', surface: 'terminal', isInteractive: true })
  await $.command.run({ command: 'ic_flow', args: '/proj' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, scroll: { offset: 0, bodyRows: 60 } } })
  expect(await ui.find({ type: 'Text', text: /PAD_LIMITED *┃/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /不是 PASS/ })).toBeDefined()
  await ui.unmount()
})

test('不給路徑：跟隨最近的專案；歷史按 2 切換並鎖定', async ($, on) => {
  const HIST = JSON.stringify([
    { path: '/runs/demo', name: 'demo_pad1', design: 'geofence', usePad: true, overall: 'RUNNING', headline: 'RUNNING', running: 'APR', last: 2, lastText: '11-12 22:40' },
    { path: '/runs/old', name: 'full_pad0', design: 'geofence', usePad: false, overall: 'PASS', headline: 'ALL_STAGES_PASS', running: '', last: 1, lastText: '11-12 21:21' },
  ])
  const asked: string[] = []
  on('command.register', () => ({ value: { command: 'ic_flow' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/home' }))
  on('process.run', (_, e) => {
    const argv = (e as { argv: string[] }).argv
    if (argv[0] === 'test') return { value: { exitCode: 0, stdout: '', stderr: '' } }
    if (argv.includes('--history')) return { value: { exitCode: 0, stdout: HIST, stderr: '' } }
    asked.push(argv[5])   // sh -c RUN_DASH ic_flow <plugin root> <scriptdir> <proj> --json
    return { value: { exitCode: 0, stdout: JSON_OUT.replace(/"project": "[^"]*"/, `"project": "${argv[5]}"`), stderr: '' } }
  })
  on('ui.open', () => ({ value: { isPlaced: true } }))

  await $.session.start({ cwd: '/home', surface: 'terminal', isInteractive: true })
  const ran = await $.command.run({ command: 'ic_flow', args: '' })
  expect(ran.text).toContain('/runs/demo')
  expect(ran.text).toContain('自動跟隨')

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, scroll: { offset: 0, bodyRows: 60 } } })
  expect(await ui.find({ type: 'Text', text: /● demo_pad1/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /full_pad0/ })).toBeDefined()
  await ui.press({ key: 'h1' })
  expect(asked[asked.length - 1]).toBe('/runs/old')
  expect(await ui.find({ type: 'Text', text: /● full_pad0/ })).toBeDefined()
  await ui.unmount()
})

test('面板上的「Esc 關閉」按鈕會關掉面板', async ($, on) => {
  let closed = ''
  on('command.register', () => ({ value: { command: 'ic_flow' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/proj' }))
  on('process.run', (_, e) => ({
    value: (e as { argv: string[] }).argv[0] === 'test'
      ? { exitCode: 0, stdout: '', stderr: '' }
      : { exitCode: 0, stdout: JSON_OUT, stderr: '' },
  }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.close', (_, e) => { closed = (e as { id: string }).id; return { value: undefined } })
  await $.session.start({ cwd: '/proj', surface: 'terminal', isInteractive: true })
  await $.command.run({ command: 'ic_flow', args: '/proj' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'esc' })
  expect(closed).toBe('ic-flow')
  await ui.unmount()
})

test('點一個階段：下方顯示說明與結果行，播那一階段的動畫；再點一次取消', async ($, on) => {
  const d = JSON.parse(JSON_OUT)
  d.rows[2].id = 'synthesis'
  d.rows[2].detail = {
    num: '2', title: '邏輯合成', tool: 'Design Compiler', explain: '把 RTL 對應成 standard cell。',
    crit: 'slack ≥ 0、無 constraint 違規', output: '產出 → geofence_chip_syn.v',
    metrics: [['核心面積', '6013.8 µm²']], log: '/proj/runs/synthesis/console.log',
    tail: ['DC_SLACK setup=8.58896 cell_area=6013.809568', 'DC_PASS'],
  }
  const out = JSON.stringify(d)
  on('command.register', () => ({ value: { command: 'ic_flow' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/proj' }))
  on('process.run', (_, e) => ({
    value: (e as { argv: string[] }).argv[0] === 'test'
      ? { exitCode: 0, stdout: '', stderr: '' }
      : { exitCode: 0, stdout: out, stderr: '' },
  }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  await $.session.start({ cwd: '/proj', surface: 'terminal', isInteractive: true })
  await $.command.run({ command: 'ic_flow', args: '/proj' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, scroll: { offset: 0, bodyRows: 80 } } })
  expect(await ui.find({ type: 'Text', text: /把 RTL 對應成/ })).toBeUndefined()
  await ui.press({ key: 's-synthesis' })
  expect(await ui.find({ type: 'Text', text: /▸ 邏輯合成 · Design Compiler/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /把 RTL 對應成 standard cell/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /DC_SLACK setup=8\.58896/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /把 RTL 組成 DFF 與邏輯閘/ })).toBeDefined()   // 合成的動畫說明
  await ui.press({ key: 's-synthesis' })
  expect(await ui.find({ type: 'Text', text: /把 RTL 對應成/ })).toBeUndefined()
  await ui.unmount()
})
