#!/usr/bin/env python3
"""Aggregate Claude Code token cost per local-day across all transcripts.

Scans ~/.claude/projects/**/*.jsonl incrementally (skips files whose mtime+size
are unchanged since last run) and writes ~/.claude/cost-cache.json:

    {"updated": <epoch>, "daily": {"YYYY-MM-DD": <usd>}, "files": {path: {...}}}

The status line reads `daily` and buckets it into today/yesterday/week/month.
A lock file prevents concurrent refreshes; a freshness guard makes re-runs cheap.
"""
import json, os, glob, time, sys
from datetime import datetime

HOME = os.path.expanduser("~")
PROJECTS = os.path.join(HOME, ".claude", "projects")
CACHE = os.path.join(HOME, ".claude", "cost-cache.json")
LOCK = os.path.join(HOME, ".claude", ".cost-cache.lock")
FRESH_SECS = 90          # if cache younger than this, do nothing
LOCK_STALE = 600         # ignore a lock older than this (crashed run)

# per-million-token prices: (input, output, cache_write_5m, cache_write_1h, cache_read)
PRICES = {
    "opus":   (15.0, 75.0, 18.75, 30.0, 1.50),
    "sonnet": (3.0,  15.0,  3.75,  6.0, 0.30),
    "haiku":  (1.0,   5.0,  1.25,  2.0, 0.10),
}

def price_for(model):
    m = (model or "").lower()
    for key, v in PRICES.items():
        if key in m:
            return v
    return PRICES["sonnet"]

def msg_cost(model, u):
    inp, out, cw5, cw1h, cr = price_for(model)
    cc = u.get("cache_creation", {}) or {}
    e5 = cc.get("ephemeral_5m_input_tokens", 0)
    e1 = cc.get("ephemeral_1h_input_tokens", 0)
    if not cc:  # older entries: no breakdown — treat all cache-creation as 5m
        e5 = u.get("cache_creation_input_tokens", 0)
    return (u.get("input_tokens", 0) * inp
            + u.get("output_tokens", 0) * out
            + u.get("cache_read_input_tokens", 0) * cr
            + e5 * cw5 + e1 * cw1h) / 1_000_000.0

def file_days(path):
    days = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                m = o.get("message", {}) or {}
                u = m.get("usage")
                ts = o.get("timestamp")
                if not u or not ts:
                    continue
                try:
                    dt = datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone()
                except Exception:
                    continue
                c = msg_cost(m.get("model"), u)
                if c:
                    key = dt.strftime("%Y-%m-%d")
                    days[key] = days.get(key, 0.0) + c
    except Exception:
        pass
    return days

def main():
    # freshness guard
    try:
        if os.path.exists(CACHE) and time.time() - os.path.getmtime(CACHE) < FRESH_SECS:
            return
    except Exception:
        pass
    # lock
    try:
        if os.path.exists(LOCK) and time.time() - os.path.getmtime(LOCK) < LOCK_STALE:
            return
        open(LOCK, "w").close()
    except Exception:
        pass

    try:
        cache = {}
        if os.path.exists(CACHE):
            try:
                cache = json.load(open(CACHE))
            except Exception:
                cache = {}
        old_files = cache.get("files", {})
        new_files = {}

        for path in glob.glob(os.path.join(PROJECTS, "**", "*.jsonl"), recursive=True):
            try:
                st = os.stat(path)
            except Exception:
                continue
            prev = old_files.get(path)
            if prev and prev.get("mtime") == st.st_mtime and prev.get("size") == st.st_size:
                new_files[path] = prev
            else:
                new_files[path] = {"mtime": st.st_mtime, "size": st.st_size,
                                   "days": file_days(path)}

        daily = {}
        for info in new_files.values():
            for d, c in info.get("days", {}).items():
                daily[d] = daily.get(d, 0.0) + c

        tmp = CACHE + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"updated": time.time(), "daily": daily, "files": new_files}, f)
        os.replace(tmp, CACHE)
    finally:
        try:
            os.remove(LOCK)
        except Exception:
            pass

if __name__ == "__main__":
    main()
