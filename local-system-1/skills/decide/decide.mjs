#!/usr/bin/env node
// Ask a local decision model closed-set questions instead of spending API model tokens.
// Default: Qwen3.5-4B on the host's LM Studio (Metal). DECIDE_MODEL=julia uses local-system-1,
// DECIDE_MODEL=jeff a native jeff-serve.
//
//   decide.mjs --question "Which team?" --option Billing --option Shipping [--state TEXT] [--type choice]
//   echo '[{"type":"choice","state":"...","question":"...","options":["a","b"]}]' | decide.mjs
//
// Without --state, a single question reads its state from stdin. Prints one JSON line per
// question: {answer, index, confidence, probabilities}. Exit 2: service unreachable or request
// rejected; the caller decides itself.
import { parseArgs } from 'node:util'

const URL_ = process.env.JULIA_URL ?? 'http://local-system-1:11435'

// Object states go over as Python json.dumps text (", " and ": "), the form Julia-1 was trained on.
const py = v => Array.isArray(v)
  ? `[${v.map(py).join(', ')}]`
  : v && typeof v === 'object' ? `{${Object.entries(v).map(([k, x]) => `${JSON.stringify(k)}: ${py(x)}`).join(', ')}}` : JSON.stringify(v)

// An LLM scores each option by its letter's probability as the first answer token, thinking
// off. DECIDE_LLM_URL is an OpenAI-style server ending in /v1 (LM Studio's /v1/responses), or
// Ollama (raw Qwen chat format) otherwise.
const MODEL = process.env.DECIDE_MODEL ?? 'qwen3.5-4b'
const LLM_URL = process.env.DECIDE_LLM_URL ?? 'http://host.docker.internal:1234/v1'
const LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'

async function firstToken (user) {
  const openai = LLM_URL.endsWith('/v1')
  const body = openai
    ? { model: MODEL, input: user, max_output_tokens: 1, temperature: 0, frequency_penalty: 0, top_logprobs: 20, include: ['message.output_text.logprobs'], reasoning: { effort: 'none' } }
    : { model: MODEL, prompt: `<|im_start|>user\n${user}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n`, raw: true, stream: false, logprobs: true, top_logprobs: 20, options: { temperature: 0, num_predict: 1 } }
  const res = await fetch(`${LLM_URL}${openai ? '/responses' : '/api/generate'}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(120_000) })
  if (!res.ok) throw new Error(`${LLM_URL} HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`)
  const j = await res.json()
  return openai ? j.output.find(o => o.type === 'message').content[0].logprobs[0].top_logprobs : j.logprobs[0].top_logprobs
}

async function llm (r) {
  const state = typeof r.state === 'string' ? r.state : py(r.state)
  const options = r.options.map((o, i) => `${LETTERS[i]}. ${o}`).join('\n')
  const top = await firstToken(`State: ${state}\n\nQuestion: ${r.question}\n${options}\n\nAnswer with the letter of the best option.`)
  const p = r.options.map((_, i) => top.filter(t => t.token.trim() === LETTERS[i]).reduce((s, t) => s + Math.exp(t.logprob), 0))
  const sum = p.reduce((a, b) => a + b, 0) || 1
  const probabilities = p.map(x => x / sum)
  const index = probabilities.indexOf(Math.max(...probabilities))
  return { answer: r.options[index], index, confidence: probabilities[index], probabilities }
}

// Jeff (github.com/firelex/jeff) runs natively for Metal. Every row goes over as a choice keyed
// "1".."n"; confidence is the top probability, like the other backends, not Jeff's rescaled one.
const JEFF_URL = process.env.JEFF_URL ?? 'http://host.docker.internal:8765'

async function jeff (r) {
  const criteria = Object.fromEntries(r.options.map((o, i) => [String(i + 1), o]))
  const headers = { 'Content-Type': 'application/json' }
  if (process.env.JEFF_API_KEY) headers.Authorization = `Bearer ${process.env.JEFF_API_KEY}`
  const res = await fetch(`${JEFF_URL}/v1/systemone`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ model: 'jeff-latest', state: typeof r.state === 'string' ? r.state : py(r.state), questions: { q: { type: 'choice', instructions: r.question, criteria } } }),
    signal: AbortSignal.timeout(30_000)
  })
  const body = await res.json()
  if (!res.ok) throw new Error(JSON.stringify(body.detail ?? body).slice(0, 200))
  const probabilities = r.options.map((_, i) => body.answers.q.probabilities[String(i + 1)])
  const index = probabilities.indexOf(Math.max(...probabilities))
  return { answer: r.options[index], index, confidence: probabilities[index], probabilities }
}

export async function decide (rows) {
  if (MODEL === 'jeff') {
    const out = []
    for (const r of rows) out.push(await jeff(r))
    return out
  }
  if (MODEL !== 'julia') {
    const out = []
    for (const r of rows) out.push(await llm(r))
    return out
  }
  const body_ = rows.map(r => typeof r.state === 'string' ? r : { ...r, state: py(r.state) })
  const res = await fetch(`${URL_}/predict`, { method: 'POST', body: JSON.stringify(body_), signal: AbortSignal.timeout(30_000) })
  const body = await res.json()
  if (!res.ok) throw new Error(body.error ?? `HTTP ${res.status}`)
  return body.map((r, i) => ({ answer: rows[i].options[r.index], index: r.index, confidence: Math.max(...r.probabilities), probabilities: r.probabilities }))
}

const stdin = async () => { let s = ''; for await (const c of process.stdin) s += c; return s }

if (import.meta.url === `file://${process.argv[1]}`) {
  const { values: v } = parseArgs({ options: { question: { type: 'string' }, option: { type: 'string', multiple: true }, state: { type: 'string' }, type: { type: 'string', default: 'choice' } } })
  try {
    const rows = v.question
      ? [{ type: v.type, question: v.question, options: v.option ?? [], state: v.state ?? (await stdin()).trim() }]
      : JSON.parse(await stdin())
    for (const r of await decide(rows)) console.log(JSON.stringify(r))
  } catch (e) {
    console.error(`decide: ${e.message}`)
    process.exit(2)
  }
}
