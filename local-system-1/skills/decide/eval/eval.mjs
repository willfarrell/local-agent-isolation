#!/usr/bin/env node
// Scores every task file in this directory: accuracy, and at each confidence threshold the
// share of decisions Julia can take alone (coverage) and how accurate those are. Decisions
// under the threshold go to the API model, so coverage x API tokens per decision is the saving.
//   node eval.mjs [task.json ...]
import { readFileSync, readdirSync } from 'node:fs'
import { decide } from '../decide.mjs'

const here = new URL('.', import.meta.url)
const files = process.argv.slice(2).length ? process.argv.slice(2) : readdirSync(here).filter(f => f.endsWith('.json'))
// ponytail: chars/4 token estimate, plus a minimal system prompt and a one-word answer.
const apiTokens = t => Math.ceil((t.question.length + t.options.join(' ').length + JSON.stringify(t.state).length) / 4) + 60

for (const f of files) {
  const task = JSON.parse(readFileSync(new URL(f, here)))
  // "field" wraps each case's text as {field: text}, merged over the task's fixed "context".
  const rows = task.cases.map(c => ({ type: task.type ?? 'choice', question: task.question, options: task.options, state: task.field ? { ...task.context, [task.field]: c.state } : c.state }))
  const t0 = performance.now()
  const out = await decide(rows)
  const ms = (performance.now() - t0) / rows.length
  const ok = out.map((r, i) => r.answer === task.cases[i].expect)
  const tokens = rows.reduce((s, r) => s + apiTokens(r), 0) / rows.length
  console.log(`${f.padEnd(22)} n=${rows.length}  accuracy ${pct(ok.filter(Boolean).length, ok.length)}  ${ms.toFixed(0)}ms/decision  ~${tokens.toFixed(0)} API tokens/decision`)
  for (const t of [0.8, 0.9, 0.95]) {
    const kept = out.map((r, i) => [r.confidence >= t, ok[i]]).filter(([k]) => k)
    console.log(`   conf>=${t}: coverage ${pct(kept.length, out.length)}  accuracy ${pct(kept.filter(([, o]) => o).length, kept.length)}`)
  }
  if (process.env.MISSES) out.forEach((r, i) => ok[i] || console.log(`   miss: ${String(task.cases[i].state).slice(0, 60)} -> ${r.answer.slice(0, 30)} (${r.confidence.toFixed(2)}), want ${task.cases[i].expect.slice(0, 30)}`))
}

function pct (a, b) { return b ? `${(100 * a / b).toFixed(0)}%`.padStart(4) : '  - ' }
