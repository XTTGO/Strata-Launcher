#!/usr/bin/env python3
"""Small load generator for the OpenAI-compatible server: C clients at once, each a different prompt.

    python3 tools/serve_load.py http://127.0.0.1:8080 --clients 1,2,4,8 --rounds 3 --max-tokens 256

For every client count it sends C streamed chat requests at the same moment (each prompt starts with its own nonce, so
the prompt cache cannot help), and reports per round and as medians: total tokens/s (all generated tokens over the
wall time of the burst), per-request tokens/s, time to first token (p50 / p95 over all requests of that count), and
the request latency (p50 / p95).  With --save DIR it writes every answer, so a later run can be compared byte for
byte with `--compare DIR` (greedy answers of a request must not depend on who else ran).

Standard library only.  The prompts are fixed texts, so two runs of the tool send the same requests.
"""
import argparse, hashlib, json, os, statistics, sys, threading, time, urllib.request

TOPICS = [
    "the history of lighthouses and how their lenses worked",
    "how a mechanical watch keeps time",
    "why bridges are built as arches and as suspension spans",
    "the water cycle and what a drought does to a river valley",
    "how bread rises, from yeast to crust",
    "the design of a medieval castle and why walls were stepped",
    "how a transistor switches, explained for a curious teenager",
    "the life of a honey bee colony through one year",
]


def prompt_for(i: int, words: int, nonce: str = "", source: str = "") -> str:
    topic = TOPICS[i % len(TOPICS)]
    instruction = (f"[request {i}{nonce}] Write a clear, well organised essay of about {words} words on {topic}. "
                   f"Use plain prose, no lists.")
    if source:
        # Put the changing part before the long source so a repeated source cannot be a cached prefix.
        prefix = hashlib.sha256(f"{nonce}:{i}".encode()).hexdigest()
        return f"[{prefix}]\n{source}\n\n{instruction}"
    return instruction


def one(url, key, model, i, words, max_tokens, res, extra, think, nonce="", source="", start_gate=None):
    body = {"model": model, "stream": True, "max_tokens": max_tokens, "temperature": 0,
            "messages": [{"role": "user", "content": prompt_for(i, words, nonce, source)}]}
    if not think:
        body["reasoning_effort"] = "none"
        body["chat_template_kwargs"] = {"enable_thinking": False}
    body.update(extra)
    req = urllib.request.Request(url + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json",
                                          **({"Authorization": "Bearer " + key} if key else {})})
    if start_gate is not None:
        try:
            start_gate.wait(timeout=30)
        except threading.BrokenBarrierError:
            res[i] = {"first": None, "tokens": 0, "prompt_tokens": None, "cached_tokens": None,
                      "total": 0, "first_at": None, "end_at": None, "text": "", "err": "start barrier failed"}
            return
    t0 = time.perf_counter()
    first, first_at, last_at, n, text, prompt_tokens, cached_tokens = None, None, None, 0, [], None, None
    err = None
    try:
        with urllib.request.urlopen(req, timeout=900) as r:
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                d = line[5:].strip()
                if d == "[DONE]":
                    break
                try:
                    j = json.loads(d)
                except ValueError:
                    continue
                for ch in j.get("choices", []):
                    dl = ch.get("delta", {})
                    piece = (dl.get("content") or "") + (dl.get("reasoning_content") or "")
                    if piece:
                        last_at = time.perf_counter()
                        if first is None:
                            first_at = last_at
                            first = first_at - t0
                        n += 1                      # one SSE chunk = one token (the server flushes per token)
                        text.append(piece)
                if j.get("usage"):
                    n = j["usage"].get("completion_tokens", n)
                    prompt_tokens = j["usage"].get("prompt_tokens", prompt_tokens)
                    cached_tokens = (j["usage"].get("prompt_tokens_details") or {}).get("cached_tokens", cached_tokens)
    except Exception as e:                          # noqa: BLE001
        err = repr(e)
    if source and err is None and prompt_tokens is None:
        err = "stream did not report actual prompt_tokens"
    end_at = time.perf_counter()
    res[i] = {"first": first, "first_at": first_at, "end_at": last_at,
              "tokens": n, "prompt_tokens": prompt_tokens, "cached_tokens": cached_tokens,
              "total": end_at - t0, "text": "".join(text), "err": err}


def output_overlap_seconds(requests):
    """Duration during which at least two requests had begun output but neither had ended."""
    events = sorted((at, delta) for r in requests
                    for at, delta in ((r.get("first_at"), 1), (r.get("end_at"), -1))
                    if isinstance(at, (int, float)) and r.get("first_at") is not None)
    active, previous, overlap = 0, None, 0.0
    for at, delta in events:
        if previous is not None and active >= 2:
            overlap += max(0.0, at - previous)
        active += delta
        previous = at
    return overlap


def pct(v, p):
    v = sorted(v)
    if not v:
        return float("nan")
    k = (len(v) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("--clients", default="1,2,4,8")
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--max-tokens", type=int, default=256)
    ap.add_argument("--words", type=int, default=800, help="the essay length asked for (longer = longer prompt? no: the answer)")
    ap.add_argument("--prompt-file", help="source text placed after a fresh per-request prefix for input-length tests")
    ap.add_argument("--model", default="strata")
    ap.add_argument("--key", default=os.environ.get("STRATA_KEY", ""))
    ap.add_argument("--nonce", default=str(int(time.time())), help="prefix of the per-request nonce (every round reads fresh prompts); '' = identical prompts every round; fix it to compare two runs")
    ap.add_argument("--think", action="store_true")
    ap.add_argument("--stagger", type=float, default=0.0, help="seconds between the starts of the clients of a burst")
    ap.add_argument("--save", help="write every answer (clients/round/request) here")
    ap.add_argument("--compare", help="compare every answer with the files a --save run wrote")
    ap.add_argument("--json", help="write the table as JSON")
    a = ap.parse_args()
    source = open(a.prompt_file, encoding="utf-8").read() if a.prompt_file else ""
    extra = {}
    out = []
    bad = 0
    for c in [int(x) for x in a.clients.split(",")]:
        rows = []
        for rd in range(a.rounds):
            res = {}
            th = []
            t0 = time.perf_counter()
            start_gate = threading.Barrier(c) if c > 1 and not a.stagger else None
            for i in range(c):
                t = threading.Thread(target=one, args=(a.url, a.key, a.model, i, a.words, a.max_tokens, res, extra, a.think, f" {a.nonce}-{c}-{rd}" if a.nonce else "", source, start_gate))
                t.start()
                th.append(t)
                if a.stagger:
                    time.sleep(a.stagger)
            for t in th:
                t.join()
            wall = time.perf_counter() - t0
            toks = sum(r["tokens"] for r in res.values())
            errs = [r["err"] for r in res.values() if r["err"]]
            firsts = [r["first"] for r in res.values() if r["first"] is not None]
            tot = [r["total"] for r in res.values()]
            per = [r["tokens"] / max(r["total"] - (r["first"] or 0), 1e-6) for r in res.values()]
            rows.append({"wall": wall, "toks": toks, "tps": toks / wall, "first": firsts, "lat": tot, "per": per, "err": errs,
                         "output_overlap_seconds": output_overlap_seconds(res.values()),
                         "requests": [{"index": i, "prompt_tokens": r["prompt_tokens"], "completion_tokens": r["tokens"],
                                       "cached_tokens": r["cached_tokens"], "first": r["first"], "total": r["total"], "error": r["err"]}
                                      for i, r in sorted(res.items())]})
            if a.save:
                d = os.path.join(a.save, f"c{c}", f"r{rd}")
                os.makedirs(d, exist_ok=True)
                for i, r in res.items():
                    open(os.path.join(d, f"{i}.txt"), "w", encoding="utf-8").write(r["text"])
            if a.compare:
                for i, r in res.items():
                    p = os.path.join(a.compare, f"c{c}", f"r{rd}", f"{i}.txt")
                    if os.path.exists(p):
                        ref = open(p, encoding="utf-8").read()
                        if ref != r["text"]:
                            n = next((k for k, (x, y) in enumerate(zip(ref, r["text"])) if x != y), min(len(ref), len(r["text"])))
                            print(f"  DIFF c={c} round={rd} req={i}: first difference at char {n}")
                            bad += 1
            print(f"c={c} round={rd}: {toks} tokens in {wall:.1f}s = {toks / wall:.1f} tok/s total"
                  + (f"  ERRORS {errs[:2]}" if errs else ""), flush=True)
        allf = [x for r in rows for x in r["first"]]
        alll = [x for r in rows for x in r["lat"]]
        allp = [x for r in rows for x in r["per"]]
        prompt_counts = [r["prompt_tokens"] for row in rows for r in row["requests"] if r["prompt_tokens"] is not None]
        cached_counts = [r["cached_tokens"] for row in rows for r in row["requests"] if r["cached_tokens"] is not None]
        s = {"clients": c, "total_tps": statistics.median(r["tps"] for r in rows),
             "per_req_tps": statistics.median(allp) if allp else float("nan"),
             "first_p50": pct(allf, .5), "first_p95": pct(allf, .95),
             "lat_p50": pct(alll, .5), "lat_p95": pct(alll, .95), "errors": sum(len(r["err"]) for r in rows)}
        if source:
            s.update({"prompt_tokens_min": min(prompt_counts) if prompt_counts else None,
                      "prompt_tokens_max": max(prompt_counts) if prompt_counts else None,
                      "prompt_token_samples": len(prompt_counts),
                      "cached_tokens_max": max(cached_counts) if cached_counts else None,
                      "cached_token_samples": len(cached_counts),
                      "output_overlap_seconds": min(r["output_overlap_seconds"] for r in rows),
                      "requests": [{"round": rd, **request} for rd, row in enumerate(rows) for request in row["requests"]]})
        out.append(s)
    print("\nclients  total tok/s  per-req tok/s  first p50/p95 (s)  latency p50/p95 (s)  errors")
    for s in out:
        print(f"{s['clients']:>7}  {s['total_tps']:>11.1f}  {s['per_req_tps']:>13.1f}  "
              f"{s['first_p50']:>7.2f}/{s['first_p95']:<7.2f}  {s['lat_p50']:>8.2f}/{s['lat_p95']:<8.2f}  {s['errors']}")
    if a.json:
        json.dump(out, open(a.json, "w"), indent=1)
    if a.compare:
        print("compare:", "ALL IDENTICAL" if not bad else f"{bad} DIFFERENT")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
