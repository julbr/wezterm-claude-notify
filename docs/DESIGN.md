# Design notes & dead-ends

This setup looks simple but several "obvious" approaches silently do nothing.
This document records what works, what doesn't, and why — so you can debug or
extend it without rediscovering the traps.

## The data flow

```
Claude Code event (Notification / Stop / UserPromptSubmit)
        │  runs the configured hook command
        ▼
~/.claude/wezterm-claude-notify.sh  <STATUS> [message]
        │  ├─ looks up THIS pane's tty device   (via $WEZTERM_PANE + `wezterm cli list`)
        │  ├─ writes OSC 1337 SetUserVar=CLAUDE_STATUS=<base64> to that device
        │  └─ posts a terminal-notifier toast with a click → `wezterm cli activate-pane`
        ▼
WezTerm sets the pane user var → repaints the tab bar
        ▼
claude-notify.lua  format-tab-title  reads pane.user_vars.CLAUDE_STATUS → tints tab
```

## Trap 1 — A hook cannot just `printf` an escape sequence

The intuitive approach is to have the hook print the OSC sequence to stdout (or
`/dev/tty`). It does nothing, because:

- **As of Claude Code v2.1.139, command hooks run in their own session with no
  controlling terminal.** `tty` reports *not a tty*; opening `/dev/tty` fails
  with *device not configured*.
- **Hook stdout is captured by Claude Code** (parsed as JSON for hook control,
  otherwise routed to the debug log). It is never written to the terminal.
- Claude Code's `terminalSequence` hook-output field *can* emit a few escape
  sequences for you, but its allowlist is OSC 0/1/2, 9, 99, 777 and bare BEL —
  **OSC 1337 (SetUserVar) is explicitly rejected.**

**What works:** discover the pane's *device node* and write to it directly. The
pane's tty (e.g. `/dev/ttys003`) is a normal device file you have write
permission to; writing an OSC sequence to it is interpreted by WezTerm exactly
as if the program produced that output. We get the device from
`wezterm cli list --format json` keyed by `$WEZTERM_PANE` (the env var WezTerm
sets in every pane, inherited by the hook). `$WEZTERM_PANE` is reliable;
`/dev/tty` is not.

## Trap 2 — SetUserVar values must be base64-encoded

WezTerm's `OSC 1337 ; SetUserVar=NAME=VALUE` protocol requires **VALUE to be
base64-encoded**; WezTerm decodes it on receipt. Sending the literal text
`ATTENTION` makes WezTerm try to base64-*decode* "ATTENTION" → garbage/empty, so
`user_vars.CLAUDE_STATUS == 'ATTENTION'` is never true. You must send
`$(printf ATTENTION | base64)`; WezTerm stores the decoded `ATTENTION`.

The NAME is sent literally; only the VALUE is base64.

## Trap 3 — Hooks must live in settings.json, not ~/.claude.json

Claude Code reads hook definitions only from the settings hierarchy
(`~/.claude/settings.json`, `.claude/settings.json`,
`.claude/settings.local.json`, managed policy, plugin/skill frontmatter).
`~/.claude.json` is the legacy global *state* file (OAuth session, MCP servers,
per-project state, caches) — a top-level `hooks` key there is **silently
ignored**. The installer writes to `~/.claude/settings.json`.

## Trap 4 — `wezterm cli set-user-var` does not exist

It is tempting to look for a CLI that sets a user var directly. There isn't one
— not in any released WezTerm, and there is no `pane:set_user_var` Lua API
either. The only way to set a user var is to emit the OSC 1337 sequence
yourself. That's why the helper writes to the tty device.

## Why the tab clears on focus (and why it's done in Lua)

The complaint with a naive version: a tab flags red and **stays** red. The only
events that would reset it (`Stop`, `UserPromptSubmit`) require *you* to act, so
a tab you've merely glanced at stays flagged.

The fix has to live on the WezTerm side, but **WezTerm Lua can't set/clear user
vars** — so we can't "reset" the var from Lua. Instead `format-tab-title` keeps
a per-pane `acknowledged` table = the `CLAUDE_STATUS` value last seen *while the
tab was focused*. An alert is shown only for a state you have **not** yet viewed.
Switching to a flagged tab marks its state acknowledged (the active tab triggers
a repaint with `tab.is_active == true`), so when you switch away it renders
normally. A genuinely-new state (e.g. `ATTENTION → DONE`) differs from what you
acknowledged, so it re-alerts. The toast still fires regardless, so you never
miss a same-state repeat even though the tab won't re-tint for it.

Side note: the `user-var-changed` Lua event did **not** fire in the WezTerm
build this was developed against (20240203), but it's irrelevant —
`format-tab-title` reads `user_vars` directly and WezTerm repaints the tab bar
when a user var changes.

## Why terminal-notifier for the toast (click-to-focus)

OSC 9 and OSC 777 toasts carry only a title/body — **no click-action payload**.
Clicking a native WezTerm toast just foregrounds the app, not the originating
pane. (Native click-to-focus-pane was only added to WezTerm in a 2026 build via
PR #7643; older builds can't do it at all.)

`terminal-notifier` supports `-execute "<cmd>"`, run via `/bin/sh` when the
notification is clicked. We set it to
`wezterm cli activate-pane --pane-id N ; open -a WezTerm` so a click switches to
the right tab and foregrounds WezTerm. Gotchas baked into the helper:

- **`-sender` and `-execute` are mutually exclusive** — `-sender` (which would
  set the WezTerm icon) disables the click command. We use `-appIcon` for the
  icon instead.
- The clicked command runs with a **minimal PATH** → use absolute paths
  (`/Applications/WezTerm.app/.../wezterm`, `/usr/bin/open`).
- `-group "wezterm-claude-<pane>"` coalesces repeated alerts from the same
  session instead of stacking them.
- terminal-notifier is a separate app to macOS → it needs its **own**
  notification permission the first time.

`wezterm cli activate-pane` switches the tab/pane but does **not** raise a
specific OS *window*; `open -a WezTerm` foregrounds the app's frontmost window.
For sessions-as-tabs-in-one-window this lands correctly. True multi-window
raising would need AppleScript `AXRaise` by a unique window title (and an
Accessibility permission) — intentionally omitted to keep the common case
dependency-free.

## The tab number is a position, not an id

The toast shows `(⌘N)` where N is the **1-based tab position within the window**
— exactly what `cmd+N` activates. This is *not* WezTerm's internal `tab_id`
(which diverges from position as tabs are opened/closed). We compute it by
ranking the pane's `tab_id` among the window's tab ids. The click action uses
`--pane-id` (precise), while the displayed number uses position (human-friendly).

## Verifying changes

The pipeline is observable without guessing:

- `wezterm cli list --format json` shows each pane's `tty_name`, `title`,
  `window_id`, `tab_id`, `is_active`.
- To confirm a SetUserVar actually lands, temporarily log from `format-tab-title`
  (`io.open('/tmp/x.log','a')`) the value of `tab.active_pane.user_vars.CLAUDE_STATUS`.
- `terminal-notifier -list ALL` shows whether a toast was *delivered* (vs. just
  not displayed because permission is off).
