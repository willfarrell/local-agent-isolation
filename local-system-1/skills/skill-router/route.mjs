#!/usr/bin/env node
// Suggest which skills a prompt needs, from catalog.json, via the decide skill's model.
//   route.mjs "prompt text"   ->  {"skills":[{"name","p"}...]}  (empty when none applies)
import { readFileSync } from 'node:fs'
import { decide } from '../decide/decide.mjs'

export const catalog = JSON.parse(readFileSync(new URL('catalog.json', import.meta.url)))

// One question over the deduplicated catalog plus a "none" option (up to 26 options).
export async function single (prompt) {
  const byLabel = {}
  for (const [n, l] of Object.entries(catalog)) (byLabel[l] ??= []).push(n)
  const labels = Object.keys(byLabel)
  const [r] = await decide([{ type: 'choice', state: prompt, question: 'Which skill should the assistant load for this request?', options: [...labels, 'None: a general question or small edit that needs no special skill'] }])
  const none = r.index === labels.length
  return labels.flatMap((l, i) => byLabel[l].map(name => ({ name, p: none ? 0 : r.probabilities[i] })))
}

export const top = (scored, k = 2, min = 0.5) => scored.filter(s => s.p >= min).sort((a, b) => b.p - a.p).slice(0, k)

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    console.log(JSON.stringify({ skills: top(await single(process.argv.slice(2).join(' ')), 2, 0.3) }))
  } catch (e) {
    console.error(`route: ${e.message}`)
    process.exit(2)
  }
}
