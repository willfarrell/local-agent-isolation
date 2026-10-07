---
name: skill-router
description: Pick which installed skill, if any, a request needs, using a local model instead of reading every skill description. Use at the start of a request when unsure whether a skill applies.
---

# skill-router

```bash
node route.mjs "containerize this Go CLI"
# {"skills":[{"name":"dockerfile","p":0.86}]}
node route.mjs "what time is it in Tokyo"
# {"skills":[]}
```

Load the skills it returns and ignore the rest. An empty list means no skill
applies, so answer directly. Exit code 2 means the model was unreachable; fall
back to reading the skill list.

It asks the `decide` skill's model one question over `catalog.json`, a
one-line label per skill, plus a "none" option. Uses the same setup as `decide`
(Qwen3.5-4B in LM Studio).

## Keeping it accurate

- Add a line to `catalog.json` whenever a skill is installed. A label says what
  the skill does in a way no other label does; skills with identical labels are
  returned together.
- At most 25 distinct labels fit in one question.
- After editing labels, rerun `node eval/eval.mjs` and
  `CASES=heldout.json node eval/eval.mjs`.

## Measured

"Hit@2" means one of the top two suggestions was right.

| set | approach | hit@2 | suggests a skill when none needed |
|---|---|---|---|
| cases.json (48 prompts) | word overlap | 68% | 18% |
| | Julia-1, best setup | 57% | 91% |
| | Qwen3.5-4B | 89% | 0% |
| heldout.json (30, never tuned on) | word overlap | 48% | 57% |
| | Julia-1 | 43% | 100% |
| | Qwen3.5-4B | 87% | 0% |

About 0.6 s per request. It replaces the ~3,550 tokens of skill descriptions
(27 skills) that would otherwise go to the API model with the one or two that
apply.
