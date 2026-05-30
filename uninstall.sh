#!/bin/bash
# wezterm-claude-notify uninstaller — removes only what install.sh added.
# Leaves terminal-notifier installed (it may be used by other tools).

set -euo pipefail
PYTHON="$(command -v python3 || echo /usr/bin/python3)"
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }

CLAUDE_DIR="$HOME/.claude"
HELPER="$CLAUDE_DIR/wezterm-claude-notify.sh"
SETTINGS="$CLAUDE_DIR/settings.json"
WEZTERM_DIR="${WEZTERM_CONFIG_DIR:-$HOME/.config/wezterm}"
MODULE="$WEZTERM_DIR/claude-notify.lua"
WEZTERM_LUA="$WEZTERM_DIR/wezterm.lua"

printf '\033[1m%s\033[0m\n' "wezterm-claude-notify — uninstalling"

rm -f "$HELPER" && ok "removed $HELPER"
rm -f "$MODULE" && ok "removed $MODULE"

# Strip our hooks (any whose command points at the helper) from settings.json.
if [ -f "$SETTINGS" ]; then
  cp -p "$SETTINGS" "$SETTINGS.bak.$(date +%s)" 2>/dev/null || true
  "$PYTHON" - "$SETTINGS" <<'PY'
import json, os, sys, tempfile
p = sys.argv[1]
with open(p) as f:
    s = json.load(f)
hooks = s.get("hooks", {})
needle = "wezterm-claude-notify.sh"
for event in list(hooks.keys()):
    groups = []
    for g in hooks[event]:
        g["hooks"] = [h for h in g.get("hooks", []) if needle not in (h.get("command") or "")]
        if g["hooks"]:
            groups.append(g)
    if groups:
        hooks[event] = groups
    else:
        del hooks[event]
if not hooks:
    s.pop("hooks", None)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(p)))
with os.fdopen(fd, "w") as f:
    json.dump(s, f, indent=2); f.write("\n")
os.replace(tmp, p)
PY
  ok "removed hooks from $SETTINGS"
fi

echo
echo "Manual: remove the 'require \"claude-notify\"' / 'claude.apply(config)' lines"
echo "        from $WEZTERM_LUA if you added them."
echo "(terminal-notifier left installed; remove with: brew uninstall terminal-notifier)"
