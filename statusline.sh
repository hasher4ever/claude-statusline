#!/bin/bash
# Claude Code status line. Segments (left to right):
#   dir | branch ✱+ahead/behind +/-lines | model+effort | 5h/7d rate limits |
#   ctx + sub = total | session $ | today·yest·week·lwk·mon·all $ | datetime
#
# Reads the JSON Claude Code passes on stdin. Cost stats come from a small cache
# maintained by cost-stats.py (refreshed in the background, never blocks render).
input=$(cat)

# portable python + cache-file mtime (BSD/macOS `stat -f`, GNU/Linux `stat -c`)
PY="$(command -v python3 || echo /usr/bin/python3)"
CACHE="$HOME/.claude/cost-cache.json"
HELPER="$HOME/.claude/cost-stats.py"
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# Keep the day/week/month cost cache fresh without blocking: if it's missing or
# older than 90s, kick off a background refresh (the helper self-guards + locks).
now=$(date +%s)
age=999999
[ -f "$CACHE" ] && age=$(( now - $(mtime "$CACHE") ))
if [ "$age" -gt 90 ] && [ -f "$HELPER" ]; then
  ( nohup "$PY" "$HELPER" >/dev/null 2>&1 & ) 2>/dev/null
fi

printf '%b' "$(echo "$input" | "$PY" -c '
import sys, json, os, subprocess, re
from datetime import datetime, timedelta

d = json.load(sys.stdin)

def k(n):
    return f"{n/1000:.0f}k" if n >= 1000 else str(n)

def money(v):
    if v < 10:          return f"${v:.2f}"   # keep cents for small/early amounts
    if v < 1000:        return f"${v:.0f}"
    if v < 1_000_000:   return f"${v/1000:.1f}k"
    return f"${v/1_000_000:.2f}M"

def usage_total(u):
    return (u.get("input_tokens", 0)
            + u.get("cache_read_input_tokens", 0)
            + u.get("cache_creation_input_tokens", 0))

# --- directory (basename) ---
p = (d.get("workspace", {}) or {}).get("current_dir") or d.get("cwd") or os.getcwd()
dirname = os.path.basename(p.rstrip("/")) or p

# --- git branch + state ---
branch = None
gitstate = ""
def git(*a):
    return subprocess.run(["git", "-C", p, *a], capture_output=True, text=True, timeout=1)
try:
    r = git("rev-parse", "--abbrev-ref", "HEAD")
    if r.returncode == 0 and r.stdout.strip():
        branch = r.stdout.strip()
        if git("status", "--porcelain").stdout.strip():
            gitstate += "✱"  # uncommitted changes
        rl = git("rev-list", "--left-right", "--count", "HEAD...@{u}")
        if rl.returncode == 0 and rl.stdout.strip():
            ahead, behind = rl.stdout.split()
            if int(ahead):  gitstate += f"↑{ahead}"
            if int(behind): gitstate += f"↓{behind}"
except Exception:
    pass

# --- model + reasoning effort ---
model = (d.get("model", {}) or {}).get("display_name", "Claude")
model = re.sub(r"\((\d+[MK]) context\)", r"\1", model)  # "(1M context)" -> "1M"
eff = d.get("effort")
if isinstance(eff, dict):
    eff = eff.get("level")
if eff:
    model = f"{model} {eff}"

# --- main-window context: prefer the payload (authoritative), else scan transcript ---
cw = d.get("context_window", {}) or {}
limit = cw.get("context_window_size") or (1_000_000 if "1M" in model else 200_000)
win = cw.get("total_input_tokens") or 0
tp = d.get("transcript_path")
if not win:
    try:
        if tp and os.path.exists(tp):
            for line in open(tp):
                line = line.strip()
                if not line: continue
                try: o = json.loads(line)
                except Exception: continue
                u = (o.get("message", {}) or {}).get("usage")
                if u: win = usage_total(u)
    except Exception:
        pass

# --- subagent context (sum of each subagent transcript last usage) ---
subtok, subn = 0, 0
try:
    if tp and tp.endswith(".jsonl"):
        subdir = os.path.join(tp[:-6], "subagents")
        if os.path.isdir(subdir):
            for fn in os.listdir(subdir):
                if not fn.endswith(".jsonl"): continue
                last = 0
                for line in open(os.path.join(subdir, fn)):
                    line = line.strip()
                    if not line: continue
                    try: o = json.loads(line)
                    except Exception: continue
                    u = (o.get("message", {}) or {}).get("usage")
                    if u: last = usage_total(u)
                if last:
                    subtok += last
                    subn += 1
except Exception:
    pass

# --- cost / lines (this session) ---
cost = d.get("cost", {}) or {}
usd = cost.get("total_cost_usd")
added = cost.get("total_lines_added", 0)
removed = cost.get("total_lines_removed", 0)

# --- time-bucketed cost from the cache the helper maintains ---
buckets = None
try:
    cpath = os.path.join(os.path.expanduser("~"), ".claude", "cost-cache.json")
    if os.path.exists(cpath):
        daily = (json.load(open(cpath)) or {}).get("daily", {})
        today = datetime.now().astimezone().date()
        yday = today - timedelta(days=1)
        wk = today - timedelta(days=today.weekday())   # Monday this week
        lwk = wk - timedelta(days=7)                    # Monday last week
        mo = today.replace(day=1)
        b = {"today": 0.0, "yesterday": 0.0, "this week": 0.0,
             "last week": 0.0, "month": 0.0, "all time": 0.0}
        for ds, c in daily.items():
            try:
                dd = datetime.strptime(ds, "%Y-%m-%d").date()
            except Exception:
                continue
            b["all time"] += c
            if dd == today:       b["today"] += c
            if dd == yday:        b["yesterday"] += c
            if dd >= wk:          b["this week"] += c
            if lwk <= dd < wk:    b["last week"] += c
            if dd >= mo:          b["month"] += c
        buckets = b
except Exception:
    pass

# --- rate-limit windows: usage % + time left until reset (5h + 7d) ---
def dur(secs):
    if secs <= 0:
        return None
    h, m = divmod(secs // 60, 60)
    dd, h = divmod(h, 24)
    if dd: return f"{dd}d{h}h"
    if h:  return f"{h}h{m:02d}m"
    return f"{m}m"

rl_parts = []   # list of (label, pct, time_left)
try:
    rls = d.get("rate_limits", {}) or {}
    now_ts = datetime.now().timestamp()
    for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
        w = rls.get(key, {}) or {}
        pct = w.get("used_percentage")
        if pct is None:
            continue
        reset = w.get("resets_at")
        left = dur(int(reset - now_ts)) if reset else None
        rl_parts.append((label, pct, left))
except Exception:
    pass

# colors
SEP, DIM, CYAN, MAG, YELLOW, GREEN, RED, ORANGE, WHITE, RST = (
    "\\033[97m", "\\033[2m", "\\033[96m", "\\033[95m", "\\033[93m",
    "\\033[92m", "\\033[91m", "\\033[38;5;208m", "\\033[37m", "\\033[0m")

# each segment is (plain_text, colored_text)
seg = []
def add(plain, color):
    seg.append((plain, f"{color}{plain}{RST}"))

add(dirname, DIM)                       # folder — dim/default
# branch · git-state (✱ ↑ ↓) · diff (+/-) all grouped in one segment
diff_plain = f"+{added} -{removed}" if (added or removed) else ""
diff_colored = f"{GREEN}+{added}{RST} {RED}-{removed}{RST}" if diff_plain else ""
if branch:
    pp, cc = [branch], [f"{DIM}{branch}{RST}"]
    if gitstate:
        pp.append(gitstate); cc.append(f"{YELLOW}{gitstate}{RST}")
    if diff_plain:
        pp.append(diff_plain); cc.append(diff_colored)
    seg.append((" ".join(pp), " ".join(cc)))
elif diff_plain:
    seg.append((diff_plain, diff_colored))
add(model, DIM)                         # model — dim/default

# rate-limit windows right after the model: pct colored by load, reset dim
def load_color(pp):
    return GREEN if pp < 50 else (YELLOW if pp < 80 else RED)
if rl_parts:
    pp, cc = [], []
    for label, pct, left in rl_parts:
        pp.append(f"{label} {pct}%" + (f" ↻{left}" if left else ""))
        cc.append(f"{DIM}{label}{RST} {load_color(pct)}{pct}%{RST}"
                  + (f" {DIM}↻{left}{RST}" if left else ""))
    seg.append((" · ".join(pp), f" {DIM}·{RST} ".join(cc)))
if win:
    pct = round(win / limit * 100)
    if subn:
        # formula: ctx (main window) + sub (all subagents) = total
        plain = f"ctx {k(win)} ({pct}%) + sub {subn}× {k(subtok)} = {k(win + subtok)}"
        colored = (f"{GREEN}ctx {k(win)} ({pct}%){RST}"
                   f" {WHITE}+{RST} {GREEN}sub {subn}× {k(subtok)}{RST}"
                   f" {WHITE}={RST} {GREEN}{k(win + subtok)}{RST}")
        seg.append((plain, colored))
    else:
        add(f"ctx {k(win)} ({pct}%)", GREEN)
if usd is not None:
    add(f"session {money(usd)}", YELLOW)
if buckets is not None:
    labels = [("today", "today"), ("yesterday", "yest"), ("this week", "week"),
              ("last week", "lwk"), ("month", "mon"), ("all time", "all")]
    plain = " · ".join(f"{sh} {money(buckets[key])}" for key, sh in labels)
    colored = f" {DIM}·{RST} ".join(
        f"{DIM}{sh}{RST} {ORANGE}{money(buckets[key])}{RST}" for key, sh in labels)
    seg.append((plain, colored))
add(datetime.now().strftime("%Y-%m-%d %H:%M:%S"), WHITE)

# Claude Code left-aligns the status line and trims leading whitespace,
# so horizontal centering/right-align is not possible from a statusLine command.
line = f" {SEP}|{RST} ".join(colored for _, colored in seg)
print(line, end="")
')"
