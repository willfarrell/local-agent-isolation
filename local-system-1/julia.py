"""Julia-1 (ONNX) typed decisions over HTTP. Usage: julia.py serve | check. See README.md."""
import hashlib
import http.server
import json
import os
import pathlib
import sys
import urllib.request

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

REPO = "https://huggingface.co/SupersonicLabs/Julia-1-ONNX/resolve"
REVISION = "82a2fadf8fccfccdc5fd4e1009ba8f1a265eb7a8"
# LFS oids from the pinned revision; parity-cases.json is plain git, pinned by REVISION alone.
FILES = {
    "model.onnx": "97141d0cfb1da6204e9f8f24d581af72eaeb82cda21149d83eaa6df7160fbcd9",
    "model.onnx.data": "fd915be810d7ebfb80fb05a48dd33c9484d17ae1b6bcb9e1f544cbaaa913ded1",
    "tokenizer.json": "609d8f4c067cd3950f88594c5a802616cea245823836ef5848ee4fc40aab5b6f",
    "parity-cases.json": None,
}
MODEL_DIR = pathlib.Path(os.environ.get("JULIA_MODEL", "/home/model")) / REVISION
PORT = int(os.environ.get("JULIA_PORT", "11435"))

# Upstream's index.js contract: maxLength 1024, headLength 256, 48 tokens per option, strict.
TYPES = {"choice": 0, "score": 1, "noul": 2}
MAX_LENGTH, HEAD_LENGTH, OPTION_TOKENS = 1024, 256, 48
MAX_ROWS, MAX_BODY = 64, 1 << 20


def fetch():
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    for name, sha in FILES.items():
        path = MODEL_DIR / name
        if path.exists():
            continue
        print(f"fetching {name}", file=sys.stderr, flush=True)
        part, digest = path.with_name(name + ".part"), hashlib.sha256()
        with urllib.request.urlopen(f"{REPO}/{REVISION}/{name}") as r, open(part, "wb") as f:
            while chunk := r.read(1 << 20):
                digest.update(chunk)
                f.write(chunk)
        if sha and digest.hexdigest() != sha:
            part.unlink()
            sys.exit(f"{name}: sha256 {digest.hexdigest()}, expected {sha}")
        part.rename(path)


class Julia:
    def __init__(self):
        fetch()
        self.tok = Tokenizer.from_file(str(MODEL_DIR / "tokenizer.json"))
        self.cls, self.sep, self.mask = (self.tok.token_to_id(t) for t in ("<bos>", "<eos>", "<mask>"))
        self.session = ort.InferenceSession(str(MODEL_DIR / "model.onnx"), providers=["CPUExecutionProvider"])

    def encode(self, text):
        return self.tok.encode(text, add_special_tokens=False).ids

    # ponytail: strict mode only, as upstream defaults; overflow is a 400, never a silent truncation.
    def serialize(self, row):
        kind, question, state, options = row.get("type"), row.get("question"), row.get("state"), row.get("options")
        if (
            kind not in TYPES
            or not isinstance(question, str)
            # ponytail: string state only; upstream's pythonJSON for dict/list state is not ported.
            or not isinstance(state, str)
            or not isinstance(options, list)
            or not 2 <= len(options) <= 20
            or any(not isinstance(x, str) or not x for x in options)
            or (kind == "noul" and len(options) != 2)
        ):
            raise ValueError("Invalid Julia decision request")
        if any("<mask>" in x for x in (state, question, *options)):
            raise ValueError("Reserved model marker in request")
        head = self.encode(f"{kind} question: {question}")
        option_ids = [self.encode(f" {x}") for x in options]
        if any(len(x) > OPTION_TOKENS for x in option_ids):
            raise ValueError("Option exceeds 48-token model contract")
        budget = HEAD_LENGTH - sum(len(x) + 1 for x in option_ids)
        if budget < 16 or len(head) > budget:
            raise ValueError("Question/options exceed lossless head budget")
        ids, markers = [self.cls, *head, self.sep], []
        for x in option_ids:
            markers.append(len(ids))
            ids += [self.mask, *x]
        ids.append(self.sep)
        room = MAX_LENGTH - len(ids) - 1
        if room < 1:
            raise ValueError("Question/options exceed sequence budget")
        state_ids = self.encode(state)
        if len(state_ids) > room:
            raise ValueError("State exceeds lossless context budget")
        return ids + state_ids + [self.sep], markers, TYPES[kind]

    def logits(self, rows):
        if not isinstance(rows, list) or not 1 <= len(rows) <= MAX_ROWS:
            raise ValueError(f"Body must be a JSON array of 1 to {MAX_ROWS} requests")
        items = [self.serialize(r if isinstance(r, dict) else {}) for r in rows]
        length = -(-max(len(ids) for ids, _, _ in items) // 8) * 8
        count = max(len(m) for _, m, _ in items)
        feed = {
            "input_ids": np.zeros((len(items), length), np.int64),
            "attention_mask": np.zeros((len(items), length), np.int64),
            "marker_pos": np.zeros((len(items), count), np.int64),
            "marker_mask": np.zeros((len(items), count), np.bool_),
            "qtype": np.array([q for _, _, q in items], np.int64),
        }
        for i, (ids, markers, _) in enumerate(items):
            feed["input_ids"][i, : len(ids)] = ids
            feed["attention_mask"][i, : len(ids)] = 1
            feed["marker_pos"][i, : len(markers)] = markers
            feed["marker_mask"][i, : len(markers)] = True
        out = self.session.run(["logits"], feed)[0]
        return [out[i, : len(m)] for i, (_, m, _) in enumerate(items)]

    def predict(self, rows):
        return [{"index": int(v.argmax()), "probabilities": display(v)} for v in self.logits(rows)]


def display(logits):
    p = np.exp(logits - logits.max())
    p /= p.sum()
    w = int(p.argmax())
    if p[w] > 0.95 and all(x < 0.045 for i, x in enumerate(p) if i != w):
        return [float(i == w) for i in range(len(p))]
    p = np.where(p < 0.01, 0, p)
    return [float(x) for x in p / p.sum()]


def check(julia):
    """Upstream's parity cases: our argmax must match PyTorch's on every one."""
    cases = json.loads((MODEL_DIR / "parity-cases.json").read_text())
    worst, bad = 0.0, 0
    for i in range(0, len(cases), 16):
        batch = cases[i : i + 16]
        for case, got in zip(batch, julia.logits([c["request"] for c in batch])):
            want = np.array(case["pytorch_logits"])
            worst = max(worst, float(np.abs(got - want).max()))
            bad += int(got.argmax() != want.argmax())
    print(f"{len(cases) - bad}/{len(cases)} match, max abs logit error {worst:.4f}")
    assert bad == 0, f"{bad} parity mismatches"


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            self.reply(200, {"ok": True})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/predict":
            return self.reply(404, {"error": "not found"})
        try:
            size = int(self.headers.get("Content-Length") or 0)
            if size > MAX_BODY:
                raise ValueError("Request body over 1 MiB")
            self.reply(200, JULIA.predict(json.loads(self.rfile.read(size))))
        except ValueError as e:
            self.reply(400, {"error": str(e)})


if __name__ == "__main__":
    JULIA = Julia()
    if sys.argv[1:] == ["check"]:
        check(JULIA)
    else:
        # ponytail: one request at a time; ThreadingHTTPServer if callers queue behind each other.
        http.server.HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
