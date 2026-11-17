import { expect, test } from 'claude-code/testing'

// examples/refract_pad（REFRACT，USE_PAD=1）實際跑出的 flow_dashboard.py --json
const JSON_OUT = '{"design": "REFRACT", "usePad": true, "top": "REFRACT_chip", "overall": "PASS", "headline": "ALL_STAGES_PASS", "sub": "全部階段通過。", "project": "/proj/refract_pad", "generated": "21:45:08", "rows": [{"id": "pad", "phase": "設計決策", "name": "PAD_planning (pad_wrapper, pad_delay_model)", "status": "PASS", "keys": "pads 49, in 0.42/0.34, out 1.23/1.36 ns", "time": "0:08", "runs": 1, "fix": false, "detail": {"num": "0", "title": "PAD wrapper＋PAD 延遲 model", "tool": "pad_tools.py", "explain": "依 RTL 的 port 產生晶片 top（每個 port 接一顆 IO PAD），並從 IO library 查表算出 PAD 延遲，讓 RTL 模擬就帶 PAD 延遲。", "crit": "由 RTL port 產生 wrapper，從 IO library 查出 PAD 延遲", "output": "產出 → REFRACT_chip.v、io_pad_sim.v（帶延遲 PAD model）、pad_plan.tcl", "metrics": [["訊號 PAD", "49 (22 in / 27 out)"], ["I1025_NS", "0.418 / 0.340 ns"], ["D4I1025_NS", "1.231 / 1.365 ns"], ["I1025_EW", "0.418 / 0.340 ns"], ["D4I1025_EW", "1.231 / 1.365 ns"]], "log": "/proj/refract_pad/runs/pad/console.log", "tail": ["PAD_DELAY I1025_NS PADIO->DOUT rise/fall = 0.418/0.340 ns", "PAD_DELAY D4I1025_NS DIN->PADIO rise/fall = 1.231/1.365 ns (load 1000 fF)", "PAD_DELAY I1025_EW PADIO->DOUT rise/fall = 0.418/0.340 ns", "PAD_DELAY D4I1025_EW DIN->PADIO rise/fall = 1.231/1.365 ns (load 1000 fF)", "FIX_IO_LIB_PASS", "PAD_PASS"]}}, {"id": "rtl_sim", "phase": "前段：功能與合成", "name": "RTL_coding (vcs_simulation)", "status": "PASS", "keys": "", "time": "0:29", "runs": 1, "fix": false, "detail": {"num": "1", "title": "RTL 模擬", "tool": "VCS", "explain": "用官方 testbench 跑 RTL，確認功能正確；之後每一步都要跟這個結果一致。", "crit": "tb 印出 PASS、mismatch = 0", "output": "產出 → 功能基準（之後每一步都和它比）", "metrics": [], "log": "/proj/refract_pad/runs/rtl_sim/console.log", "tail": []}}, {"id": "synthesis", "phase": "前段：功能與合成", "name": "Synthesis (design_compiler_synthesis)", "status": "PASS", "keys": "area 23532.2, setup +0.205 ns", "time": "0:30", "runs": 1, "fix": false, "detail": {"num": "2", "title": "邏輯合成", "tool": "Design Compiler", "explain": "Design Compiler 依 SDC 時序約束，把 RTL 對應成 standard cell 組成的 gate-level netlist。", "crit": "slack ≥ 0、無 constraint 違規", "output": "產出 → REFRACT_chip_syn.v、.sdc、.svf、.sdf", "metrics": [["核心面積", "23532.2 µm²"], ["DC setup", "+0.205 ns"]], "log": "/proj/refract_pad/runs/synthesis/console.log", "tail": ["DC_SLACK setup=0.204891 cell_area=23532.209980", "DC_PASS"]}}, {"id": "formality", "phase": "前段：功能與合成", "name": "Formality (function_checking)", "status": "PASS", "keys": "", "time": "0:16", "runs": 1, "fix": false, "detail": {"num": "3", "title": "Function 驗證", "tool": "Formality", "explain": "不跑模擬，用數學方法證明合成出的 netlist 與 RTL 功能相同（逐一比對 compare point）。", "crit": "Verification SUCCEEDED", "output": "產出 → netlist ≡ RTL 的證明", "metrics": [], "log": "/proj/refract_pad/runs/formality/console.log", "tail": ["FM_PASS"]}}, {"id": "sta", "phase": "前段：功能與合成", "name": "STA_prelayout (primetime_3corner)", "status": "PASS", "keys": "setup +0.205 / hold +0.057 ns", "time": "0:17", "runs": 1, "fix": false, "detail": {"num": "4", "title": "佈局前 STA", "tool": "PrimeTime ×3 corner", "explain": "PrimeTime 在 slow／typical／fast 三個 corner 算每條路徑的 setup／hold slack，並寫出給 Gate-level sim 的 SDF。", "crit": "每個 corner setup／hold ≥ 0", "output": "產出 → REFRACT_<corner>.sdf（給 Gate-level sim）", "metrics": [["worst setup", "+0.205 ns"], ["worst hold", "+0.057 ns"]], "log": "/proj/refract_pad/runs/sta/console_slow.log", "tail": ["STA_SLACK slow setup=38.030510 hold=0.223327", "STA_PASS slow"]}}, {"id": "gate_sim", "phase": "前段：功能與合成", "name": "Gate_sim (vcs_sdf_simulation)", "status": "PASS", "keys": "SDF $removal warn 619/619", "time": "1:23", "runs": 1, "fix": false, "detail": {"num": "5", "title": "Gate-level sim＋SDF", "tool": "VCS", "explain": "netlist 加上 SDF 延遲再跑一次 testbench，確認帶真實 cell 延遲時功能仍正確。", "crit": "功能 PASS、SDF 0 error、只容許已知 warning", "output": "產出 → 含延遲的功能確認", "metrics": [["slow $removal", "619"], ["fast $removal", "619"]], "log": "/proj/refract_pad/runs/gate_sim/console.log", "tail": ["SDF_NOTE slow: removal-check warnings=619", "SDF_NOTE fast: removal-check warnings=619", "GATE_SIM_PASS"]}}, {"id": "ndm", "phase": "後段：APR", "name": "NDM (icc2_library_build)", "status": "PASS", "keys": "", "time": "0:08", "runs": 1, "fix": false, "detail": {"num": "6-0", "title": "建 NDM library", "tool": "ICC2 lm_shell", "explain": "把 standard cell（與 IO PAD）的 LEF 外框和 timing 打包成 ICC2 用的 NDM library。", "crit": "library 建立完成", "output": "產出 → stdcell_rvt.ndm（PAD 模式加 io.ndm）", "metrics": [], "log": "/proj/refract_pad/runs/ndm/console.log", "tail": ["NDM_PASS"]}}, {"id": "apr", "phase": "後段：APR", "name": "APR (floorplan_place_cts_route)", "status": "PASS", "keys": "die 1200 µm, core 520 µm", "time": "5:05", "runs": 1, "fix": false, "detail": {"num": "6", "title": "floorplan → route", "tool": "IC Compiler II", "explain": "ICC2 做 floorplan、電源網路、placement、CTS（時脈樹）與 routing，這一步只要求繞線乾淨。", "crit": "繞線 0 DRC／open／short", "output": "產出 → routed block", "metrics": [["die", "1200 µm"], ["core", "520 µm"], ["PAD", "57"], ["PAD→ring 接線", "4"]], "log": "/proj/refract_pad/runs/apr/console.log", "tail": ["PG_FIX VDD: 8 floating rails, adding stacked vias", "PG_FIX VSS: 8 floating rails, adding stacked vias", "ROUTE_FIX iter 1 DRCs=1 open=0 nets={u_core/n605}", "ROUTE_FIX iter 2 DRCs=1 open=0 nets={u_core/n605}", "ROUTE_FIX iter 3 DRCs=0 open=0 nets={}", "APR_ROUTED (constraint violations: 2; run apr_eco.tcl next)"]}}, {"id": "eco", "phase": "後段：APR", "name": "APR_ECO (maxcap_transition_fix)", "status": "PASS", "keys": "buffers +1", "time": "0:32", "runs": 1, "fix": false, "detail": {"num": "6", "title": "APR ECO", "tool": "IC Compiler II", "explain": "繞線後依報告自動在推不動的 net 插 buffer，清掉 max_cap／max_transition，並做 APR 最終判定。", "crit": "max_cap／transition 清乾淨、PG 無浮接", "output": "產出 → 乾淨的 routed block", "metrics": [["插入 buffer", "1"]], "log": "/proj/refract_pad/runs/apr/eco_console.log", "tail": ["APR_PASS"]}}, {"id": "finish", "phase": "後段：APR", "name": "Finish (filler_gds_netlist)", "status": "PASS", "keys": "", "time": "0:28", "runs": 4, "fix": false, "detail": {"num": "6", "title": "filler、GDS、netlist", "tool": "IC Compiler II", "explain": "補 filler cell、寫出 GDS 與 netlist（含／不含電源接腳兩份），交給 signoff。", "crit": "GDS 與兩份 netlist 寫出", "output": "產出 → routed_full.gds、routed.v、routed_pg.v", "metrics": [], "log": "/proj/refract_pad/runs/finish/console.log", "tail": ["FINISH_PASS"]}}, {"id": "drc_patch", "phase": "後段：APR", "name": "DRC_patch (m1_patch)", "status": "PASS", "keys": "M1 patched 49 / 49", "time": "0:15", "runs": 1, "fix": true, "detail": {"num": "7a′", "title": "M1 細條補丁", "tool": "IC Compiler II", "explain": "ICV 抓到 M1 太細的錯誤時，在 ICC2 補金屬成合法寬度，再回 finish → DRC。", "crit": "ICV 的 M1 錯誤全部補上", "output": "觸發：DRC 有 M1 細條錯誤 → 補丁 → finish → DRC", "metrics": [["補丁（最後一次）", "49 / 49"]], "log": "/proj/refract_pad/runs/apr/drc_patch_console.log", "tail": ["DRC_PATCH: 49 M1 error boxes", "DRC_PATCH: patched 49 / 49", "DRC_PATCH_PASS"]}}, {"id": "drc", "phase": "Signoff", "name": "DRC (icv_drc)", "status": "PASS", "keys": "CLEAN", "time": "6:54", "runs": 4, "fix": false, "detail": {"num": "7a", "title": "DRC", "tool": "IC Validator", "explain": "IC Validator 依製程規則逐條檢查 GDS（線寬、間距、密度…）。", "crit": "RESULTS: CLEAN", "output": "產出 → DRC 結果（PAD 模式另有 drc_classified.rpt）", "metrics": [["結果", "CLEAN"]], "log": "/proj/refract_pad/runs/drc/console.log", "tail": ["DRC_PASS"]}}, {"id": "lvs", "phase": "Signoff", "name": "LVS (icv_lvs_transistor)", "status": "PASS", "keys": "PASS", "time": "0:41", "runs": 3, "fix": false, "detail": {"num": "7b", "title": "LVS（電晶體層級）", "tool": "IC Validator", "explain": "從版圖萃取出電晶體與連線，和 CDL 電路圖逐項比對是否一致。", "crit": "Final comparison PASS", "output": "產出 → LVS 結果（PAD 模式 FAIL 時另有 lvs_classified.rpt）", "metrics": [["結果", "PASS"]], "log": "/proj/refract_pad/runs/lvs/console.log", "tail": ["LVS_PASS"]}}, {"id": "starrc", "phase": "Signoff", "name": "PEX (starrc_extraction)", "status": "PASS", "keys": "SPEF x3 corners", "time": "4:11", "runs": 3, "fix": false, "detail": {"num": "8", "title": "寄生萃取", "tool": "StarRC ×3 corner", "explain": "StarRC 從版圖萃取每條線的寄生電阻與電容，三個 RC corner 各寫一份 SPEF。", "crit": "每個 corner SPEF 產生", "output": "產出 → REFRACT_chip.spef ×3 corner", "metrics": [["SPEF corner", "3"]], "log": "/proj/refract_pad/runs/starrc/console.log", "tail": ["STARRC_PASS"]}}, {"id": "pt_post", "phase": "Signoff", "name": "STA_postroute (primetime_spef)", "status": "PASS", "keys": "setup +37.179 / hold +0.000 ns", "time": "0:20", "runs": 3, "fix": false, "detail": {"num": "9a", "title": "繞線後 STA", "tool": "PrimeTime ×3 corner", "explain": "PrimeTime 用 StarRC 的實際 RC 重算 slack 與 max_cap／transition，並寫出繞線後的 SDF。", "crit": "實際 RC 下 setup／hold ≥ 0、無違規", "output": "產出 → REFRACT_postroute_<corner>.sdf", "metrics": [["worst setup", "+37.179 ns"], ["worst hold", "+0.000 ns"]], "log": "/proj/refract_pad/runs/pt_post/console_slow.log", "tail": ["POSTROUTE_SLACK slow setup=37.178921 hold=0.244764", "POSTROUTE_STA_PASS slow"]}}, {"id": "signoff_eco", "phase": "Signoff", "name": "Signoff_ECO (sizing_buffering)", "status": "PASS", "keys": "cells changed 2", "time": "0:29", "runs": 2, "fix": true, "detail": {"num": "9a′", "title": "Signoff ECO", "tool": "IC Compiler II", "explain": "繞線後 STA 仍有違規時，自動換大顆 cell 或插 buffer，之後重跑 finish → DRC → LVS → StarRC → STA。", "crit": "修掉 StarRC＋PT 看到的違規", "output": "觸發：繞線後 STA 有違規 → ECO → finish → DRC → LVS → StarRC → STA", "metrics": [["最後一次動作", "2"]], "log": "/proj/refract_pad/runs/apr/signoff_eco_console.log", "tail": ["SIGNOFF_ECO: 2 max_cap/transition pins, 0 hold endpoints from 3 PT reports", "SIGNOFF_ECO: changed 2 cells", "SIGNOFF_ECO_PASS"]}}, {"id": "fm_post", "phase": "Signoff", "name": "Formality_post (routed_vs_rtl)", "status": "PASS", "keys": "", "time": "0:20", "runs": 1, "fix": false, "detail": {"num": "9b", "title": "繞線後 Function 驗證", "tool": "Formality", "explain": "證明繞線後的 netlist（含 CTS、ECO 加入的 buffer）仍與 RTL 功能相同。", "crit": "RTL vs routed netlist SUCCEEDED", "output": "產出 → routed netlist ≡ RTL 的證明", "metrics": [], "log": "/proj/refract_pad/runs/fm_post/console.log", "tail": ["FM_POST_PASS"]}}, {"id": "gate_post", "phase": "Signoff", "name": "Gate_post (vcs_postroute_sdf)", "status": "PASS", "keys": "SDF $removal warn 619/619", "time": "1:26", "runs": 1, "fix": false, "detail": {"num": "9c", "title": "繞線後 SDF 模擬", "tool": "VCS", "explain": "繞線後 netlist＋實際 RC 的 SDF 再跑一次 testbench，最終功能確認。", "crit": "功能 PASS、SDF 0 error", "output": "產出 → 最終功能確認", "metrics": [["slow $removal", "619"], ["fast $removal", "619"]], "log": "/proj/refract_pad/runs/gate_post/console.log", "tail": ["PAD_SIMNET wrote chip_sim.v", "SDF_NOTE slow: removal-check warnings=619", "PAD_SIMNET wrote chip_sim.v", "SDF_NOTE fast: removal-check warnings=619", "GATE_SIM_PASS"]}}]}'

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
    expect((await ui.find({ type: 'Text', text: /^PASS/ }))).toBeDefined()
    expect((await ui.find({ type: 'Text', text: /ALL_STAGES_PASS/ }))).toBeDefined()
    await ui.unmount()
  }
  // 停靠在側邊（約 45% 寬）時改用精簡排版：名稱不含括號裡的子步驟
  const narrow = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, bodyColumns: 80, placement: 'dock' } })
  expect(await narrow.find({ type: 'Text', text: /^RTL_coding +$/ })).toBeDefined()
  expect(await narrow.find({ type: 'Text', text: /vcs_simulation/ })).toBeUndefined()
  expect(await narrow.find({ type: 'Text', text: /^PASS/ })).toBeDefined()
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
    .replace('"keys": "setup +37.179 / hold +0.000 ns"', '"keys": ""')
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

test('全部通過播完成動畫', async ($, on) => {
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
  expect(await ui.find({ type: 'Text', text: /tape-out\? *┃/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /全部跑完！/ })).toBeDefined()
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
