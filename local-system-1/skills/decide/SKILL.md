---
name: decide
description: Answer a closed-set question (pick one of 2-26 fixed options about a short text) with a local model instead of reasoning it out. Use for classifying or routing text, commit types, "is this command destructive", "did the agent claim it's done", and "does this source support the claim". Accept the answer only at confidence >= 0.9; otherwise decide yourself.
---

# decide

`decide.mjs` asks a local model a multiple-choice question and prints one JSON
line per question. By default the model is Qwen3.5-4B, served by LM Studio on the
host (Metal), at about 0.2-0.4 s per decision.

```bash
node decide.mjs --question "Which team should handle this request?" \
  --option "Billing: charges, invoices, refunds, payment problems" \
  --option "Shipping: delivery status, delays, lost or damaged packages" \
  --state "I was charged twice for my order."
# {"answer":"Billing: ...","index":0,"confidence":0.99,"probabilities":[...]}
```

For several questions, pipe a JSON array of
`{"type":"choice","state","question","options"}` to stdin. `state` may also be
a JSON object with named fields.

## Rules

1. **Accept only at confidence >= 0.9.** In testing, every answer at that level
   was correct. Below it, decide yourself.
2. **Exit code 2** means the model was unreachable or rejected the request.
   Decide yourself.
3. **Options** are full phrases that say what each choice covers, up to 26 per
   question.
4. **New kinds of question** get an eval before you rely on them: add a task
   file to `eval/` with 20+ labelled cases, then run `node eval/eval.mjs task.json`.

## Setup

LM Studio on the host with `qwen3.5-4b` downloaded and its server on port 1234.
Harness containers reach it at `host.docker.internal:1234`.

| variable | default | meaning |
|---|---|---|
| `DECIDE_MODEL` | `qwen3.5-4b` | model name; `julia` uses local-system-1, `jeff` a native [Jeff](https://github.com/firelex/jeff) server |
| `DECIDE_LLM_URL` | `http://host.docker.internal:1234/v1` | ends in `/v1`: OpenAI-style (LM Studio); otherwise Ollama |
| `JULIA_URL` | `http://local-system-1:11435` | only for `DECIDE_MODEL=julia` |
| `JEFF_URL` | `http://host.docker.internal:8765` | only for `DECIDE_MODEL=jeff`; start it with `jeff-serve` (MLX) on the host |
| `JEFF_API_KEY` | unset | sent as a bearer token if the server sets `JEFF_API_KEY` |

local-system-2's Ollama (0.17.7) cannot load Qwen3.5 models, and in Docker it
runs on CPU only, at 8-25 s per decision with a 0.6B model. Use LM Studio.

## Measured (eval/)

| task | Julia-1 | Qwen3.5-4B | Qwen3.5-4B accuracy at conf >= 0.9 (share answered) |
|---|---|---|---|
| ticket-triage (4 teams) | 75% | 100% | 100% (85%) |
| commit-type (6 types) | 38% | 96% | 100% (63%) |
| destructive shell command | 54% | 92% | 100% (50%) |
| claims-done | 55% | 95% | 100% (70%) |
| claim-check (supports / contradicts / silent) | 28% | 100% | 100% (67%) |

The Qwen3.8-4B community distill (empero-ai) scored 83-96% on the same tasks.
Julia-1 (144M) matched upstream's own benchmark but did not carry over to these
free-text questions. Each decision replaces about 110-135 API tokens.
