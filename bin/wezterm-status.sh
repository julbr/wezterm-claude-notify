#!/bin/bash
# wezterm-claude-notify — reflect Claude Code session state into WezTerm.
#
# Called by Claude Code hooks with a status and (for alerts) a message:
#   wezterm-status.sh <ATTENTION|DONE|WORKING> [toast message]
#     ATTENTION -> red tab  + clickable OS toast
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
  | "$PYTHON" -c 'import json,sys,os
pid=int(os.environ.get("WEZTERM_PANE","-1"))
data=json.load(sys.stdin)
p=next((x for x in data if x.get("pane_id")==pid), {})
win=p.get("window_id"); mytab=p.get("tab_id")
tabs=sorted({x.get("tab_id") for x in data if x.get("window_id")==win and x.get("tab_id") is not None})
pos=(tabs.index(mytab)+1) if mytab in tabs else ""
def clean(s): return (s or "").replace("\t"," ").replace("\n"," ").replace(";",",").strip()
print("\t".join([clean(p.get("tty_name")), clean(p.get("title")), clean(p.get("cwd")), str(pos)]))' 2>/dev/null
)"
IFS=$'\t' read -r tty_dev pane_title pane_cwd tab_pos <<< "${info:-}"

# Fallback: the parent process controlling tty.
if [ -z "${tty_dev:-}" ]; then
  t="$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ')"
  [ -n "$t" ] && [ "$t" != "??" ] && tty_dev="/dev/$t"
fi
[ -n "${tty_dev:-}" ] && [ -w "$tty_dev" ] || exit 0

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
