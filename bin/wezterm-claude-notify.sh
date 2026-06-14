#!/bin/bash
# wezterm-claude-notify — reflect Claude Code session state into WezTerm.
#
# Called by Claude Code hooks with a status and (for alerts) a message:
#   wezterm-claude-notify.sh <ATTENTION|DONE|WORKING> [toast message]
#     ATTENTION -> red tab  + clickable OS toast  (but Claude Code's non-input
#                  Notifications — idle "waiting for your next prompt", auth
#                  success, completed MCP forms — are filtered out; see the
#                  notification_type guard below)
#     DONE      -> green tab
#     WORKING   -> clears the highlight (tab back to normal)
#
# WHY THIS SCRIPT EXISTS (see docs/DESIGN.md for the full story):
#   As of Claude Code v2.1.139, command hooks run in their own session with NO
#   controlling terminal, and their stdout is captured by Claude Code (parsed as
#   JSON) — so a hook CANNOT reach the terminal by printf-ing an escape sequence
#   to stdout or /dev/tty. We instead look up THIS pane's tty device node via
#   $WEZTERM_PANE + `wezterm cli list` and write the OSC sequence to that device.
#   For the toast we use terminal-notifier so the notification can carry a click
#   action that focuses the originating pane (OSC notifications can't).
#
# Config via env (all optional):
#   WCN_TOAST=0          disable OS toasts (tab coloring still works)
#   WCN_NOTIFIER=/path   force a specific terminal-notifier binary
#   WCN_FOCUS=0          on click, only foreground WezTerm + select the tab; skip
#                        the user-var write that switches macOS Space / raises the
#                        originating window (use on builds without user-var-changed)

set -u
status="${1:-}"
fallback_msg="${2:-}"

# Only meaningful inside WezTerm.
[ -n "${WEZTERM_PANE:-}" ] || exit 0

# Claude Code delivers the hook's JSON event on stdin, for EVERY hook. We read it
# (when present) to extract two things: the firing session's own `cwd` — used by
# all three statuses to detect a stale/inherited $WEZTERM_PANE (a background/agent
# session pointing at someone else's pane; see the guard below) so we don't color
# or toast the wrong tab — and, for ATTENTION, the `notification_type`, which tells
# a real input/permission request from a non-input Notification (idle "waiting for
# your next prompt", auth success, …) that must NOT turn the tab red. The read is
# BOUNDED on purpose: `read -t 1` caps it at one second so a caller that delivers
# the event but holds stdin open can never hang the hook — Claude Code closes stdin
# right after the event, so the normal path still returns instantly; `-d ''` slurps
# the whole payload (incl. a pretty-printed multi-line one). Skip it on an
# interactive terminal, which carries no payload to wait for. On timeout or no
# payload, hook_payload is empty and we fall through (fail visible). `|| true`: a
# no-delimiter EOF/timeout makes read exit non-zero, which is expected, not an error.
hook_payload=""
hook_cwd=""
if [ ! -t 0 ]; then
  IFS= read -r -d '' -t 1 hook_payload || true
fi

# --- locate tools (portable across Homebrew prefixes / install locations) ----
find_wezterm() {
  if [ -n "${WEZTERM_EXECUTABLE_DIR:-}" ] && [ -x "${WEZTERM_EXECUTABLE_DIR}/wezterm" ]; then
    printf '%s' "${WEZTERM_EXECUTABLE_DIR}/wezterm"; return 0
  fi
  if command -v wezterm >/dev/null 2>&1; then command -v wezterm; return 0; fi
  for c in /Applications/WezTerm.app/Contents/MacOS/wezterm \
           /opt/homebrew/bin/wezterm /usr/local/bin/wezterm; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}
wezterm="$(find_wezterm)" || exit 0

PYTHON="$(command -v python3 2>/dev/null || true)"
[ -z "$PYTHON" ] && PYTHON=/usr/bin/python3
[ -x "$PYTHON" ] || exit 0

# Drop the non-input Notification types: these don't need you, so they must not
# paint the tab red. The set is Claude Code's known informational events —
#   idle_prompt           Claude is idle, "waiting for your next prompt"
#   auth_success          a login / auth just succeeded
#   elicitation_complete  an MCP elicitation form was submitted or dismissed
#   elicitation_response  an MCP elicitation response was sent back
# Everything ELSE still flags the tab: the genuine input requests
# (permission_prompt, elicitation_dialog) AND — deliberately — any unknown or
# future type, an empty/unparseable payload, or a Claude Code too old to carry
# notification_type. That's a denyLIST, not an allowlist, so it's fail VISIBLE:
# we never silently swallow a real prompt; the cost of an unknown type is at most
# one spurious red tab. Bailing here also skips the wezterm query below.
if [ -n "$hook_payload" ]; then
  # One parse yields both the notification_type (for the denylist below) and the
  # FIRING session's own cwd (for the stale-pane guard further down). Tab-delimited;
  # cwd can't contain a tab, and a parse failure yields a lone tab (both empty).
  # WORKING/DONE payloads carry no notification_type, so ntype is empty for them and
  # the denylist below is a no-op there — they only need cwd for the guard.
  parsed="$(printf '%s' "$hook_payload" | "$PYTHON" -c 'import json,sys
try:
    d = json.load(sys.stdin)
    d = d if isinstance(d, dict) else {}
    sys.stdout.write((d.get("notification_type") or "") + "\t" + (d.get("cwd") or ""))
except Exception:
    sys.stdout.write("\t")' 2>/dev/null)"
  ntype="${parsed%%$'\t'*}"
  hook_cwd="${parsed#*$'\t'}"
  case "$ntype" in
    idle_prompt|auth_success|elicitation_complete|elicitation_response) exit 0 ;;
  esac
fi

# WezTerm app icon (for the toast), derived from the binary location.
icon=""
case "$wezterm" in
  */WezTerm.app/Contents/MacOS/wezterm)
    cand="${wezterm%/Contents/MacOS/wezterm}/Contents/Resources/terminal.icns"
    [ -f "$cand" ] && icon="file://$cand" ;;
esac
[ -z "$icon" ] && [ -f /Applications/WezTerm.app/Contents/Resources/terminal.icns ] \
  && icon="file:///Applications/WezTerm.app/Contents/Resources/terminal.icns"

# --- one query: this pane's tty device + title + cwd + 1-based tab position ---
# Tab POSITION (not the internal tab_id) is what cmd+N maps to; computed per
# window by ranking this pane's tab among the window's tabs.
info="$(
  "$wezterm" cli list --format json 2>/dev/null \
  | "$PYTHON" -c 'import json,sys,os,urllib.parse
pid=int(os.environ.get("WEZTERM_PANE","-1"))
data=json.load(sys.stdin)
p=next((x for x in data if x.get("pane_id")==pid), {})
win=p.get("window_id"); mytab=p.get("tab_id")
tabs=sorted({x.get("tab_id") for x in data if x.get("window_id")==win and x.get("tab_id") is not None})
pos=(tabs.index(mytab)+1) if mytab in tabs else ""
def clean(s): return (s or "").replace("\t"," ").replace("\n"," ").replace(";",",").strip()
# WezTerm reports cwd as a file://host/path URL; reduce it to a plain, percent-
# decoded filesystem path so it matches the hook payload cwd (a plain path) when
# the stale-pane guard compares them. (The basename for dir still works on either.)
def to_path(u):
    u = u or ""
    return urllib.parse.unquote(urllib.parse.urlparse(u).path or "") if "://" in u else u
print("\t".join([clean(p.get("tty_name")), clean(p.get("title")), clean(to_path(p.get("cwd"))), str(pos)]))' 2>/dev/null
)"
IFS=$'\t' read -r tty_dev pane_title pane_cwd tab_pos <<< "${info:-}"

# Fallback: the parent process controlling tty.
if [ -z "${tty_dev:-}" ]; then
  t="$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ')"
  [ -n "$t" ] && [ "$t" != "??" ] && tty_dev="/dev/$t"
fi
[ -n "${tty_dev:-}" ] && [ -w "$tty_dev" ] || exit 0

# --- guard: a stale/inherited WEZTERM_PANE (background & agent sessions) ------
# $WEZTERM_PANE identifies the firing session's pane ONLY for a plain one-Claude-
# per-pane session. A daemon-managed, backgrounded, or `claude agents`-orchestrated
# session inherits the WEZTERM_PANE of whatever pane LAUNCHED it, which may now hold
# an unrelated (or dormant) session. We'd then resolve THAT pane and stamp its folder
# + title onto — and paint its tab for — a notification that came from elsewhere
# (e.g. a loc-inspections agent surfacing as "landmark"). The Notification payload
# carries the firing session's OWN cwd: if its project root differs from the resolved
# pane's, the pane isn't ours, so suppress (no toast, no tab paint). Worktrees live at
# <project>/.claude/worktrees/<name>, so normalize both to the project root first.
# Skipped when either cwd is unknown (empty payload, older Claude, lookup miss) so the
# normal foreground path is untouched — fail visible, never swallow a real prompt.
# This sits before the tab-color write, so it guards ALL THREE statuses: a stray
# WORKING/DONE from a background session no longer recolors the launcher pane's tab.
project_root() {  # owning project root: drop a trailing slash + any Claude worktree suffix
  local p="${1%/}"
  case "$p" in */.claude/worktrees/*) p="${p%%/.claude/worktrees/*}" ;; esac
  printf '%s' "$p"
}
if [ -n "${hook_cwd:-}" ] && [ -n "${pane_cwd:-}" ] \
   && [ "$(project_root "$hook_cwd")" != "$(project_root "$pane_cwd")" ]; then
  exit 0
fi

# --- tab color: OSC 1337 SetUserVar (value MUST be base64-encoded) -----------
case "$status" in
  WORKING|working|clear|"") val="" ;;
  *) val="$status" ;;
esac
b64="$(printf %s "$val" | base64 | tr -d '\n')"
printf '\033]1337;SetUserVar=CLAUDE_STATUS=%s\007' "$b64" > "$tty_dev"

# --- OS toast (only when a message is provided, i.e. the Notification hook) ---
[ "${WCN_TOAST:-1}" = "0" ] && exit 0
if [ -n "$fallback_msg" ]; then
  dir="${pane_cwd##*/}"; [ -z "$dir" ] && dir="${pane_cwd:-session}"
  body="${pane_title:-$fallback_msg}"
  [ -n "${tab_pos:-}" ] && body="${body} (⌘${tab_pos})"

  tn="${WCN_NOTIFIER:-}"
  [ -z "$tn" ] && tn="$(command -v terminal-notifier 2>/dev/null || true)"
  [ -z "$tn" ] && { for c in /opt/homebrew/bin/terminal-notifier /usr/local/bin/terminal-notifier; do [ -x "$c" ] && tn="$c" && break; done; }

  if [ -n "${tn:-}" ] && [ -x "$tn" ]; then
    # What a click does, in order (runs under /bin/sh with a minimal PATH, so
    # absolute paths). The goal: jump to the originating window's macOS Space,
    # raise that window, and select its tab — even with several WezTerm windows
    # spread across Spaces.
    #   1. open -a WezTerm — foreground WezTerm over whatever app you're in (a
    #      backgrounded app can't pull itself forward from Lua alone).
    #   2. activate-pane  — Mux-level tab select; this is ALSO the graceful
    #      degradation path on older builds where user-var-changed doesn't fire.
    #   3. sleep, then write CLAUDE_FOCUS_REQUEST to THIS pane's tty. WezTerm
    #      fires user-var-changed and claude-notify.lua calls pane:activate() +
    #      window:focus(): selects the tab, raises the OS window, and (an app
    #      focusing its own window makes macOS follow) switches to that window's
    #      Space. The short sleep lets step 1 bring WezTerm frontmost first —
    #      window:focus() only switches Space when WezTerm is already frontmost.
    # NO macOS Accessibility permission and NO window-title tag are needed.
    # The SetUserVar VALUE is arbitrary (MQ== = base64 "1"): WezTerm fires the
    # event on every SetUserVar receipt, so a constant re-fires on every click.
    # WCN_FOCUS=0 keeps only foreground + tab select (no Space/window jump).
    # CLAUDE_FOCUS_REQUEST must match the name claude-notify.lua listens for.
    if [ "${WCN_FOCUS:-1}" != "0" ]; then
      exec_cmd="/usr/bin/open -a WezTerm ; ${wezterm} cli activate-pane --pane-id ${WEZTERM_PANE} >/dev/null 2>&1 ; /bin/sleep 0.25 ; printf '\033]1337;SetUserVar=CLAUDE_FOCUS_REQUEST=MQ==\007' > ${tty_dev}"
    else
      exec_cmd="${wezterm} cli activate-pane --pane-id ${WEZTERM_PANE} ; /usr/bin/open -a WezTerm"
    fi
    args=( -title "Claude needs input: ${dir}"
           -message "$body"
           -group "wezterm-claude-${WEZTERM_PANE}"
           -execute "$exec_cmd" )
    [ -n "$icon" ] && args+=( -appIcon "$icon" )
    "$tn" "${args[@]}" >/dev/null 2>&1
  else
    # Fallback: native WezTerm toast via OSC 777 (no click-to-pane).
    printf '\033]777;notify;%s;%s\007' "Claude needs input: ${dir}" "$body" > "$tty_dev"
  fi
fi

exit 0
