# wezterm-claude-notify

Know which of your parallel **Claude Code** sessions needs you — without
staring at tabs. Each [WezTerm](https://wezterm.org) tab tints itself by the
state of the Claude Code session running in it, and you get a **clickable**
macOS notification that jumps straight to the right tab.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  [api] run tests    ⚠️ REQUIRES INPUT - [web] add nav    ✅ DONE - [infra] deploy │  ← tab bar
└──────────────────────────────────────────────────────────────────────────────┘
        ▲ working               ▲ needs you (red)            ▲ finished (green)
```

Each tab also gets a **folder-aware title**: a Claude Code tab is prefixed with
the project it runs in — `[api] run tests` — and a plain shell tab shows its
working-directory name instead of `zsh` or a blank.

| Claude Code event | Tab becomes | Toast? |
|-------------------|-------------|--------|
| needs input / permission prompt (`Notification`) | 🔴 red "REQUIRES INPUT" | yes, clickable |
| finished its turn (`Stop`)                        | 🟢 green "DONE"          | no |
| you send a new prompt (`UserPromptSubmit`)        | normal (cleared)         | no |

> The `Notification` row covers genuine input/permission prompts only. Claude
> Code's *non-input* notifications — idle *"waiting for your next prompt"* (which
> fires on any quiet session ~60 s after it goes idle, including a fresh
> `/clear`), auth success, and completed MCP forms — are filtered out by
> `notification_type`, so an idle tab never turns red on its own.

An alert **auto-clears once you focus that tab** (you've seen it), so colors
don't pile up. Notifications say *which* project and tab — e.g.
**"Claude needs input: web-ui — ✳ Refactor auth (⌘2)"** — and clicking one
**jumps to the macOS Space holding that window**, raises that exact window, and
selects that tab — even with several WezTerm windows spread across Spaces. No
extra macOS permission required.

**Folder-aware tab titles.** Every tab gets a useful title even with no alert
active: a tab at a plain shell shows its **working-directory name** (instead of
`zsh` or a blank), and a Claude Code tab — whose title is the task it's working
on — is **prefixed with that folder**, e.g. `[wisp] Add search to the UI`, so you
can tell parallel sessions apart at a glance. A tab you've **renamed yourself**
(rename UI or `wezterm cli set-tab-title`) keeps its name (an active alert still
tints it). Turn the whole thing off with `show_folder = false` — tabs then render
as WezTerm would by default, leaving only the alert tinting.

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

1. The first time a toast fires, macOS needs you to allow it:
   **System Settings → Notifications → terminal-notifier → Allow Notifications.**
2. Reload config — Claude Code hot-reloads `settings.json`, WezTerm auto-reloads
   `wezterm.lua`. A fresh WezTerm tab is cleanest. Run `/hooks` in Claude Code to
   confirm the three hooks are registered.

That's it — **no Accessibility permission is needed**. Click-to-Space works by
having WezTerm focus its own window (which makes macOS follow to that window's
Space); see [How it works](#how-it-works-short-version). For this, macOS's
*"When switching to an application, switch to a Space with open windows"*
(Desktop & Dock → Mission Control) must stay **on** — it is on by default.

## Configuration

Pass options to `apply` (all optional):

```lua
claude.apply(config, {
  colors = {
    attention = { bg = '#e06c75', fg = '#1e1e2e' },  -- red
    done      = { bg = '#98c379', fg = '#1e1e2e' },  -- green
  },
  prefix = { attention = '⚠️ ', done = '✅ ' },
  show_folder   = true,     -- folder-aware tab titles: bare shells show the cwd
                            -- folder name; Claude tabs are prefixed "[folder] "
  folder_format = '[%s] ',  -- string.format template for that prefix (%s = folder)
  click_to_focus = true,  -- handle CLAUDE_FOCUS_REQUEST so a toast click jumps to
                          -- the originating window's Space + tab (set false to
                          -- opt out of registering the user-var-changed handler)
  agents_status = true,   -- show background / `claude agents` workers that are
                          -- awaiting your input in the right status bar (see below)
  agents_status_interval = 3,         -- seconds between polls of the daemon state
  agents_status_max      = 4,         -- max names to list before "· +N more"
  agents_status_color    = '#e5c07b', -- color of the status text (amber by default)
})
```

### Agents awaiting-input status

A background task or a `claude agents` worker runs **detached** — it has no pane
of its own (it inherited a frozen `$WEZTERM_PANE` from whatever launched it), so
its "needs input" toast can't reliably focus a tab and its tab can't be tinted:
there is no correct tab to point at. Instead, this module surfaces that state
where it *is* reliable. The Claude daemon writes each worker's status to
`~/.claude/jobs/<id>/state.json` in real time — flipping `state` to `"blocked"`
the moment a worker awaits you — so the module polls those files (gated by the
live `~/.claude/daemon/roster.json`, so finished jobs never count) and lists the
blocked workers **by name** in the right status bar of every window:

```
⏳ 2 agents need input · teleport-migration · monorepo-rules
```

It's pane-independent: immune to the stale-pane problem, to having several
`claude agents` UIs open, and to tab renames. The status clears when nothing is
waiting. Set `agents_status = false` to turn it off.

**Already drive `update-status` yourself?** Set `agents_status = false` and fold
the string into your own handler:

```lua
wezterm.on('update-status', function(window, pane)
  local agents = claude.agents_status_text()      -- '' when none are waiting
  -- ...combine `agents` with your own right-status content...
  window:set_right_status(agents)
end)
```

**Already have your own `format-tab-title`?** Compose instead of replacing:

```lua
local claude = require 'claude-notify'
wezterm.on('format-tab-title', function(tab, tabs, panes, conf, hover, max)
  local d = claude.decorate(tab)            -- {prefix, bg, fg} or nil
  local base = claude.title(tab)            -- folder-aware base title ('' if nothing)
  if not d and base == '' then return nil end          -- let WezTerm's default win
  local title = (d and d.prefix or '') .. base
  return {
    { Background = { Color = d and d.bg or '#333' } },
    { Foreground = { Color = d and d.fg or '#ccc' } },
    { Text = ' ' .. title .. ' ' },
  }
end)
```

**Already have your own `user-var-changed` handler?** Set `click_to_focus = false`
so `apply()` doesn't register a second one, and call the module's handler from
yours:

```lua
wezterm.on('user-var-changed', function(window, pane, name, value)
  claude.on_user_var(window, pane, name, value)  -- acts only on CLAUDE_FOCUS_REQUEST
  -- ...your own var handling here...
end)
```

Helper env vars: `WCN_TOAST=0` disables toasts (tab coloring still works);
`WCN_NOTIFIER=/path/to/terminal-notifier` forces a specific binary;
`WCN_FOCUS=0` makes a click only foreground WezTerm + select the tab, skipping
the Space/window jump (for older WezTerm without the `user-var-changed` event).

## How it works (short version)

Claude Code hooks fire `wezterm-claude-notify.sh`, which sets a per-pane WezTerm
user var `CLAUDE_STATUS` (via an OSC 1337 *SetUserVar* escape sequence written
**directly to the pane's tty device**) and posts a `terminal-notifier` toast.
The Lua module reads `CLAUDE_STATUS` in `format-tab-title` and tints the tab.

The toast's click action foregrounds WezTerm (`open -a WezTerm`) and then writes
a second user var, `CLAUDE_FOCUS_REQUEST`, to the originating pane's tty. WezTerm
fires its `user-var-changed` event, and the Lua module responds with
`pane:activate()` + `window:focus()`: this selects the originating tab, raises
its OS window, and — because an app focusing its own window makes macOS follow —
**switches to that window's Space**. WezTerm does the cross-Space move itself, so
no Accessibility permission is needed.

It's less obvious than it sounds — Claude Code hooks have no controlling
terminal, WezTerm requires the user-var value to be base64-encoded, OSC
notifications can't carry a click target, and `wezterm cli` can neither raise a
GUI window nor switch Spaces. See [docs/DESIGN.md](docs/DESIGN.md) for the full
rationale and the dead-ends to avoid.

## Troubleshooting

- **No tab colors:** confirm `claude.apply(config)` runs (and is before
  `return config`); run `/hooks` to confirm hooks are registered; make sure the
  hooks live in `settings.json`, **not** `~/.claude.json` (the latter is ignored
  for hooks).
- **No toast banner, but it's "delivered":** allow terminal-notifier in System
  Settings → Notifications.
- **Wrong tab number in the toast:** the number is the 1-based *position*
  (what `⌘N` reaches), computed per window.
- **Click foregrounds WezTerm but doesn't switch Space / select the tab:** make
  sure `claude.apply(config)` is loaded (it registers the `user-var-changed`
  handler) and `click_to_focus` isn't `false`; if you have your own
  `user-var-changed` handler, call `claude.on_user_var(...)` from it (see
  [Configuration](#configuration)). On very old WezTerm builds without the
  `user-var-changed` event, set `WCN_FOCUS=0` for the foreground + tab-select
  fallback.
- **Click doesn't switch Space at all:** macOS's *"When switching to an
  application, switch to a Space with open windows for the application"* must stay
  **on** (Desktop & Dock → Mission Control; it's the default). No supported API
  can switch Spaces if it's off.

## Uninstall

```sh
./uninstall.sh    # removes helper + hooks + module; leaves terminal-notifier
```

## License

MIT © Julien Brinas. See [LICENSE](LICENSE).
