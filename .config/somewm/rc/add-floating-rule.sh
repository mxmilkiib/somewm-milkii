#!/usr/bin/env bash
set -Eeuo pipefail

# add the focused window to the floating rules in rc.lua
# - inspects focused client (class/instance/name/role)
# - picks a specific identifier (prefers class unless generic, then instance, role, name)
# - appends to the correct list in the floating rule_any block
# - preserves indentation and comments; wraps to a new line when long
# - makes timestamped backups and rotates them per policy
#
# backup policy:
# - filename: rc.lua.bak-YYYYMMDD_ hhmm (24h)
# - keep last 5 in place
# - older than latest 5 go to ./old
# - >1 day -> old/week/
# - >1 week -> old/month/
# - >1 month -> old/year/

CONFIG="$HOME/.config/somewm/rc.lua"
MARKER="floatingggggggggg"
MAX_LINE_LEN=100

_die() { printf 'error: %s\n' "$*" >&2; exit 1; }

_need() {
  local missing=()
  for t in somewm-client awk sed date grep mv mkdir find stat touch; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if ((${#missing[@]})); then _die "missing required tools: ${missing[*]}"; fi
}

# old: _get_active_window_id used xdotool/xprop (X11-only)
# new: somewm-client provides client info directly, no window ID needed

_escape_lua() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/\"/\\\"/g'
}

# extract a stable substring from a window title so that name-based rules
# match future windows from the same app, not just the current content.
# ruled.client matches name via Lua string.match (substring/pattern), so
# the extracted part will match any title containing it.
#
# heuristics:
#   "Page Title — App"     → take after " — "  (browser-style app suffix)
#   "file.ext - App"       → take after " - "  (editor-style app suffix)
#   "App: content"         → take before ": "  (app prefix)
#   "Dialog Name"          → no separator, keep as-is (likely already stable)
_extract_stable_name() {
  local title="$1" segment

  # " — " (em-dash with spaces) — app is the last segment
  if [[ "$title" == *" — "* ]]; then
    segment="${title##* — }"
    (( ${#segment} >= 3 )) && { printf '%s' "$segment"; return 0; }
  fi

  # " - " (hyphen with spaces) — app is the last segment
  if [[ "$title" == *" - "* ]]; then
    segment="${title##* - }"
    (( ${#segment} >= 3 )) && { printf '%s' "$segment"; return 0; }
  fi

  # ": " (colon with space) — app is the first segment
  if [[ "$title" == *": "* ]]; then
    segment="${title%%: *}"
    (( ${#segment} >= 3 )) && { printf '%s' "$segment"; return 0; }
  fi

  # no separator or segments too short — keep the full title
  printf '%s' "$title"
}

_backup_rotate() {
  local dir ts dst backdir now secs_day secs_week secs_month f mtime age
  dir=$(dirname -- "$CONFIG")
  ts=$(date +%Y%m%d_%H%M)
  dst="$CONFIG.bak-$ts"
  cp --preserve=mode,timestamps --reflink=auto "$CONFIG" "$dst"

  backdir="$dir/old"
  mkdir -p -- "$backdir" "$backdir/week" "$backdir/month" "$backdir/year"

  # keep latest 5 in-place, move the rest to ./old
  shopt -s nullglob
  local backups=("$CONFIG".bak-*)
  if ((${#backups[@]} > 5)); then
    # sort lexicographically
    IFS=$'\n' backups=($(printf '%s\n' "${backups[@]}" | sort))
    local to_move=("${backups[@]:0:${#backups[@]}-5}")
    for f in "${to_move[@]}"; do mv -f -- "$f" "$backdir/" || true; done
  fi
  shopt -u nullglob

  # age buckets for files already under ./old
  now=$(date +%s)
  secs_day=$((24*60*60))
  secs_week=$((7*24*60*60))
  secs_month=$((30*24*60*60))

  find "$backdir" -maxdepth 1 -type f -name 'rc.lua.bak-*' -print0 | while IFS= read -r -d '' f; do
    mtime=$(stat -c %Y -- "$f") || continue
    age=$((now - mtime))
    if (( age > secs_month )); then
      mv -f -- "$f" "$backdir/year/" || true
    elif (( age > secs_week )); then
      mv -f -- "$f" "$backdir/month/" || true
    elif (( age > secs_day )); then
      mv -f -- "$f" "$backdir/week/" || true
    fi
  done
}

# old: _choose_identifier used xprop -id to get WM_CLASS/WM_NAME/WM_WINDOW_ROLE
# old: tried somewm-client --json client info focused, but its result field is a
#      flat text blob, not structured JSON, so jq field access returned empty
# new: uses somewm-client eval to read the four fields directly from the
#      focused client object, returned as a pipe-delimited string
_choose_identifier() {
  local raw class instance name role
  raw=$(somewm-client eval 'c=client.focus; if c then return tostring(c.class or "").."|"..tostring(c.instance or "").."|"..tostring(c.name or "").."|"..tostring(c.role or "") end return "|||"' 2>/dev/null) || true
  [[ -n "$raw" ]] || _die "cannot get focused client info from somewm-client eval"

  # somewm-client prints "OK\n<return value>"; take the last non-empty line
  local payload
  payload=$(printf '%s\n' "$raw" | sed -e '/^OK$/d' -e '/^[[:space:]]*$/d' | tail -n1)
  [[ -n "$payload" ]] || _die "empty payload from somewm-client eval"

  IFS='|' read -r class instance name role <<<"$payload"

  local -a generic_classes=(
    "Alacritty" "URxvt" "XTerm" "kitty" "st-256color" "foot" "wezterm" "WezTerm"
    "Chromium" "firefox" "Firefox" "Navigator" "Brave-browser" "Google-chrome" "Code"
    "mpv" "Vlc" "vlc" "Thunar" "Dolphin" "Nautilus" "Pcmanfm" "Emacs" "org.gnome.Nautilus"
  )
  local is_generic=false g
  for g in "${generic_classes[@]}"; do
    if [[ "${class:-}" == "$g" ]]; then is_generic=true; break; fi
  done

  if [[ -n "${class:-}" && $is_generic == false ]]; then printf 'class|%s\n' "$class"; return 0; fi
  if [[ -n "${instance:-}" ]]; then printf 'instance|%s\n' "$instance"; return 0; fi
  if [[ -n "${role:-}" ]]; then printf 'role|%s\n' "$role"; return 0; fi
  if [[ -n "${name:-}" ]]; then
    local stable
    stable=$(_extract_stable_name "$name")
    printf 'name|%s\n' "$stable"
    return 0
  fi
  return 1
}

_already_present() {
  local value="$1"
  grep -Fq -- "\"$value\"" "$CONFIG"
}

_insert_into_list() {
  local list="$1"; shift
  local value="$1"
  local escaped
  escaped=$(_escape_lua "$value")
  awk -v marker="$MARKER" -v list="$list" -v newval="$escaped" -v maxlen="$MAX_LINE_LEN" '
    BEGIN { }
    { lines[NR]=$0 }
    END {
      start=0
      for (i=1; i<=NR; i++) if (index(lines[i], marker)) { start=i; break }
      if (start==0) { for (i=1; i<=NR; i++) print lines[i]; exit 0 }
      blockStart=0; blockEnd=0
      for (i=start; i<=NR; i++) {
        if (blockStart==0 && lines[i] ~ list"[ \t]*=[ \t]*\{") { blockStart=i; continue }
        if (blockStart>0 && lines[i] ~ /^[ \t]*\},[ \t]*$/) { blockEnd=i; break }
      }
      if (blockStart==0 || blockEnd==0) { for (i=1; i<=NR; i++) print lines[i]; exit 0 }
      last=-1; firstEntry=-1; entryIndent=""
      for (i=blockStart+1; i<blockEnd; i++) {
        if (firstEntry<0 && lines[i] ~ /\"/) { match(lines[i], /^[ \t]*/); entryIndent=substr(lines[i], RSTART, RLENGTH); firstEntry=i }
        if (lines[i] ~ /\"/) last=i
      }
      if (last<0) {
        newLine=entryIndent"\""newval"\""
        for (i=1; i<blockEnd; i++) print lines[i]
        print newLine
        for (i=blockEnd; i<=NR; i++) print lines[i]
        exit 0
      }
      ll=lines[last]
      cpos=index(ll, "--")
      pre=ll; post=""
      if (cpos>0) { pre=substr(ll,1,cpos-1); post=substr(ll,cpos) }
      sub(/[ \t]+$/, "", pre)
      app=pre
      if (app !~ /,\s*$/) app=app ","
      app=app " \"" newval "\""
      if (length(app) <= maxlen && cpos==0) {
        lines[last]=app
        if (post!="") lines[last]=lines[last] post
      } else {
        preComma=pre
        if (preComma !~ /,\s*$/) preComma=preComma","; lines[last]=preComma
        if (post!="") lines[last]=lines[last] post
        newLine=entryIndent"\""newval"\""
        for (i=1; i<blockEnd; i++) print lines[i]
        print newLine
        for (i=blockEnd; i<=NR; i++) print lines[i]
        exit 0
      }
      for (i=1; i<=NR; i++) print lines[i]
    }
  ' "$CONFIG" >"$CONFIG.tmp"
  mv -f -- "$CONFIG.tmp" "$CONFIG"
}

_main() {
  _need
  [[ -f "$CONFIG" ]] || _die "rc.lua not found at $CONFIG"

  # old: winid=$(_get_active_window_id) || _die "cannot determine active window id"
  # new: somewm-client provides client info directly
  IFS='|' read -r chosen_type chosen_value < <(_choose_identifier) || _die "unable to infer identifier from focused window"
  [[ -n "$chosen_value" ]] || _die "empty identifier"

  if _already_present "$chosen_value"; then
    printf 'already present: %s "%s"\n' "$chosen_type" "$chosen_value"
    exit 0
  fi

  _backup_rotate
  _insert_into_list "$chosen_type" "$chosen_value"

  # old: awesome-client to set floating on the focused window
  # new: somewm-client eval to do the same
  somewm-client eval 'c=client.focus if c then c.floating=true c.ontop=true end' >/dev/null 2>&1 || true

  if command -v notify-send >/dev/null 2>&1; then
    notify-send "somewm" "added $chosen_type=\"$chosen_value\" to floating rules"
  else
    printf 'added %s="%s" to floating rules\n' "$chosen_type" "$chosen_value"
  fi
}

_main "$@"
