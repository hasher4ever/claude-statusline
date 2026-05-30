# Claude Code Status Line

A rich, single-line status bar for [Claude Code](https://claude.com/claude-code)
that shows your repo, model + reasoning effort, live context-window usage
(including subagents), rate-limit windows, and a full cost breakdown
(today / yesterday / this week / last week / month / all time).

```
myproject | main ✱ +42 -7 | Opus 4.8 1M high | 5h 5% ↻4h30m · 7d 16% ↻3d18h | ctx 157k (16%) + sub 1× 17k = 174k | session $8.65 | today $12 · yest $9 · week $48 · lwk $63 · mon $210 · all $980 | 2026-01-01 14:19:05
```

*(numbers above are illustrative)*

## What each segment shows

| Segment | Meaning |
| --- | --- |
| `myproject` | Current directory (basename) |
| `main ✱ +42 -7` | Git branch · `✱` uncommitted · `↑/↓` ahead/behind upstream · lines added/removed this session |
| `Opus 4.8 1M high` | Model · context size · reasoning effort level |
| `5h 5% ↻4h30m · 7d 16% ↻3d18h` | Rate-limit windows: % used + time to reset. Color shifts green → yellow → red as you approach the cap |
| `ctx 157k (16%) + sub 1× 17k = 174k` | Main context-window fill (+%) **+** subagent windows **=** total. Subagents are separate windows, so they're shown as an addend, not folded into the main % |
| `session $8.65` | Cost of the current session (from Claude Code) |
| `today … all` | Cost bucketed by day/week/month/all-time, computed from your local transcripts |
| `2026-01-01 14:19:05` | Time of last render |

Segments hide themselves when their data isn't present (e.g. no subagents, not a git repo).

## Install

```bash
git clone https://github.com/hasher4ever/claude-statusline.git
cd claude-statusline
./install.sh
```

The installer copies `statusline.sh` and `cost-stats.py` into `~/.claude/`, adds a
`statusLine` block to `~/.claude/settings.json` (backing up the old one to
`settings.json.bak`), and builds the initial cost cache. Open a new session or
send a prompt to see it.

### Manual install

If you'd rather not run the script:

1. Copy `statusline.sh` and `cost-stats.py` into `~/.claude/`, then `chmod +x` both.
2. Add to `~/.claude/settings.json`:
   ```json
   "statusLine": { "type": "command", "command": "/ABSOLUTE/PATH/TO/.claude/statusline.sh" }
   ```
3. Run `python3 ~/.claude/cost-stats.py` once to seed the cache.

## How the cost numbers work

Claude Code only hands the status line the **current session's** cost. The
day/week/month/all-time totals are computed by `cost-stats.py`, which scans your
transcripts under `~/.claude/projects/**/*.jsonl`, sums each message's token
usage × model list price, and buckets it by local date into
`~/.claude/cost-cache.json`.

- The scan is **incremental**: each file is fingerprinted by mtime+size, so past
  days are never re-read — only the active session recomputes. Steady-state
  refreshes are near-instant.
- The status line reads the cache (fast) and triggers a **background** refresh
  only when it's older than 90s, so rendering never blocks.

> **Cost is estimated at API list prices** (Opus / Sonnet / Haiku per-token
> rates in `cost-stats.py`). If you're on a subscription (Pro / Max), this is
> **not your bill** — treat it as a usage-value meter. Edit the `PRICES` table
> in `cost-stats.py` to adjust rates.

## Requirements

- macOS or Linux
- `python3` (standard library only — no pip installs)
- `git` (for the branch/diff segment)
- A terminal with 256-color + UTF-8 support

## Customize

- **Colors / segments**: everything is in `statusline.sh`. Each segment is a
  `(plain, colored)` tuple appended to `seg`; reorder or drop them freely.
- **Rate-limit thresholds**: `load_color()` (green <50%, yellow <80%, red ≥80%).
- **Cost label/number format**: `money()` and the `labels` list.
- **Pricing**: the `PRICES` dict in `cost-stats.py`.

## Uninstall

Remove the `statusLine` block from `~/.claude/settings.json` (or restore
`settings.json.bak`), then delete `~/.claude/statusline.sh`,
`~/.claude/cost-stats.py`, and `~/.claude/cost-cache.json`.

## License

MIT
