#!/usr/bin/env bash
set -euo pipefail

log_file="/tmp/ambit_gnome_dispatch.log"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$log_file"; }

last_press_file="/tmp/ambit_chromium_last_press"
double_tap_window="${AMBIT_DOUBLE_TAP_WINDOW:-1.0}"

log "dispatch start"

ensure_ydotoold() {
  local sock1="/tmp/.ydotool_socket"
  local sock2="/run/ydotoold/socket"
  local sock3="/run/user/${UID}/ydotoold.socket"
  if [[ -S "$sock1" ]]; then
    export YDOTOOL_SOCKET="$sock1"
    return 0
  fi
  if [[ -S "$sock2" ]]; then
    export YDOTOOL_SOCKET="$sock2"
    return 0
  fi
  if [[ -S "$sock3" ]]; then
    export YDOTOOL_SOCKET="$sock3"
    return 0
  fi
  if command -v ydotoold >/dev/null 2>&1; then
    log "ydotoold socket not found; attempting to start ydotoold"
    (nohup ydotoold >/tmp/ydotoold.log 2>&1 &) || true
    sleep 0.2
    if [[ -S "$sock1" ]]; then
      export YDOTOOL_SOCKET="$sock1"
      return 0
    fi
    if [[ -S "$sock2" ]]; then
      export YDOTOOL_SOCKET="$sock2"
      return 0
    fi
    if [[ -S "$sock3" ]]; then
      export YDOTOOL_SOCKET="$sock3"
      return 0
    fi
  fi
  return 1
}

ydotool_refresh() {
  local key_delay="${AMBIT_KEY_DELAY:-30}"
  local keycodes="${AMBIT_REFRESH_KEYCODES:-29:1 42:1 19:1 19:0 42:0 29:0}"
  local refresh_mode="${AMBIT_REFRESH_MODE:-combo}"
  if [[ "$refresh_mode" == "type" ]]; then
    # Hold Ctrl+Shift, type "r", then release. Use if keycodes misbehave.
    ydotool key 29:1 42:1
    ydotool type --key-delay "$key_delay" "r"
    ydotool key 42:0 29:0
  elif [[ "$refresh_mode" == "key" ]]; then
    ydotool key --key-delay "$key_delay" $keycodes
  else
    # Use ydotool's named combo syntax when available.
    ydotool key ctrl+shift+r
  fi
}

now="$(python3 - <<'PY'
import time
print(time.time())
PY
)"
last="0"
if [[ -f "$last_press_file" ]]; then
  last="$(cat "$last_press_file" 2>/dev/null || echo 0)"
fi
printf '%s\n' "$now" > "$last_press_file"

is_double_tap="$(python3 - "$now" "$last" "$double_tap_window" <<'PY'
import sys
now = float(sys.argv[1])
last = float(sys.argv[2])
window = float(sys.argv[3])
print("1" if now - last <= window else "0")
PY
)"

if [[ "$is_double_tap" == "1" ]]; then
  if command -v ydotool >/dev/null 2>&1 && ensure_ydotoold; then
    log "double-tap detected: activating chromium then sending Ctrl+Shift+R via ydotool"
    focus_delay="${AMBIT_FOCUS_DELAY:-0.6}"
    refresh_delay="${AMBIT_REFRESH_DELAY:-0.05}"
    activate_by_substring "Chromium" >/dev/null 2>&1 || true
    sleep 0.1
    activate_by_substring "Chromium" >/dev/null 2>&1 || true
    sleep "$focus_delay"
    ydotool_refresh
    sleep "$refresh_delay"
    exit 0
  fi

  if command -v wtype >/dev/null 2>&1; then
    log "double-tap detected: activating chromium then sending Ctrl+Shift+R via wtype"
    focus_delay="${AMBIT_FOCUS_DELAY:-0.25}"
    activate_by_substring "Chromium" >/dev/null 2>&1 || true
    sleep "$focus_delay"
    wtype -M ctrl -M shift -k r -m shift -m ctrl
    exit 0
  fi

  log "ydotoold/wtype unavailable; cannot hard refresh"
  /usr/bin/notify-send "Ambit" "Start ydotoold or install wtype for hard refresh"
  exit 0
fi

activate_by_wmclass() {
  local klass="$1"
  gdbus call --session \
    --dest org.gnome.Shell \
    --object-path /de/lucaswerkmeister/ActivateWindowByTitle \
    --method de.lucaswerkmeister.ActivateWindowByTitle.activateByWmClass \
    "$klass" 2>/dev/null
}

activate_by_substring() {
  local needle="$1"
  gdbus call --session \
    --dest org.gnome.Shell \
    --object-path /de/lucaswerkmeister/ActivateWindowByTitle \
    --method de.lucaswerkmeister.ActivateWindowByTitle.activateBySubstring \
    "$needle" 2>/dev/null
}

found=false
wmclass_list="${AMBIT_CHROMIUM_WMCLASS:-Chromium,chromium,chromium-browser,org.chromium.Chromium,Google-chrome,google-chrome,google-chrome-stable}"
IFS=',' read -r -a wmclasses <<< "$wmclass_list"
for klass in "${wmclasses[@]}"; do
  res="$(activate_by_wmclass "$klass")"
  if [[ "$res" == "(true,)" ]]; then
    found=true
    log "activated chromium via wm_class=$klass"
    break
  fi
done

if ! $found; then
  for needle in Chromium Chrome; do
    res="$(activate_by_substring "$needle")"
    if [[ "$res" == "(true,)" ]]; then
      found=true
      log "activated chromium via title substring=$needle"
      break
    fi
  done
fi

if $found; then
  log "single tap: activated chromium"
  exit 0
fi

desktop_id="${AMBIT_CHROMIUM_DESKTOP:-}"
chromium_cmd="${AMBIT_CHROMIUM_CMD:-}"

if command -v gtk-launch >/dev/null 2>&1; then
  if [[ -n "$desktop_id" ]]; then
    gtk-launch "$desktop_id" >/dev/null 2>&1 && log "launched via gtk-launch $desktop_id" && exit 0
  fi
  gtk-launch chromium >/dev/null 2>&1 && log "launched via gtk-launch chromium" && exit 0
  gtk-launch chromium-browser >/dev/null 2>&1 && log "launched via gtk-launch chromium-browser" && exit 0
  gtk-launch org.chromium.Chromium >/dev/null 2>&1 && log "launched via gtk-launch org.chromium.Chromium" && exit 0
  gtk-launch google-chrome >/dev/null 2>&1 && log "launched via gtk-launch google-chrome" && exit 0
  gtk-launch google-chrome-stable >/dev/null 2>&1 && log "launched via gtk-launch google-chrome-stable" && exit 0
fi

if command -v gio >/dev/null 2>&1; then
  if [[ -n "$desktop_id" ]]; then
    gio launch "$desktop_id" >/dev/null 2>&1 && log "launched via gio $desktop_id" && exit 0
  fi
  gio launch chromium.desktop >/dev/null 2>&1 && log "launched via gio chromium.desktop" && exit 0
  gio launch org.chromium.Chromium.desktop >/dev/null 2>&1 && log "launched via gio org.chromium.Chromium.desktop" && exit 0
  gio launch google-chrome.desktop >/dev/null 2>&1 && log "launched via gio google-chrome.desktop" && exit 0
  gio launch google-chrome-stable.desktop >/dev/null 2>&1 && log "launched via gio google-chrome-stable.desktop" && exit 0
fi

if [[ -n "$chromium_cmd" ]]; then
  log "launching via AMBIT_CHROMIUM_CMD"
  /bin/sh -lc "$chromium_cmd" >/dev/null 2>&1 && exit 0
fi

log "chromium launcher not found"
/usr/bin/notify-send "Ambit" "Chromium launcher not found"
