#!/usr/bin/env bash
set -euo pipefail

log_file="/tmp/ambit_gnome_active_window.log"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$log_file"; }

get_extension_json() {
  local raw
  raw="$(gdbus call --session \
    --dest org.gnome.Shell.Extensions.AmbitFocus \
    --object-path /org/gnome/Shell/Extensions/AmbitFocus \
    --method org.gnome.Shell.Extensions.AmbitFocus.GetActiveWindow 2>/dev/null || true)"

  if [[ -z "$raw" ]]; then
    return 0
  fi

  python3 - "$raw" <<'PY'
import ast
import sys

raw = sys.argv[1].strip()
try:
    val = ast.literal_eval(raw)
except Exception:
    print("")
    sys.exit(0)

if isinstance(val, tuple) and val:
    s = val[0]
elif isinstance(val, str):
    s = val
else:
    s = ""

if not isinstance(s, str):
    s = ""

print(s)
PY
}

eval_js() {
  gdbus call --session \
    --dest org.gnome.Shell \
    --object-path /org/gnome/Shell \
    --method org.gnome.Shell.Eval \
    "$1" 2>/dev/null || true
}

parse_gdbus() {
  python3 - "$1" <<'PY'
import ast
import re
import sys

raw = sys.argv[1].strip()
try:
    tup = ast.literal_eval(raw)
except Exception:
    tup = None

if not isinstance(tup, tuple) or len(tup) < 2:
    # Fallback to regex for unexpected formats.
    m = re.match(r"^\\((true|false), (.*)\\)$", raw)
    if not m:
        print("ERR|")
        sys.exit(0)
    ok = m.group(1) == "true"
    payload = m.group(2)
else:
    ok = bool(tup[0])
    payload = tup[1]

if not ok:
    print("NO|")
    sys.exit(0)

if payload is None:
    print("OK|")
    sys.exit(0)

try:
    val = ast.literal_eval(payload) if isinstance(payload, str) else payload
except Exception:
    val = payload

print("OK|" + str(val).replace("\\n", " ").strip())
PY
}

get_field() {
  local expr="$1"
  local raw parsed status value
  raw="$(eval_js "$expr")"
  log "eval_js expr=${expr} raw=${raw}"
  parsed="$(parse_gdbus "$raw")"
  status="${parsed%%|*}"
  value="${parsed#*|}"
  if [[ "$status" != "OK" ]]; then
    log "eval_js status=${status} expr=${expr}"
    if [[ "$status" == "NO" ]]; then
      log "eval_js denied: GNOME Shell Eval likely disabled"
    fi
  fi
  printf '%s' "$value"
}

app_id="$(get_field "global.display.focus_window ? global.display.focus_window.get_gtk_application_id() : ''")"
wm_class="$(get_field "global.display.focus_window ? global.display.focus_window.get_wm_class() : ''")"
wm_instance="$(get_field "global.display.focus_window ? global.display.focus_window.get_wm_class_instance() : ''")"
title="$(get_field "global.display.focus_window ? global.display.focus_window.get_title() : ''")"
log "result app_id=${app_id} wm_class=${wm_class} wm_instance=${wm_instance} title=${title}"

if [[ "${1-}" == "--json" ]]; then
  ext_json="$(get_extension_json)"
  if [[ -n "$ext_json" ]]; then
    log "using extension json"
    printf '%s\n' "$ext_json"
    exit 0
  fi

  python3 - "$app_id" "$wm_class" "$wm_instance" "$title" <<'PY'
import json
import sys

app_id, wm_class, wm_instance, title = sys.argv[1:5]
print(json.dumps({
  "app_id": app_id,
  "wm_class": wm_class,
  "wm_class_instance": wm_instance,
  "title": title,
}))
PY
  exit 0
fi

printf "app_id=%s\nwm_class=%s\nwm_class_instance=%s\ntitle=%s\n" \
  "$app_id" "$wm_class" "$wm_instance" "$title"
