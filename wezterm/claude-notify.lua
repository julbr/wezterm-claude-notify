-- wezterm-claude-notify — color WezTerm tabs by Claude Code session state.
--
-- A companion script (bin/wezterm-status.sh), driven by Claude Code hooks, sets
-- a per-pane user var CLAUDE_STATUS to "ATTENTION", "DONE" or "" via an OSC 1337
-- SetUserVar escape sequence. This module reads that var in format-tab-title and
-- tints the tab. An alert auto-clears once you focus the tab (you've seen it).
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
--
-- Options (all optional) for apply()/configure():
--   colors  = { attention = {bg=..., fg=...}, done = {bg=..., fg=...} }
--   prefix  = { attention = '⚠️ ', done = '✅ ' }
--   notification_handling = 'SuppressFromFocusedTab' | 'AlwaysShow' | ...
--       (only relevant if you fall back to WezTerm's native OSC toasts; the
--        terminal-notifier path used by default is unaffected by this.)

local wezterm = require 'wezterm'

local M = {}

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

-- Register a standalone format-tab-title handler. Returns the tab's normal title
-- (with an alert prefix) only when there's an alert to show; otherwise returns
-- nil so WezTerm's default rendering (or another handler) takes over.
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
  return M
end

return M
