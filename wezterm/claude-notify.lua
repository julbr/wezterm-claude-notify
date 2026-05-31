-- wezterm-claude-notify — color WezTerm tabs by Claude Code session state, and
-- make a clicked notification jump to the originating window's macOS Space + tab.
--
-- A companion script (bin/wezterm-claude-notify.sh), driven by Claude Code hooks, sets
-- a per-pane user var CLAUDE_STATUS to "ATTENTION", "DONE" or "" via an OSC 1337
-- SetUserVar escape sequence. This module reads that var in format-tab-title and
-- tints the tab. An alert auto-clears once you focus the tab (you've seen it).
--
-- CLICK-TO-FOCUS: when you click an attention toast, the helper writes another
-- user var (CLAUDE_FOCUS_REQUEST) to the originating pane's tty. This module
-- handles the `user-var-changed` event and calls pane:activate() + window:focus()
-- — which selects the originating tab, raises its OS window, and (because an app
-- focusing its own window makes macOS follow) switches to that window's macOS
-- Space. No Accessibility permission and no window-title tag required.
--
-- USAGE (most setups — no existing format-tab-title):
--   local claude = require 'claude-notify'
--   claude.apply(config)            -- optionally: claude.apply(config, { ... })
--
-- USAGE (you already have your own format-tab-title): compose manually —
--   local claude = require 'claude-notify'
--   wezterm.on('format-tab-title', function(tab, tabs, panes, conf, hover, max)
--     local d = claude.decorate(tab)        -- {prefix, bg, fg} or nil
--     local title = (d and d.prefix or '') .. tab.active_pane.title
--     local bg = d and d.bg or '#333333'
--     local fg = d and d.fg or '#cccccc'
--     return { {Background={Color=bg}}, {Foreground={Color=fg}}, {Text=' '..title..' '} }
--   end)
--   -- ...and, if you already handle user-var-changed yourself, also call:
--   wezterm.on('user-var-changed', function(window, pane, name, value)
--     claude.on_user_var(window, pane, name, value)  -- handles CLAUDE_FOCUS_REQUEST
--   end)
--
-- Options (all optional) for apply()/configure():
--   colors  = { attention = {bg=..., fg=...}, done = {bg=..., fg=...} }
--   prefix  = { attention = '⚠️ ', done = '✅ ' }
--   click_to_focus = true|false  -- handle CLAUDE_FOCUS_REQUEST to jump Space+tab
--   notification_handling = 'SuppressFromFocusedTab' | 'AlwaysShow' | ...
--       (only relevant if you fall back to WezTerm's native OSC toasts; the
--        terminal-notifier path used by default is unaffected by this.)

local wezterm = require 'wezterm'

local M = {}

-- The user var the helper writes (base64) when an attention toast is CLICKED.
-- Must stay in lockstep with bin/wezterm-claude-notify.sh, which sets the same name.
local FOCUS_VAR = 'CLAUDE_FOCUS_REQUEST'

local defaults = {
  colors = {
    attention = { bg = '#e06c75', fg = '#1e1e2e' }, -- red
    done      = { bg = '#98c379', fg = '#1e1e2e' }, -- green
  },
  prefix = {
    attention = '⚠️ REQUIRES INPUT - ',
    done      = '✅ DONE - ',
  },
  user_var = 'CLAUDE_STATUS',
  click_to_focus = true,
}

local opts = defaults

-- Per-pane record of the status last seen while the tab was focused. An alert is
-- only shown for a state you have NOT yet viewed, so once you switch to a flagged
-- tab the highlight clears on its own. (WezTerm's Lua can't set/clear user vars,
-- so acknowledgment is tracked on the display side.)
local acknowledged = {}

-- Merge user options over the defaults (shallow, per-subtable).
function M.configure(o)
  o = o or {}
  opts = {
    user_var = o.user_var or defaults.user_var,
    colors = {
      attention = (o.colors and o.colors.attention) or defaults.colors.attention,
      done      = (o.colors and o.colors.done)      or defaults.colors.done,
    },
    prefix = {
      attention = (o.prefix and o.prefix.attention) or defaults.prefix.attention,
      done      = (o.prefix and o.prefix.done)      or defaults.prefix.done,
    },
    -- explicit nil check so click_to_focus = false is honored (not coerced to true)
    click_to_focus = (o.click_to_focus == nil) and defaults.click_to_focus or o.click_to_focus,
    notification_handling = o.notification_handling,
  }
  return M
end

-- Returns { prefix, bg, fg } for the alert this tab should show, or nil if none.
-- Also updates the acknowledgment state. Safe to call from your own handler.
function M.decorate(tab)
  local pane = tab.active_pane
  if not pane then return nil end
  local status = pane.user_vars[opts.user_var]

  if tab.is_active then
    acknowledged[pane.pane_id] = status
  end

  local effective = status
  if acknowledged[pane.pane_id] == status then
    effective = nil
  end

  if effective == 'ATTENTION' then
    return { prefix = opts.prefix.attention, bg = opts.colors.attention.bg, fg = opts.colors.attention.fg }
  elseif effective == 'DONE' then
    return { prefix = opts.prefix.done, bg = opts.colors.done.bg, fg = opts.colors.done.fg }
  end
  return nil
end

-- Handle a user-var-changed event. When the helper's toast click writes
-- CLAUDE_FOCUS_REQUEST to a pane's tty, select that pane's tab and focus its
-- window — which raises the OS window and switches to its macOS Space. Every
-- other user var is ignored. pcall-guarded so a stale pane/window reference
-- never raises. Safe to call from your own user-var-changed handler.
function M.on_user_var(window, pane, name, value)
  if name ~= FOCUS_VAR then return end
  pcall(function() if pane then pane:activate() end end)      -- select the originating tab
  pcall(function() if window then window:focus() end end)     -- raise window + switch Space
end

-- Register standalone format-tab-title (tab tinting) and, unless disabled, a
-- user-var-changed handler (click-to-focus). format-tab-title returns nil when
-- there's no alert so WezTerm's default rendering (or another handler) wins.
function M.apply(config, o)
  if o then M.configure(o) end
  if opts.notification_handling and config and config.notification_handling == nil then
    config.notification_handling = opts.notification_handling
  end
  wezterm.on('format-tab-title', function(tab, tabs, panes, conf, hover, max_width)
    local d = M.decorate(tab)
    if not d then return nil end
    return {
      { Background = { Color = d.bg } },
      { Foreground = { Color = d.fg } },
      { Text = ' ' .. d.prefix .. tab.active_pane.title .. ' ' },
    }
  end)
  if opts.click_to_focus then
    wezterm.on('user-var-changed', M.on_user_var)
  end
  return M
end

return M
