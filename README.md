# wezterm-claude-notify

Know which of your parallel **Claude Code** sessions needs you — without
staring at tabs. Each [WezTerm](https://wezterm.org) tab tints itself by the
state of the Claude Code session running in it, and you get a **clickable**
macOS notification that jumps straight to the right tab.

```
┌──────────────────────────────────────────────────────────────┐
│  api-server     ⚠️ REQUIRES INPUT - web-ui      ✅ DONE - infra │   ← tab bar
└──────────────────────────────────────────────────────────────┘
        ▲ working           ▲ needs you (red)        ▲ finished (green)
```

| Claude Code event | Tab becomes | Toast? |
|-------------------|-------------|--------|
| needs input / permission prompt (`Notification`) | 🔴 red "REQUIRES INPUT" | yes, clickable |
| finished its turn (`Stop`)                        | 🟢 green "DONE"          | no |
| you send a new prompt (`UserPromptSubmit`)        | normal (cleared)         | no |

An alert **auto-clears once you focus that tab** (you've seen it), so colors
don't pile up. Notifications say *which* project and tab — e.g.
**"Claude needs input: web-ui — ✳ Refactor auth (⌘2)"** — and clicking one
brings WezTerm forward and switches to that exact tab.

## Requirements

- macOS
- [WezTerm](https://wezterm.org)
- [Claude Code](https://www.claude.com/product/claude-code) **v2.1.139+**
- `python3` (ships with macOS Command Line Tools)
- [`terminal-notifier`](https://github.com/julienXX/terminal-notifier) for
  *clickable* toasts (`brew install terminal-notifier`). Optional — without it,
  toasts fall back to WezTerm's native (non-clickable) notification.

## Install

```sh
git clone https://github.com/julbr/wezterm-claude-notify.git
cd wezterm-claude-notify
./install.sh                 # or: ./install.sh --write-wezterm
```

The installer (idempotent — safe to re-run after `git pull`):

1. copies the hook helper to `~/.claude/wezterm-claude-notify.sh`
2. **merges** three hooks into `~/.claude/settings.json` (your other settings
   are preserved; a timestamped backup is made)
3. installs the WezTerm module to `~/.config/wezterm/claude-notify.lua`
4. installs `terminal-notifier` via Homebrew if missing

Then add two lines to your `wezterm.lua` (or pass `--write-wezterm` to let the
installer do it):

```lua
local claude = require 'claude-notify'
claude.apply(config)   -- place before `return config`
```

**Two manual steps the installer can't do for you:**

- The first time a toast fires, macOS needs you to allow it:
  **System Settings → Notifications → terminal-notifier → Allow Notifications.**
- Reload config — Claude Code hot-reloads `settings.json`, WezTerm auto-reloads
  `wezterm.lua`. A fresh WezTerm tab is cleanest. Run `/hooks` in Claude Code to
  confirm the three hooks are registered.

## Configuration

Pass options to `apply` (all optional):

```lua
claude.apply(config, {
  colors = {
    attention = { bg = '#e06c75', fg = '#1e1e2e' },  -- red
    done      = { bg = '#98c379', fg = '#1e1e2e' },  -- green
  },
  prefix = { attention = '⚠️ ', done = '✅ ' },
})
```

**Already have your own `format-tab-title`?** Compose instead of replacing:

```lua
local claude = require 'claude-notify'
wezterm.on('format-tab-title', function(tab, tabs, panes, conf, hover, max)
  local d = claude.decorate(tab)            -- {prefix, bg, fg} or nil
  local title = (d and d.prefix or '') .. tab.active_pane.title
  return {
    { Background = { Color = d and d.bg or '#333' } },
    { Foreground = { Color = d and d.fg or '#ccc' } },
    { Text = ' ' .. title .. ' ' },
  }
end)
```

Helper env vars: `WCN_TOAST=0` disables toasts (tab coloring still works);
`WCN_NOTIFIER=/path/to/terminal-notifier` forces a specific binary.

## How it works (short version)

Claude Code hooks fire `wezterm-claude-notify.sh`, which sets a per-pane WezTerm
user var `CLAUDE_STATUS` (via an OSC 1337 *SetUserVar* escape sequence written
**directly to the pane's tty device**) and posts a `terminal-notifier` toast
whose click action runs `wezterm cli activate-pane`. The Lua module reads
`CLAUDE_STATUS` in `format-tab-title` and tints the tab.

It's less obvious than it sounds — Claude Code hooks have no controlling
terminal, WezTerm requires the user-var value to be base64-encoded, and OSC
notifications can't carry a click target. See [docs/DESIGN.md](docs/DESIGN.md)
for the full rationale and the dead-ends to avoid.

## Troubleshooting

- **No tab colors:** confirm `claude.apply(config)` runs (and is before
  `return config`); run `/hooks` to confirm hooks are registered; make sure the
  hooks live in `settings.json`, **not** `~/.claude.json` (the latter is ignored
  for hooks).
- **No toast banner, but it's "delivered":** allow terminal-notifier in System
  Settings → Notifications.
- **Wrong tab number in the toast:** the number is the 1-based *position*
  (what `⌘N` reaches), computed per window.
- **Multiple windows:** clicking reliably switches the tab and foregrounds the
  app; raising a *specific background window* across several windows needs an
  extra AppleScript step (not included — most setups run sessions as tabs in one
  window). Open an issue if you need it.

## Uninstall

```sh
./uninstall.sh    # removes helper + hooks + module; leaves terminal-notifier
```

## License

MIT © Julien Brinas. See [LICENSE](LICENSE).
