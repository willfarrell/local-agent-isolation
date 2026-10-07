# local-system-1

Fast typed decisions with [Julia-1](https://huggingface.co/SupersonicLabs/Julia-1),
a 144M-parameter encoder. You give it a state, a question and 2 to 20 options,
and it returns the index of the option it picked plus a probability for each
option. It does not generate text; use `local-system-2` for that.

It runs upstream's ONNX export
([Julia-1-ONNX](https://huggingface.co/SupersonicLabs/Julia-1-ONNX)) on CPU
through Alpine's onnxruntime, on amd64 and arm64.

## Start it

```bash
docker compose -f compose.yaml up -d local-system-1
```

The first start downloads about 610 MB of weights, checks their sha256, and
stores them in `~/.agents/models/julia-1`. Later starts reuse them. The
service reports healthy once the model is loaded:

```bash
docker compose -f compose.yaml ps local-system-1
```

| from | URL |
|---|---|
| the host | `http://127.0.0.1:11435` (`SYSTEM1_PORT` changes the host port) |
| a harness container | `http://local-system-1:11435` |

## Call it

`POST /predict` with a JSON array of 1 to 64 requests. You get back an array
of the same length, in the same order.

```bash
curl -s http://127.0.0.1:11435/predict -d '[{
  "type": "choice",
  "state": "I was charged twice for the same order.",
  "question": "Which team should handle this request?",
  "options": ["Billing and payment disputes", "Shipping and delivery", "Account access and login"]
}]'
```

The response has this shape (the numbers here are illustrative):

```json
[{"index": 0, "probabilities": [1.0, 0.0, 0.0]}]
```

### Request fields

| field | type | rule |
|---|---|---|
| `type` | string | `choice`, `score` or `noul` (required) |
| `state` | string | the context to decide about; `""` is allowed |
| `question` | string | what to decide |
| `options` | array of strings | 2 to 20 non-empty strings; exactly 2 for `noul` |

The three types:

- **`choice`**: pick the best option. `index` is the winner.
- **`score`**: the options are an ordered rubric, lowest first. `index` is
  the rung the state reaches.
- **`noul`**: a yes/no question. Put the false description first and the
  true one second, for example `["No", "Yes"]`. `probabilities[1]` is the
  probability of true.

### Response fields

| field | meaning |
|---|---|
| `index` | zero-based position of the winning option in your `options` |
| `probabilities` | one number per option, summing to 1 |

The probabilities are rounded for display, the same way upstream does it. If
the winner is above 0.95 and every other option is below 0.045, the result
is one-hot. Otherwise values below 0.01 become 0 and the rest are
renormalized.

### Limits

Requests are never truncated. Anything over a limit is rejected with HTTP 400
and `{"error": "..."}`, so you can shorten it and retry.

| limit | error |
|---|---|
| each option at most 48 tokens | `Option exceeds 48-token model contract` |
| question plus all options within 256 tokens | `Question/options exceed lossless head budget` |
| whole request within 1,024 tokens | `State exceeds lossless context budget` |
| `<mask>` anywhere in the text | `Reserved model marker in request` |
| a bad field or type | `Invalid Julia decision request` |
| more than 64 requests, or a body over 1 MiB | a message naming the limit |

`state` must be a string. Upstream also accepts an object or array state; to
send one here, serialize it to a string yourself.

Requests are handled one at a time. Batch several questions into one call
rather than sending them in parallel.

## Check it

This runs upstream's 100 parity cases and fails if any pick differs from the
PyTorch reference:

```bash
docker compose -f compose.yaml exec local-system-1 python3 /opt/julia/julia.py check
```

`GET /healthz` returns `{"ok": true}` once the model is loaded.
