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
        │  ├─ looks up THIS pane's tty device (via $WEZTERM_PANE + `wezterm cli list`)
        │  ├─ writes OSC 1337 SetUserVar=CLAUDE_STATUS=<base64> to that device
        │  └─ posts a terminal-notifier toast whose click → open WezTerm + write CLAUDE_FOCUS_REQUEST to the pane's tty
        ▼
WezTerm sets the pane user var → repaints the tab bar
        ▼
claude-notify.lua  format-tab-title  reads pane.user_vars.CLAUDE_STATUS → tints tab

When the toast is CLICKED (separate flow, runs under /bin/sh, minimal PATH):
        /usr/bin/open -a WezTerm                              (foreground WezTerm over the current app)
        wezterm cli activate-pane --pane-id N                 (Mux tab select; also the old-build fallback)
        printf OSC SetUserVar=CLAUDE_FOCUS_REQUEST > <tty>    (the pane's tty)
        ▼
claude-notify.lua  user-var-changed  → pane:activate() + window:focus()
        → selects the tab, raises the OS window, and (an app focusing its own
          window makes macOS follow) switches to that window's macOS Space
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

## Trap 5 — Not every `Notification` means "needs you"

Claude Code's `Notification` hook fires for six `notification_type`s, and most
don't need you: `idle_prompt` (Claude has gone quiet — "waiting for your next
prompt"), `auth_success` (a login succeeded), and `elicitation_complete` /
`elicitation_response` (an MCP form was already answered). `idle_prompt` is the
worst offender — it fires on *any* session ~60 s after it goes idle, **including
one you just `/clear`ed and walked away from** — so mapping every Notification to
`ATTENTION` paints an idle, empty tab red "REQUIRES INPUT" with nothing actually
needing you (and flips a finished green tab back to red a minute after `Stop`).
Only `permission_prompt` and `elicitation_dialog` are genuine input requests.

The fix is data-driven, not matcher-driven: the helper reads the hook's JSON
event from **stdin** (Claude Code delivers it there), extracts
`notification_type`, and bails on the known non-input set above. Three things
keep this from misfiring:

- stdin is read **only** for the `ATTENTION` invocation (the `Stop`/`UserPromptSubmit`
  paths never touch it), with a **bounded** `read -r -d '' -t 1` rather than an
  unbounded `cat`: Claude Code closes stdin right after the event so the read
  returns at once, but the 1 s cap means a caller that delivers the event yet
  *holds stdin open* can never hang the hook. (We also skip the read on an
  interactive tty, which carries no payload to wait for.)
- a deny**list**, not an allowlist: an empty/unparseable payload, a Claude Code
  too old to carry `notification_type`, or any *unknown/future* type all fall
  through to the alert — *fail visible*, never silently swallow a real prompt.
  The cost of a miss is at most one spurious red tab, never a missed one — which
  is why we list what to *drop*, not what to *keep*.
- the bail happens before the `wezterm cli list` query, so a suppressed ping
  costs almost nothing.

We filter in the script rather than narrowing the hook `matcher` so the policy
lives in one place, survives any future notification_type, and degrades safely
on builds that don't populate the field.

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

Side note: tab *coloring* doesn't rely on the `user-var-changed` event at all —
`format-tab-title` reads `user_vars` directly and WezTerm repaints the tab bar
when a user var changes. (The `user-var-changed` event *does* fire on this build,
20240203 — verified empirically; it's the basis of click-to-focus below. An
earlier draft of these notes claimed it didn't fire; that was wrong.)

## Why terminal-notifier for the toast (click-to-focus)

OSC 9 and OSC 777 toasts carry only a title/body — **no click-action payload**.
Clicking a native WezTerm toast just foregrounds the app, not the originating
pane. (Native click-to-focus-pane was only added to WezTerm in a 2026 build via
PR #7643; older builds can't do it at all.)

`terminal-notifier` supports `-execute "<cmd>"`, run via `/bin/sh` when the
notification is clicked. We use it to foreground WezTerm and hand a focus request
back to WezTerm itself (see *Click-to-Space navigation* below). Gotchas baked
into the helper:

- **`-sender` and `-execute` are mutually exclusive** — `-sender` (which would
  set the WezTerm icon) disables the click command. We use `-appIcon` for the
  icon instead.
- The clicked command runs with a **minimal PATH** (and an empty `LANG`) → use
  absolute paths (`/Applications/WezTerm.app/.../wezterm`, `/usr/bin/open`).
- `-group "wezterm-claude-<pane>"` coalesces repeated alerts from the same
  session instead of stacking them.
- terminal-notifier is a separate app to macOS → it needs its **own**
  notification permission the first time.

## Click-to-Space navigation (and its dead-ends)

The goal: clicking a toast should land you on the macOS **Space** that holds the
window that fired it, raise *that* window (you may have several WezTerm windows
spread across Spaces), and select the tab. The shipped solution lets **WezTerm
focus its own window** — but only after ruling out the obvious approaches, which
were all verified dead on this build (20240203):

- **`wezterm cli activate-pane` / `activate-tab` are Mux-level only.** Verified
  live: activating a pane in a window on another Space left `list-clients`
  `focused_pane_id` unchanged and did not switch Space (WezTerm issue #3542). They
  *do* select the tab within the Mux, which is still useful (see below).
- **No `wezterm cli` command raises a GUI window** (`activate-window`, #3542, is
  unimplemented), and **`set-window-title` is a no-op on macOS** here (#4899).
- **AppleScript `AXRaise` can't reach an off-Space window.** System Events only
  enumerates windows on the *current* Space; a window on another Space has an
  **empty AXTitle** and isn't selectable, so `first window whose name contains …`
  returns nothing (`-1719`). `AXRaise` also can't switch Spaces by itself (that
  lives in Dock.app/SkyLight). So "activate the app, then AXRaise the target by a
  title tag" only works when the target already happens to be on the Space the
  app-activation landed on — exactly the multi-window case we need to solve. Dead
  end (an earlier version of this project shipped it; live testing showed it
  fails for the real scenario).

**What works: WezTerm's own `window:focus()`, triggered via `user-var-changed`.**
An app focusing *its own* window makes macOS follow to that window's Space — no
Accessibility needed. We just need to get a shell click to call Lua, and the
bridge is the one we already use for tab color: writing an OSC 1337 SetUserVar to
the pane's tty. So the click's `-execute` is:

```sh
/usr/bin/open -a WezTerm \
; <wezterm> cli activate-pane --pane-id N >/dev/null 2>&1 \
; /bin/sleep 0.25 \
; printf '\033]1337;SetUserVar=CLAUDE_FOCUS_REQUEST=MQ==\007' > <tty>
```

and `claude-notify.lua` handles it:

```lua
wezterm.on('user-var-changed', function(window, pane, name, value)
  if name == 'CLAUDE_FOCUS_REQUEST' then
    pcall(function() pane:activate() end)   -- select the originating tab
    pcall(function() window:focus() end)    -- raise window + switch Space
  end
end)
```

Why each piece, and the traps (all verified live on 20240203):

1. **`open -a WezTerm` is required for the cross-*app* case.** When you click a
   toast you're usually in another app. `window:focus()` updates WezTerm's focused
   window but does **not** pull WezTerm in front of another app on its own
   (verified: from Finder, the var-write moved `focused_pane_id` but left Finder
   frontmost). `open -a WezTerm` foregrounds WezTerm; then `window:focus()` does
   the within-WezTerm cross-Space move.

2. **The `sleep` matters.** `window:focus()` only switches Space when WezTerm is
   already frontmost. The 0.25 s lets `open -a` win the foreground before the var
   write fires `user-var-changed`. Too short and you can land on the wrong Space.

3. **`user-var-changed` fires on *every* SetUserVar receipt — even an unchanged
   value** (verified: writing `MQ==` twice fired twice). So the value is arbitrary
   (`MQ==` = base64 "1"); a constant re-fires on every click. No per-click nonce
   needed.

4. **`pane:activate()` selects the originating tab** even when it isn't the
   window's active tab (verified: triggering on a background pane switched the
   window's active tab to it). `window:focus()` then raises the window and follows
   to its Space.

5. **Graceful degradation.** On a build where `user-var-changed` doesn't fire, the
   var write is simply a no-op and the preceding `open -a` + `activate-pane` still
   foreground WezTerm and select the tab — the old behavior. `WCN_FOCUS=0` forces
   that path explicitly.

6. **No Accessibility permission, no window-title tag.** Because WezTerm moves its
   own window, we avoid both the TCC grant and polluting window titles with a
   lookup tag — the two costs of the AXRaise dead end above.

The one remaining dependency is the macOS Dock setting **"When switching to an
application, switch to a Space with open windows for the application"**
(`workspaces-auto-swoosh`, **on** by default). With it off, `window:focus()` can
still update focus but macOS won't follow to the Space, and no supported API can
force it (only private, SIP-gated SkyLight/CGS calls — rejected).

## The tab number is a position, not an id

The toast shows `(⌘N)` where N is the **1-based tab position within the window**
— exactly what `cmd+N` activates. This is *not* WezTerm's internal `tab_id`
(which diverges from position as tabs are opened/closed). We compute it by
ranking the pane's `tab_id` among the window's tab ids. The click action uses
`--pane-id` (precise), while the displayed number uses position (human-friendly).

## Folder-aware tab titles

Two related needs, one mechanism. A tab sitting at a bare shell has no useful
pane title (it's empty, or just the shell's process name like `zsh`); a Claude
Code tab sets its title to the **task it's working on**, but with several
sessions open you can't tell which project each belongs to. `format-tab-title`
(and the public `claude.title(tab)` helper) fill both in from the pane's working
directory, in this precedence:

1. **explicit tab rename** (`tab.tab_title`, set via the rename UI or
   `wezterm cli set-tab-title`) → shown as-is; the user asked for it. (An active
   alert still prepends its prefix and tints the tab — only the *title* is theirs.)
2. **bare title** (empty, or a known shell name) → the cwd folder name (`wisp`).
3. **anything else** (a real title) → prefix it with the folder
   (`[wisp] Add search …`).

With `show_folder = false` the whole title path is skipped: a non-alert tab
returns `nil` from the handler, so WezTerm renders its default and only the
alert tinting remains.

We don't try to detect "is this Claude Code". Anything that sets a real pane
title (Claude, vim, a custom prompt) gets the `[folder]` prefix; a plain shell
gets the folder as its title. Both are useful, so the simple rule wins. Two
deliberate choices: we keep a small allow-list of shell process names
(`zsh`/`bash`/`fish`/…) so a default shell that titles itself `zsh` still shows
the folder, not `[folder] zsh`; and we don't strip Claude's leading spinner
glyph before prefixing — it's version-specific and harmless: `[wisp] ⠐ Add …`.

The folder comes from `PaneInformation.current_working_dir`, which WezTerm
populates from **OSC 7** (your shell — and Claude Code — emit it). Two
cross-build traps the helper absorbs:

- **It changed type.** Before 20240127 it was a `file://` **string**; since
  20240127 it's a **Url object** (read `.file_path`). `folder_name()` handles
  both, plus a `tostring()` + string-parse fallback for a non-`file` scheme or a
  build where `.file_path` is unavailable.
- **It can be nil.** A shell that doesn't emit OSC 7 reports no cwd; then there's
  no folder and the title falls back to the pane title (or WezTerm's default).

The non-alert path returns the title as a **plain string**, not a colored
`{Background=…}` list, so a normal tab keeps your theme's active/inactive tab
colors — only an actual alert overrides them.

## Verifying changes

The pipeline is observable without guessing:

- `wezterm cli list --format json` shows each pane's `tty_name`, `title`,
  `window_id`, `tab_id`, `is_active`. `wezterm cli list-clients --format json`
  shows the GUI's live `focused_pane_id` — the signal for whether a focus request
  actually moved the GUI (the Mux `is_active` does not reflect GUI focus).
- To confirm a SetUserVar actually lands, temporarily log from `format-tab-title`
  (`io.open('/tmp/x.log','a')`) the value of `tab.active_pane.user_vars.CLAUDE_STATUS`.
- `terminal-notifier -list ALL` shows whether a toast was *delivered* (vs. just
  not displayed because permission is off).
- To test click-to-focus without clicking: find the target pane's tty
  (`wezterm cli list`), then `printf '\033]1337;SetUserVar=CLAUDE_FOCUS_REQUEST=MQ==\007' > /dev/ttysNNN`.
  Watch `focused_pane_id` move to that pane. To exercise the full cross-app path,
  `open -a` another app first, then run the click's exact `-execute` string via
  `/bin/sh -c`. Note: macOS Space/window state is genuinely flaky to observe while
  you're actively switching Spaces — read `focused_pane_id` as the ground truth,
  and judge the user-facing result by clicking a real toast.
