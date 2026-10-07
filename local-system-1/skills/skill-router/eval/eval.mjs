#!/usr/bin/env node
// Scores routing on cases.json (CASES=heldout.json for the untuned set): hit@2 on prompts that need a skill, false
// positives on prompts that need none, and latency. Bar (from the dropped System 1): beat
// word overlap by 10 points of hit@2 with false positives at or under 25%.
import { readFileSync } from 'node:fs'
import { catalog, single, top } from '../route.mjs'

const cases = JSON.parse(readFileSync(new URL(process.env.CASES ?? 'cases.json', import.meta.url)))
const STOP = new Set('the and for with this that from into what how can you your are our about any all its'.split(' '))
const words = s => new Set(s.toLowerCase().match(/[a-z0-9]{3,}/g)?.filter(w => !STOP.has(w)) ?? [])

async function overlap (prompt) {
  const p = words(prompt)
  return Object.keys(catalog).map(n => {
    const w = words(`${n.replaceAll('-', ' ')} ${catalog[n]}`)
    return { name: n, p: [...p].filter(x => w.has(x)).length / 2 }
  })
}

async function score (label, strategy, thresholds) {
  const scored = []
  const ms = []
  for (const c of cases) {
    const t = performance.now()
    scored.push(await strategy(c.prompt))
    ms.push(performance.now() - t)
  }
  ms.sort((a, b) => a - b)
  for (const min of thresholds) {
    let hit = 0, need = 0, fp = 0, none = 0
    const misses = []
    cases.forEach((c, i) => {
      const got = top(scored[i], 2, min).map(s => s.name)
      if (c.skills.length) {
        need++
        if (got.some(g => c.skills.includes(g))) hit++
        else misses.push(c.prompt.slice(0, 40))
      } else {
        none++
        if (got.length) fp++
      }
    })
    console.log(`${label.padEnd(8)} min=${String(min).padEnd(4)} hit@2 ${(100 * hit / need).toFixed(0).padStart(3)}%  false-pos ${(100 * fp / none).toFixed(0).padStart(3)}%  p50 ${ms[ms.length >> 1].toFixed(0)}ms`)
    if (process.env.MISSES) console.log('   missed:', misses.join(' | '))
  }
}

await score('overlap', overlap, [0.5, 1])
await score('single', single, [0.01, 0.3, 0.5])
