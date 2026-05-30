#!/bin/bash
# Installer for the Claude Code status line.
# Copies the two scripts into ~/.claude/, wires up settings.json, and builds the
# initial cost cache. Safe to re-run (idempotent). Backs up settings.json first.
set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude"
PY="$(command -v python3 || echo /usr/bin/python3)"

mkdir -p "$DEST"
cp "$SRC/statusline.sh" "$DEST/statusline.sh"
cp "$SRC/cost-stats.py" "$DEST/cost-stats.py"
chmod +x "$DEST/statusline.sh" "$DEST/cost-stats.py"
echo "✓ installed statusline.sh + cost-stats.py to $DEST"

SETTINGS="$DEST/settings.json"
[ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak" && echo "✓ backed up settings.json -> settings.json.bak"

# Merge the statusLine block into settings.json (create the file if absent).
"$PY" - "$SETTINGS" "$DEST/statusline.sh" <<'PYEOF'
import json, os, sys
settings_path, script_path = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(settings_path):
    try:
        with open(settings_path) as f:
            data = json.load(f)
    except Exception:
        print("! settings.json is not valid JSON — leaving it untouched.")
        print("  Add this manually:")
        print('  "statusLine": {"type": "command", "command": "%s"}' % script_path)
        sys.exit(0)
data["statusLine"] = {"type": "command", "command": script_path}
with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
print("✓ wired statusLine into settings.json")
PYEOF

# Build the initial cost cache (one-time scan of ~/.claude/projects transcripts).
echo "… building initial cost cache (one-time, may take a few seconds)"
"$PY" "$DEST/cost-stats.py" || true
echo "✓ done. Open a new Claude Code session (or send a prompt) to see the status line."
