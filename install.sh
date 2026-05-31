#!/bin/bash
# wezterm-claude-notify installer (macOS).
#
# Idempotent: safe to re-run (e.g. after `git pull`). It MERGES into your
# existing Claude Code settings and never clobbers unrelated config.
#
# Flags:
#   --write-wezterm   append the `require`/`apply` lines to your wezterm.lua
#                     automatically (otherwise the snippet is just printed)
#   --no-notifier     skip installing terminal-notifier
#   -h, --help        show this help

set -euo pipefail

WRITE_WEZTERM=0
INSTALL_NOTIFIER=1
for arg in "$@"; do
  case "$arg" in
    --write-wezterm) WRITE_WEZTERM=1 ;;
    --no-notifier)   INSTALL_NOTIFIER=0 ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="$(command -v python3 || echo /usr/bin/python3)"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

[ "$(uname -s)" = "Darwin" ] || { warn "This installer targets macOS; other platforms are unsupported."; }

CLAUDE_DIR="$HOME/.claude"
HELPER_DEST="$CLAUDE_DIR/wezterm-claude-notify.sh"
SETTINGS="$CLAUDE_DIR/settings.json"
WEZTERM_DIR="${WEZTERM_CONFIG_DIR:-$HOME/.config/wezterm}"
WEZTERM_LUA="$WEZTERM_DIR/wezterm.lua"
MODULE_DEST="$WEZTERM_DIR/claude-notify.lua"

bold "wezterm-claude-notify — installing"

# 1) helper script -----------------------------------------------------------
mkdir -p "$CLAUDE_DIR"
install -m 0755 "$SCRIPT_DIR/bin/wezterm-status.sh" "$HELPER_DEST"
ok "helper -> $HELPER_DEST"

# 2) merge hooks into ~/.claude/settings.json (idempotent) -------------------
[ -f "$SETTINGS" ] && cp -p "$SETTINGS" "$SETTINGS.bak.$(date +%s)" 2>/dev/null || true
"$PYTHON" - "$SETTINGS" "$SCRIPT_DIR/claude/hooks.json" <<'PY'
import json, os, sys, tempfile
settings_path, hooks_path = sys.argv[1], sys.argv[2]
try:
    with open(settings_path) as f:
        txt = f.read().strip()
    settings = json.loads(txt) if txt else {}
except FileNotFoundError:
    settings = {}
with open(hooks_path) as f:
    frag = json.load(f)["hooks"]

settings.setdefault("hooks", {})
added = 0
for event, groups in frag.items():
    existing = settings["hooks"].setdefault(event, [])
    have = {h.get("command")
            for g in existing for h in g.get("hooks", [])
            if isinstance(h, dict)}
    for g in groups:
        cmds = {h.get("command") for h in g.get("hooks", [])}
        if cmds & have:
            continue  # already installed
        existing.append(g)
        added += 1

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(settings_path)))
with os.fdopen(fd, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
os.replace(tmp, settings_path)
print(f"  hooks merged ({added} added; events: {', '.join(frag)})")
PY
ok "Claude Code hooks -> $SETTINGS"

# 3) WezTerm Lua module ------------------------------------------------------
mkdir -p "$WEZTERM_DIR"
install -m 0644 "$SCRIPT_DIR/wezterm/claude-notify.lua" "$MODULE_DEST"
ok "WezTerm module -> $MODULE_DEST"

SNIPPET=$'-- wezterm-claude-notify\nlocal claude = require \'claude-notify\'\nclaude.apply(config)  -- place before `return config`'
if [ "$WRITE_WEZTERM" = "1" ] && [ -f "$WEZTERM_LUA" ]; then
  if grep -q "require 'claude-notify'" "$WEZTERM_LUA" || grep -q 'require "claude-notify"' "$WEZTERM_LUA"; then
    ok "wezterm.lua already requires claude-notify"
  elif grep -q '^return config' "$WEZTERM_LUA"; then
    # insert the require/apply just before the final `return config`
    "$PYTHON" - "$WEZTERM_LUA" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines()
out, done = [], False
for ln in lines:
    if not done and ln.strip() == "return config":
        out += ["-- wezterm-claude-notify",
                "local claude = require 'claude-notify'",
                "claude.apply(config)",
                ""]
        done = True
    out.append(ln)
open(p, "w").write("\n".join(out) + "\n")
PY
    ok "wezterm.lua updated (added require/apply before \`return config\`)"
  else
    warn "Couldn't find \`return config\` in wezterm.lua — add these lines yourself:"
    printf '%s\n' "$SNIPPET" | sed 's/^/      /'
  fi
else
  warn "Add these lines to $WEZTERM_LUA (before \`return config\`):"
  printf '%s\n' "$SNIPPET" | sed 's/^/      /'
fi

# 4) terminal-notifier (clickable toasts) ------------------------------------
if [ "$INSTALL_NOTIFIER" = "1" ]; then
  if command -v terminal-notifier >/dev/null 2>&1; then
    ok "terminal-notifier present"
  elif command -v brew >/dev/null 2>&1; then
    echo "  installing terminal-notifier via Homebrew..."
    HOMEBREW_NO_AUTO_UPDATE=1 brew install terminal-notifier >/dev/null 2>&1 \
      && ok "terminal-notifier installed" \
      || warn "brew install failed — toasts will use non-clickable OSC 777 fallback"
  else
    warn "terminal-notifier missing and Homebrew unavailable."
    warn "Install for clickable toasts:  brew install terminal-notifier"
  fi
fi

echo
bold "Almost done — two manual steps:"
echo "  1. Grant notification permission to terminal-notifier the FIRST time it fires:"
echo "     System Settings → Notifications → terminal-notifier → Allow Notifications."
echo "  2. Reload config: Claude Code hot-reloads settings.json; WezTerm auto-reloads"
echo "     wezterm.lua. (A fresh WezTerm tab is the cleanest.)"
echo
echo "Click-to-Space needs NO Accessibility permission. It does rely on the macOS"
echo "default 'switch to a Space with open windows for the application' staying ON"
echo "(System Settings → Desktop & Dock → Mission Control). Set WCN_FOCUS=0 to opt out."
echo
echo "Verify with:  /hooks   (inside Claude Code — should list Notification/Stop/UserPromptSubmit)"
