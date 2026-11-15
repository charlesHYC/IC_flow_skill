export type FlowRow = {
  id?: string
  phase: string
  name: string
  status: string
  keys: string
  time: string
  runs: number
  fix: boolean
  detail?: StageDetail
}

// 點選某一列時，面板下方顯示的階段說明（flow_dashboard.py --json 的 rows[].detail）
export type StageDetail = {
  num: string
  title: string
  tool: string
  explain: string
  crit: string
  output: string
  metrics: [string, string][]
  log: string
  tail: string[]
}

export type FlowData = {
  design: string
  usePad: boolean
  top: string
  overall: string
  headline: string
  sub: string
  project: string
  generated: string
  rows: FlowRow[]
}

export type HistoryItem = {
  path: string
  name: string
  design: string
  usePad: boolean
  overall: string
  headline: string
  running: string
  last: number
  lastText: string
}

declare module 'claude-code' {
  interface PluginState {
    'ic-flow': {
      project: Shaped<string>
      data: Shaped<FlowData | null>
      error: Shaped<string>
      frame: Shaped<number>
      history: Shaped<HistoryItem[]>
      follow: Shaped<boolean>
      selected: Shaped<string>
    }
  }
}
