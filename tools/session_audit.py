#!/usr/bin/env python3
"""Where the time actually goes: mlx-serve log + agent session DBs -> the tables in OPTIMIZATION_PLAN.md.

Usage:
  python3 tools/session_audit.py                    # server ledger + worst cold spots
  python3 tools/session_audit.py --decode-buckets   # decode tok/s by context, per harness signature
  python3 tools/session_audit.py --thinking-share   # billed vs visible output tokens (pi + Kilo)
  python3 tools/session_audit.py --session <id>     # one Kilo session
  python3 tools/session_audit.py --sessions         # list local-model sessions to pick from

Read-only. Server log: ~/.mlx-serve/logs/mlx-serve-<port>.log
Agent DB:       ~/.local/share/kilo/kilo.db   (tables message/part, JSON in `data`)
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import os
import re
import glob
import sqlite3
import statistics
import sys
from collections import Counter

LOG = os.path.expanduser("~/.mlx-serve/logs/mlx-serve-{port}.log")
DB = os.path.expanduser("~/.local/share/kilo/kilo.db")
LOCAL_MODELS = ("Qwen3.8-Flash-Next", "mlx-serve")

RE_POST = re.compile(
    r"POST /v1/chat/completions \((?P<msgs>\d+) msgs, max_tokens=(?P<mt>\d+).*?"
    r"thinking=(?P<th>\w+), sys=(?P<sysb>\d+)b, user=(?P<usb>\d+)b, tools=(?P<tlb>\d+)b"
)
RE_PROMPT = re.compile(r"  prompt=(\d+) tokens, max_gen=(\d+), ctx=(\d+)")
RE_REUSE = re.compile(r"  \[hot-cache\] reused (\d+)/(\d+) tokens(?: \(matched (\d+); entry (\d+)/(\d+)\))?")
RE_DONE = re.compile(
    r"  <- (\d+)\+(\d+) tokens streamed \[prefill: ([\d.]+) tok/s"
    r"(?: \((\d+) cached / (\d+) total\))?, decode: ([\d.]+) tok/s\](?: \[(\w+)\])?"
)
RE_ECHO = re.compile(r'  > "(.*)')
RE_SSD = re.compile(r"\[disk-cache\] restored (\d+)/(\d+) tokens from SSD in ([\d.]+)ms \(ssm@(\d+)\)")
RE_ARGS = re.compile(r"\[args\] serve: \S+:(\d+), ctx-size=(\d+), pld=(\w+)")
FROZEN_TOKENS = 20_000  # a request with at least this many fresh tokens is a visible freeze


def ts(ms: int) -> str:
    return dt.datetime.fromtimestamp(ms / 1000).strftime("%H:%M:%S")


def parse_log(port: int) -> tuple[list[dict], int, list[dict]]:
    path = LOG.format(port=port)
    if not os.path.exists(path):
        sys.exit(f"no server log at {path}")
    reqs: list[dict] = []
    cur: dict | None = None
    runs = 0
    ssd: list[dict] = []
    with open(path, errors="replace") as fh:
        for line in fh:
            if RE_ARGS.match(line):
                runs += 1
            if line.startswith("mlx-serve ") and "headless" not in line:
                runs = max(runs, 1)
            m = RE_POST.match(line)
            if m:
                cur = {k: (int(m[k]) if k != "th" else m[k]) for k in ("msgs", "mt", "sysb", "usb", "tlb", "th")}
                cur["run"] = runs
                reqs.append(cur)
                continue
            if cur is None:
                if (m := RE_SSD.search(line)):
                    ssd.append({"restored": int(m[1]), "prompt": int(m[2]), "ms": float(m[3]), "ssm": int(m[4])})
                continue
            if (m := RE_ECHO.match(line)) and "echo" not in cur:
                cur["echo"] = m[1][:60]
            elif (m := RE_PROMPT.match(line)):
                cur["prompt"] = int(m[1])
            elif (m := RE_REUSE.match(line)):
                cur["reused"] = int(m[1])
                cur["ptotal"] = int(m[2])
                cur["matched"] = int(m[3]) if m[3] else int(m[1])
            elif "cold prefill" in line or "hybrid miss" in line:
                cur["hybrid_miss"] = True
            elif (m := RE_SSD.search(line)):
                ssd.append({"restored": int(m[1]), "prompt": int(m[2]), "ms": float(m[3]), "ssm": int(m[4])}
                           )
            elif (m := RE_DONE.match(line)):
                cur["out"] = int(m[2])
                cur["pre_rate"] = float(m[3])
                # the server omits "(N cached / M total)" exactly when nothing was cached
                cur["cached"] = int(m[4]) if m[4] else 0
                cur["ptotal"] = int(m[5]) if m[5] else int(m[1])
                cur["dec_rate"] = float(m[6])
                cur["fin"] = m[7] or ""
                cur["fresh"] = cur["ptotal"] - cur["cached"]
                cur["pre_s"] = cur["fresh"] / cur["pre_rate"] if cur["pre_rate"] else 0.0
                cur["dec_s"] = cur["out"] / cur["dec_rate"] if cur["dec_rate"] else 0.0
                cur = None
    return [r for r in reqs if "fresh" in r], runs, ssd


def pct(x: float, n: float) -> str:
    return f"{100 * x / n:5.1f}%" if n else "    -"


def server_report(reqs: list[dict], runs: int, port: int, ssd: list[dict]) -> None:
    billed = sum(r["ptotal"] for r in reqs)
    fresh = sum(r["fresh"] for r in reqs)
    pre = sum(r["pre_s"] for r in reqs)
    out = sum(r["out"] for r in reqs)
    dec = sum(r["dec_s"] for r in reqs)
    print(f"# server ledger  ({LOG.format(port=port)})")
    print(f"requests {len(reqs)}   server runs {runs}")
    print(f"billed prompt tokens   {billed:>12,}")
    print(f"fresh prefilled tokens {fresh:>12,}   reuse {pct(billed - fresh, billed)}")
    print(f"prefill wall {pre:8,.0f} s @ {fresh / pre if pre else 0:6.0f} tok/s   "
          f"decode wall {dec:8,.0f} s @ {out / dec if dec else 0:5.1f} tok/s")
    print(f"prefill share of inference wall: {pct(pre, pre + dec)}   (decode {pct(dec, pre + dec)})")

    cold = [r for r in reqs if r["cached"] == 0]
    print(f"\n## fully-cold requests (zero reuse) : {len(cold)} "
          f"-> {sum(r['fresh'] for r in cold):,} fresh tokens, "
          f"{sum(r['pre_s'] for r in cold):,.0f} s prefill, "
          f"{sum(r['dec_s'] for r in cold):,.0f} s decode")
    for r in sorted(cold, key=lambda r: -r["pre_s"])[:12]:
        print(f"   fresh={r['fresh']:>7} pre={r['pre_s']:>6.1f}s gen={r['out']:>5} "
              f"msgs={r['msgs']:>4} sys={r['sysb']:>6}b tools={r['tlb']:>6}b "
              f":: {r.get('echo', '')[:44]!r}")

    loss = [r["matched"] - r["reused"] for r in reqs if r.get("matched", 0) > r.get("reused", 0)]
    if loss:
        print(f"\n## checkpoint-granularity loss: {len(loss)}/{len(reqs)} requests matched past what they reused")
        print(f"   tokens lost median={statistics.median(loss):.0f} "
              f"p90={sorted(loss)[int(len(loss) * .9)]:.0f} max={max(loss):,} total={sum(loss):,} "
              f"(~{sum(loss) / (fresh / pre if pre else 1):,.0f} s)")
    hyb = [r for r in reqs if r.get("hybrid_miss")]
    print(f"   'hybrid miss / cold prefill' lines: {len(hyb)}")

    print("\n## decode rate by prompt size")
    for lo, hi in ((0, 8192), (8192, 16384), (16384, 32768), (32768, 65536),
                   (65536, 98304), (98304, 131072), (131072, 10 ** 9)):
        sel = [r for r in reqs if lo <= r["ptotal"] < hi and r["out"] > 50]
        if sel:
            d = sum(r["out"] for r in sel) / sum(r["dec_s"] for r in sel)
            p = sum(r["fresh"] for r in sel) / max(1e-9, sum(r["pre_s"] for r in sel))
            print(f"   {lo:>6}-{hi if hi < 10**8 else '+':>6} n={len(sel):>4}  decode {d:5.1f} tok/s   prefill {p:6.0f} tok/s")

    sig = lambda r: (r["sysb"], r["tlb"])
    sw = [reqs[i] for i in range(1, len(reqs)) if sig(reqs[i]) != sig(reqs[i - 1])]
    print(f"\n## prompt-signature churn: {len({sig(r) for r in reqs})} distinct (sys,tools) signatures, "
          f"{len(sw)} switches -> {sum(r['fresh'] for r in sw):,} fresh tokens")
    for r in sorted(sw, key=lambda r: -r["fresh"])[:6]:
        print(f"   fresh={r['fresh']:>7} of {r['ptotal']:>7} tools={r['tlb']:>6}b :: {r.get('echo', '')[:40]!r}")

    sizes = [r["ptotal"] for r in reqs]
    print(f"\ncontext: median prompt {statistics.median(sizes):.0f}  max {max(sizes):,}  "
          f">=98k {len([s for s in sizes if s >= 98304])}  fresh/step median "
          f"{statistics.median([r['fresh'] for r in reqs]):.0f} p90 {sorted(r['fresh'] for r in reqs)[int(len(reqs) * .9)]:,}")
    if ssd:
        short = [s for s in ssd if s["prompt"] - s["restored"] > 20000]
        print(f"\n## SSD tier: {len(ssd)} restores, {sum(s['ms'] for s in ssd):,.0f} ms total I/O "
              f"(fast: {max((s['ms'] for s in ssd), default=0):.0f} ms worst) BUT "
              f"{len(short)} restored >20k tokens short of the match -> re-prefilled at {fresh / pre if pre else 0:.0f} tok/s")
        for s in sorted(short, key=lambda s: s["prompt"] - s["restored"], reverse=True)[:6]:
            print(f"   restored {s['restored']:>7}/{s['prompt']:>7} in {s['ms']:>7.0f} ms  (ssm@{s['ssm']}) "
                  f"-> {s['prompt'] - s['restored']:>7} tokens recomputed")


def sessions_list() -> None:
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    q = """select s.id, s.title, count(m.id), min(m.time_created),
                (select group_concat(distinct json_extract(m2.data,'$.modelID'))
                   from message m2 where m2.session_id = s.id
                     and json_extract(m2.data,'$.role')='assistant')
           from session s join message m on m.session_id = s.id
          where json_extract(m.data,'$.role')='assistant'
          group by s.id having count(m.id) > 4 order by min(m.time_created) desc limit 40"""
    for sid, title, n, t0, models in con.execute(q):
        local = any(k in (models or "") for k in LOCAL_MODELS)
        print(f"{'LOCAL' if local else '     '}  {sid}  n={n:<4} {ts(t0)}  {title[:48]:48} {models[:40] if models else ''}")


def session_report(sid: str) -> None:
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    rows = []
    q = """select id, data from message where session_id=? and json_extract(data,'$.role')='assistant'
           order by time_created"""
    for mid, d in con.execute(q, (sid,)):
        j = json.loads(d)
        tk = j.get("tokens") or {}
        ca = tk.get("cache") or {}
        t = j.get("time") or {}
        tool = 0
        for (pd_,) in con.execute(
            "select data from part where message_id=? and json_extract(data,'$.type')='tool'", (mid,)
        ):
            tm = (json.loads(pd_).get("state") or {}).get("time") or {}
            if tm.get("start"):
                tool += max(0, (tm.get("end") or tm["start"]) - tm["start"])
        rows.append(
            dict(start=t.get("created", 0), fresh=tk.get("input") or 0, cached=ca.get("read") or 0,
                 out=(tk.get("output") or 0) + (tk.get("reasoning") or 0),
                 el=(t.get("completed") or t.get("created", 0)) - t.get("created", 0), tool=tool)
        )
    if not rows:
        sys.exit(f"no assistant steps for {sid}")
    llm = [max(0, r["el"] - r["tool"]) for r in rows]
    billed = sum(r["fresh"] + r["cached"] for r in rows)
    fresh = sum(r["fresh"] for r in rows)
    out = sum(r["out"] for r in rows)
    print(f"# session {sid}   steps={len(rows)}   {ts(rows[0]['start'])} -> {ts(rows[-1]['start'])}")
    print(f"billed {billed:,}  cached {billed - fresh:,} ({pct(billed - fresh, billed)})  fresh {fresh:,}  generated {out:,}")
    print(f"elapsed {sum(r['el'] for r in rows) / 1000:,.0f} s = tool {sum(r['tool'] for r in rows) / 1000:,.0f} s "
          f"+ LLM {sum(llm) / 1000:,.0f} s")
    print(f"model-time estimate: prefill {fresh / 1159:,.0f} s ({pct(fresh / 1159, fresh / 1159 + out / 72)}) "
          f"+ decode {out / 72:,.0f} s")
    fr = sorted(r["fresh"] for r in rows)
    print(f"fresh/step median {statistics.median(fr):.0f}  p90 {fr[int(len(fr) * .9)]:,}  max {max(fr):,}")
    print(f"\n## frozen steps: LLM wall >> (fresh/1159 + out/72), or fresh >= {FROZEN_TOKENS:,}")
    for r in sorted(rows, key=lambda r: -r["fresh"])[:12]:
        if r["fresh"] < 4000:
            break
        exp = r["fresh"] / 1159 + r["out"] / 72
        print(f"   {ts(r['start'])}  fresh={r['fresh']:>7}  cached={r['cached']:>7}  out={r['out']:>5}  "
              f"llm={max(0, r['el'] - r['tool']) / 1000:>6.1f}s  (explains {exp:5.0f}s)  "
              f"unexplained={max(0, (r['el'] - r['tool']) / 1000 - exp):5.1f}s")
    gaps = [rows[i + 1]["start"] - rows[i]["start"] for i in range(len(rows) - 1)]
    if gaps:
        print(f"\nstep-to-step wall gaps: median {statistics.median(gaps) / 1000:.1f}s "
              f"p90 {sorted(gaps)[int(len(gaps) * .9)] / 1000:.1f}s max {max(gaps) / 1000:.1f}s "
              f"total {sum(gaps) / 1000:,.0f}s (includes your thinking time)")


# ---------------------------------------------------------------- harness compare
BUCKETS = ((0, 8192), (8192, 16384), (16384, 32768), (32768, 65536),
           (65536, 98304), (98304, 131072), (131072, 10 ** 9))


def decode_buckets(reqs, top=8):
    """Decode tok/s by context size, split by request signature (sys_bytes, tools_bytes).
    Server-side only - no client join, so every completed request is counted."""
    sigs = Counter((r["sysb"], r["tlb"]) for r in reqs if r.get("dec_rate") and r["out"] > 50)
    keep = {s for s, _ in sigs.most_common(top)}
    print(f"decode tok/s by context bucket, per request signature ({len(keep)} shown of {len(sigs)})")
    print(f"{'bucket':>16} " + " ".join(f"{str(s[0])+'/'+str(s[1]):>16}" for s in sorted(keep, key=lambda s: -sigs[s])))
    for lo, hi in BUCKETS:
        cells = []
        for s in sorted(keep, key=lambda s: -sigs[s]):
            g = [r for r in reqs if r.get("dec_rate") and lo <= r["prompt"] < hi and r["out"] > 50
                 and (r["sysb"], r["tlb"]) == s]
            v = sum(r["out"] for r in g) / max(1e-9, sum(r["dec_s"] for r in g)) if g else None
            cells.append(f"{v:6.1f} (n={len(g):>3})" if v else f"{'-':>13}       ")
        lab = f"{lo // 1024}K-" + ("+" if hi > 10 ** 8 else f"{hi // 1024}K")
        print(f"{lab:>16} " + " ".join(cells))
    print("\nsignature = (system-prompt bytes, tool-schema bytes); a new signature is a new "
          "cache entry and a cold prefill")


def kilo_visible(mid, con):
    """(thinking, answer text, tool-arg) bytes stored for one assistant message."""
    rea = txt = arg = 0
    for (pd_,) in con.execute("select data from part where message_id=?", (mid,)):
        try:
            p = json.loads(pd_)
        except Exception:
            continue
        ty = p.get("type")
        if ty == "reasoning":
            rea += len(p.get("text") or "")
        elif ty == "text" and not p.get("synthetic"):
            txt += len(p.get("text") or "")
        elif ty == "tool":
            arg += len(json.dumps((p.get("state") or {}).get("input") or {}))
    return rea, txt, arg


def pi_sessions():
    """pi's own per-message token ledger -> same shape as a Kilo session."""
    out = {}
    for f in sorted(glob.glob(os.path.expanduser("~/.pi/agent/sessions/*/*.jsonl"))):
        steps, sysb, tlb, lvl = [], 0, 0, []
        for line in open(f, errors="replace"):
            try:
                j = json.loads(line)
            except Exception:
                continue
            if j.get("type") == "thinking_level_change":
                lvl.append(j.get("thinkingLevel"))
            m = j.get("message") or {}
            if m.get("role") == "system":
                sec = m.get("sections") or {}
                sysb = sum(len(v) for k, v in sec.items() if k != "tools")
                tlb = sum(len(v) for k, v in sec.items() if k == "tools")
            if m.get("role") != "assistant":
                continue
            u = m.get("usage") or {}
            rea = sum(len(c.get("thinking") or "") for c in m.get("content") or [] if c.get("type") == "thinking")
            txt = sum(len(c.get("text") or "") for c in m.get("content") or [] if c.get("type") == "text")
            arg = sum(len(json.dumps(c.get("arguments") or {})) for c in m.get("content") or []
                      if c.get("type") == "toolCall")
            steps.append(dict(t=j.get("timestamp"), fresh=u.get("input") or 0,
                              out=(u.get("output") or 0) + (u.get("reasoning") or 0),
                              cache=u.get("cacheRead") or 0, rea=rea, txt=txt, arg=arg))
        if steps:
            name = os.path.basename(f)[:10] + " (pi) " + os.path.basename(os.path.dirname(f))[2:34]
            out[name] = dict(steps=steps, sysb=sysb, tlb=tlb, model=steps[-1].get("model") or "",
                             lvl=">".join(dict.fromkeys(lvl)))
    return out


def thinking_share(con, port=11234, limit=8, min_out=200):
    """How much of what we PAID TO GENERATE was ever visible. ~4 bytes/token."""
    print("thinking vs visible content (billed output tokens vs stored bytes, ~4 B/token)")
    print("NOTE: mlx-serve bills the thinking stream as ordinary output; Kilo records "
          "tokens.reasoning=0, so nothing here is server-reported 'reasoning'.\n")
    rows = []
    for sid, title, nmsg, t0, models in con.execute(
            """select s.id, s.title, count(m.id), min(m.time_created),
                      (select group_concat(distinct json_extract(m2.data,'$.modelID'))
                         from message m2 where m2.session_id = s.id
                           and json_extract(m2.data,'$.role')='assistant')
                 from session s join message m on m.session_id = s.id
                where json_extract(m.data,'$.role')='assistant'
                group by s.id having count(m.id) > 4
                order by min(m.time_created) desc limit 40"""):
        if not any(k in (models or "") for k in LOCAL_MODELS):
            continue
        msgs = con.execute("select id, data from message where session_id=? "
                           "and json_extract(data,'$.role')='assistant'", (sid,)).fetchall()
        if len(msgs) < 5:
            continue
        agg = Counter(); bad = []
        for mid, d in msgs:
            j = json.loads(d); out = (j.get("tokens") or {}).get("output") or 0
            rea, txt, arg = kilo_visible(mid, con)
            agg["out"] += out; agg["rea"] += rea; agg["txt"] += txt; agg["arg"] += arg
            if out >= 8000 and (txt + arg) / 4 < 500:
                bad.append((dt.datetime.fromtimestamp(j["time"]["created"] / 1000).strftime("%H:%M"),
                            out, rea // 4, (txt + arg) // 4,
                            (j["time"].get("completed", 0) - j["time"]["created"]) / 1000))
        rows.append(("Kilo", title[:34], agg, bad, len(msgs)))
        if len(rows) >= limit:
            break
    for name, st in list(pi_sessions().items())[:limit]:
        agg = Counter()
        bad = []
        for s in st["steps"]:
            agg["out"] += s["out"]; agg["rea"] += s["rea"]; agg["txt"] += s["txt"]; agg["arg"] += s["arg"]
            if s["out"] >= 8000 and (s["txt"] + s["arg"]) / 4 < 500:
                bad.append((s["t"][11:16], s["out"], s["rea"] // 4, (s["txt"] + s["arg"]) // 4, 0))
        rows.append(("pi", st["lvl"] + " " + name[-24:], agg, bad, len(st["steps"])))
    print(f"{'harness':>8} {'session':36} {'steps':>5} {'billed out':>11} {'thinking':>9} "
          f"{'visible txt':>10} {'tool args':>10} {'think %':>8}")
    for kind, title, agg, bad, n in sorted(rows, key=lambda r: -r[2]["rea"] / max(1, r[2]["out"])):
        tok = lambda b: b / 4
        t, x, a, o = tok(agg["rea"]), tok(agg["txt"]), tok(agg["arg"]), agg["out"]
        print(f"{kind:>8} {title[:36]:36} {n:>5} {o:>11,.0f} {t:>9,.0f} {x:>10,.0f} {a:>10,.0f} "
              f"{100 * t / max(1, o):>7.0f}%")
    worst = [(k, ti, b) for k, ti, agg, bad, n in rows for b in bad]
    if worst:
        print(f"\nsteps that billed >=8,000 output tokens and showed <500 ({len(worst)} found) - "
              f"candidates for --reasoning-budget:")
        for kind, title, (t, out, rea, vis, sec) in sorted(worst, key=lambda w: -w[2][1])[:12]:
            print(f"   {kind:>5} {t}  billed={out:>7,}  thinking~{rea:>7,}  visible~{vis:>5,}  "
                  f"wall={sec:>6.1f}s   [{title[:28]}]")
    print("\nreference points measured 2026-09-24: pi 34% thinking share, Kilo 48%; "
          "worst measured step 21,521 billed tokens for a 557-byte todowrite (396 s).")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=11234)
    ap.add_argument("--session")
    ap.add_argument("--sessions", action="store_true")
    ap.add_argument("--decode-buckets", action="store_true",
                    help="decode tok/s by context size, split by request signature")
    ap.add_argument("--thinking-share", action="store_true",
                    help="billed vs visible output tokens (pi and Kilo ledgers)")
    ap.add_argument("--limit", type=int, default=8, help="rows/signatures to show")
    a = ap.parse_args()
    if a.sessions:
        sessions_list()
    elif a.session:
        session_report(a.session)
    elif a.decode_buckets:
        reqs, runs, ssd = parse_log(a.port)
        decode_buckets(reqs, top=a.limit)
    elif a.thinking_share:
        thinking_share(sqlite3.connect(f"file:{DB}?mode=ro", uri=True), a.port, a.limit)
    else:
        reqs, runs, ssd = parse_log(a.port)
        server_report(reqs, runs, a.port, ssd)
