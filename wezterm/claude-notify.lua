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
--     local base = claude.title(tab)        -- folder-aware base title ('' if nothing)
--     if not d and base == '' then return nil end   -- let WezTerm's default win
--     local title = (d and d.prefix or '') .. base
--     local bg = d and d.bg or '#333333'
--     local fg = d and d.fg or '#cccccc'
--     return { {Background={Color=bg}}, {Foreground={Color=fg}}, {Text=' '..title..' '} }
--   end)
--   -- ...and, if you already handle user-var-changed yourself, also call:
--   wezterm.on('user-var-changed', function(window, pane, name, value)
--     claude.on_user_var(window, pane, name, value)  -- handles CLAUDE_FOCUS_REQUEST
--   end)
--
-- FOLDER-AWARE TITLES: independent of any alert, this module also fills in the
-- tab title. A bare shell (whose title is empty or just the shell name) gets its
-- working-directory name; a Claude Code tab (whose title is the task it's working
-- on) is prefixed with that name — e.g. "[wisp] Add search to the UI" — so you can
-- tell parallel sessions apart. An explicit tab rename (the rename UI or
-- `wezterm cli set-tab-title`) wins over the folder/task logic (an active alert
-- still tints the tab). Set show_folder = false to opt out (tabs render as
-- WezTerm would by default; only alert tinting remains).
--
-- Options (all optional) for apply()/configure():
--   colors  = { attention = {bg=..., fg=...}, done = {bg=..., fg=...} }
--   prefix  = { attention = '⚠️ ', done = '✅ ' }
--   click_to_focus = true|false  -- handle CLAUDE_FOCUS_REQUEST to jump Space+tab
--   show_folder    = true|false  -- folder-aware titles (default true; see above)
--   folder_format  = '[%s] '     -- string.format template for the folder prefix on
--                                   a Claude task title (%s = the cwd folder name)
--   agents_status  = true|false  -- AGENTS AWAITING-INPUT STATUS (default true; see below)
--   agents_status_interval = 3   -- seconds between polls of the daemon job state
--   agents_status_max      = 4   -- max agent names to list before "· +N more"
--   agents_status_color    = '#e5c07b'  -- foreground color of the right-status text
--   notification_handling = 'SuppressFromFocusedTab' | 'AlwaysShow' | ...
--       (only relevant if you fall back to WezTerm's native OSC toasts; the
--        terminal-notifier path used by default is unaffected by this.)
--
-- AGENTS AWAITING-INPUT STATUS: a daemon-managed background / `claude agents`
-- worker has NO pane of its own (it inherited a frozen $WEZTERM_PANE from its
-- launcher), so its "needs input" toast can't reliably focus a tab and its tab
-- can't be tinted — there is no correct tab. Instead we surface that state where
-- it IS reliable: the daemon writes each worker's status to
-- ~/.claude/jobs/<id>/state.json in real time, flipping `state` to "blocked" the
-- moment a worker awaits you. This module polls those files (gated by the live
-- ~/.claude/daemon/roster.json so finished jobs never count) and shows the blocked
-- agents BY NAME in the WezTerm right status bar of every window — pane-independent,
-- immune to stale panes, multiple `claude agents` UIs, and tab renames. The status
-- is cleared when nothing awaits. If you already drive update-status yourself, set
-- agents_status=false and call claude.agents_status_text() from your own handler.

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
  -- Folder-aware titles: a bare shell tab shows its working-directory name, and
  -- a Claude Code tab (whose title is the current task) is prefixed with that
  -- name so you can tell sessions apart, e.g. "[wisp] Add search to the UI".
  show_folder = true,
  folder_format = '[%s] ', -- string.format template for the Claude-title prefix; %s = folder
  -- Agents awaiting-input status (right status bar). See the header comment.
  agents_status = true,
  agents_status_interval = 3,        -- seconds between polls of the daemon job state
  agents_status_max = 4,             -- max agent names to list before "· +N more"
  agents_status_color = '#e5c07b',   -- amber, to read as distinct from the red alert tabs
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
    show_folder = (o.show_folder == nil) and defaults.show_folder or o.show_folder,
    folder_format = o.folder_format or defaults.folder_format,
    -- explicit nil check so agents_status = false is honored (not coerced to true)
    agents_status = (o.agents_status == nil) and defaults.agents_status or o.agents_status,
    agents_status_interval = o.agents_status_interval or defaults.agents_status_interval,
    agents_status_max = o.agents_status_max or defaults.agents_status_max,
    agents_status_color = o.agents_status_color or defaults.agents_status_color,
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

-- Short folder label from a pane's current working directory, or nil if unknown.
-- Robust across WezTerm builds: since 20240127 current_working_dir is a Url object
-- (read .file_path); before that it was a plain file:// string. We handle both,
-- plus the tostring() fallback for a non-file scheme (e.g. ssh://host/path).
local function folder_name(pane)
  local cwd = pane and pane.current_working_dir
  if not cwd then return nil end
  local path
  if type(cwd) == 'userdata' then
    local ok, fp = pcall(function() return cwd.file_path end)
    if ok and type(fp) == 'string' and fp ~= '' then path = fp else cwd = tostring(cwd) end
  end
  if not path and type(cwd) == 'string' then
    path = cwd:gsub('^%a[%w+.-]*://[^/]*', '')                 -- strip scheme + optional host
    path = path:gsub('%%(%x%x)', function(h)                   -- percent-decode (%20 -> space)
      return string.char(tonumber(h, 16))
    end)
  end
  if not path or path == '' then return nil end
  path = path:gsub('/+$', '')                                  -- drop trailing slash(es)
  if path == '' then return '/' end                            -- cwd was the filesystem root
  local name = path:match('([^/]+)$'):gsub('%c', '')           -- basename; strip stray control bytes
  return name ~= '' and name or nil
end

-- Pane titles that mean "just a shell, nothing meaningful" — a default shell
-- reports its process name as the title, so treat those like an empty title
-- (show the folder name alone, not "[folder] zsh"). Login shells prefix a '-'.
local SHELL_TITLES = {
  zsh = true, bash = true, sh = true, fish = true, tcsh = true, csh = true,
  ksh = true, dash = true, nu = true, pwsh = true, xonsh = true, elvish = true,
}
local function is_bare_title(raw)
  if raw == '' then return true end
  return SHELL_TITLES[(raw:gsub('^%-', ''))] == true          -- strip a login shell's leading '-'
end

-- Apply opts.folder_format to the folder name, guarded against a misconfigured
-- template. string.format raises on a type-mismatched directive (e.g. '%d') and
-- silently drops the folder for a template with no '%s' (or an empty one). In any
-- case where the folder name doesn't survive into the result we fall back to the
-- default bracket form, so the folder is always shown.
local function with_folder(folder)
  local ok, s = pcall(string.format, opts.folder_format, folder)
  if ok and s and s:find(folder, 1, true) then return s end   -- plain find: folder present?
  return '[' .. folder .. '] '
end

-- Base tab title (before any alert prefix/color):
--   explicit tab rename (tab_title)       -> the rename (an active alert still tints it)
--   plain shell (empty / shell-name title)-> "<folder>"        (the folder name alone)
--   Claude Code / any other real title    -> "[folder] <title>" via opts.folder_format
--   no folder (show_folder=false, no cwd) -> the pane title verbatim
function M.title(tab)
  if not tab then return '' end
  -- A tab renamed via the UI or `wezterm cli set-tab-title` is the user's
  -- deliberate choice; honor it (the caller may still prepend an alert prefix).
  if tab.tab_title and tab.tab_title ~= '' then return tab.tab_title end
  local pane = tab.active_pane
  if not pane then return '' end
  local raw = pane.title or ''
  local folder = opts.show_folder and folder_name(pane) or nil
  if not folder then return raw end             -- folder off, or cwd unknown
  if is_bare_title(raw) then return folder end  -- plain shell: the folder name alone
  return with_folder(folder) .. raw             -- real title: "[folder] <title>"
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

-- === Agents awaiting-input status =========================================
-- Read the daemon's job state files and report which `claude agents` / background
-- workers are awaiting your input. See the header comment for the full rationale.

local function read_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

-- wezterm.json_parse raises on malformed JSON (e.g. a state.json caught mid-write),
-- so guard it and treat any failure as "no data this cycle" (it reappears next poll).
local function json_parse(s)
  if not s or s == '' then return nil end
  local ok, v = pcall(wezterm.json_parse, s)
  if ok then return v end
  return nil
end

-- Names of daemon-managed workers whose state is "blocked" (awaiting your input).
-- We iterate the LIVE roster (supervisorPid + a `workers` map; entries carry
-- dispatch.short / sessionId) rather than globbing the jobs dir, so a finished
-- worker — whose state.json lingers at "done" — never counts. The job dir is keyed
-- by the short id (== state.json daemonShort == first sessionId segment).
local function blocked_agent_names()
  local home = wezterm.home_dir or os.getenv('HOME')
  if not home or home == '' then return {} end
  local roster = json_parse(read_file(home .. '/.claude/daemon/roster.json'))
  if type(roster) ~= 'table' or type(roster.workers) ~= 'table' then return {} end
  local names = {}
  for _, w in pairs(roster.workers) do
    if type(w) == 'table' then
      local short = (w.dispatch and w.dispatch.short)
        or (type(w.sessionId) == 'string' and w.sessionId:match('^[^-]+'))
      if short then
        local st = json_parse(read_file(home .. '/.claude/jobs/' .. short .. '/state.json'))
        if type(st) == 'table' and st.state == 'blocked' then
          local nm = st.name
          if type(nm) ~= 'string' or nm == '' then        -- unnamed: fall back to the cwd leaf
            nm = type(st.cwd) == 'string' and st.cwd:gsub('/+$', ''):match('([^/]+)$') or nil
          end
          names[#names + 1] = nm or 'agent'
        end
      end
    end
  end
  return names
end

local function format_agents(names)
  local n = #names
  if n == 0 then return '' end
  table.sort(names)                  -- stable display order (roster iteration order isn't)
  local max = opts.agents_status_max or 4
  local shown, extra = names, 0
  if n > max then
    shown = {}
    for i = 1, max do shown[i] = names[i] end
    extra = n - max
  end
  local verb = (n == 1) and 'needs' or 'need'
  local s = '⏳ ' .. n .. ' agent' .. ((n == 1) and '' or 's') .. ' ' .. verb
    .. ' input · ' .. table.concat(shown, ' · ')
  if extra > 0 then s = s .. ' · +' .. extra .. ' more' end
  return s
end

-- Throttled, pcall-guarded accessor returning the "agents awaiting input" string
-- ('' when none). update-status fires ~1/s per window; the cache (shared across all
-- windows) caps the actual file reads at one batch per agents_status_interval.
-- Public so a user with their own update-status handler can compose it.
local agents_cache = { at = -1, text = '' }
function M.agents_status_text()
  local now = os.time()
  local interval = opts.agents_status_interval or 3
  if agents_cache.at >= 0 and (now - agents_cache.at) < interval then
    return agents_cache.text
  end
  agents_cache.at = now
  local ok, text = pcall(function() return format_agents(blocked_agent_names()) end)
  agents_cache.text = (ok and text) or ''
  return agents_cache.text
end

-- Register standalone format-tab-title (folder-aware title + alert tinting) and,
-- unless disabled, a user-var-changed handler (click-to-focus). The handler
-- returns nil only when there's nothing to show (no alert, no title, no folder),
-- so WezTerm's default rendering (or another handler) wins in that case.
function M.apply(config, o)
  if o then M.configure(o) end
  if opts.notification_handling and config and config.notification_handling == nil then
    config.notification_handling = opts.notification_handling
  end
  wezterm.on('format-tab-title', function(tab, tabs, panes, conf, hover, max_width)
    local d = M.decorate(tab)             -- nil when no alert; also tracks acknowledgment
    local title = M.title(tab)            -- folder-aware base title
    if d then
      return {
        { Background = { Color = d.bg } },
        { Foreground = { Color = d.fg } },
        { Text = ' ' .. d.prefix .. title .. ' ' },
      }
    end
    -- No alert: render the folder-aware title. With folder titles off (the opt-out)
    -- or nothing to show, return nil so WezTerm's default / another handler wins.
    if not opts.show_folder or title == '' then return nil end
    return ' ' .. title .. ' '            -- plain string keeps the theme's tab colors
  end)
  if opts.click_to_focus then
    wezterm.on('user-var-changed', M.on_user_var)
  end
  if opts.agents_status then
    wezterm.on('update-status', function(window)
      local text = M.agents_status_text()
      if text == '' then
        window:set_right_status('')
      else
        window:set_right_status(wezterm.format({
          { Foreground = { Color = opts.agents_status_color } },
          { Text = text .. '  ' },           -- trailing pad so it isn't flush to the edge
        }))
      end
    end)
  end
  return M
end

return M
