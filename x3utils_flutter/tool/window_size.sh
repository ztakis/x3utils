#!/usr/bin/env bash
set -euo pipefail

PROCESS_NAME="${1:-x3utils}"

usage() {
  cat <<'USAGE'
Usage: window_size.sh [process-name]

Reports the outer and client sizes of the first matching X11 window.
The process name defaults to "x3utils".
USAGE
}

fail() {
  echo "window_size.sh: $*" >&2
  exit 1
}

if [[ "$PROCESS_NAME" == "-h" || "$PROCESS_NAME" == "--help" ]]; then
  usage
  exit 0
fi

[[ $# -le 1 ]] || {
  usage >&2
  exit 2
}

for command_name in xprop xwininfo; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "Required command not found: $command_name"
done

[[ -n "${DISPLAY:-}" ]] ||
  fail "No X11 display was found. Run this from the Linux Mint desktop session."

client_list="$(xprop -root _NET_CLIENT_LIST 2>/dev/null)" ||
  fail "Could not read the X11 window list on DISPLAY=$DISPLAY."

window_ids="$({
  printf '%s\n' "$client_list" |
    sed -n 's/^.*# //p' |
    tr ',' '\n' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d'
})"

[[ -n "$window_ids" ]] ||
  fail "No visible X11 windows were found."

window_id=""
process_id=""

while IFS= read -r candidate_id; do
  candidate_pid="$(
    (xprop -notype -id "$candidate_id" _NET_WM_PID 2>/dev/null || true) |
      sed -n 's/^_NET_WM_PID = \([0-9][0-9]*\).*$/\1/p'
  )"
  [[ -n "$candidate_pid" ]] || continue

  process_comm="$(
    (ps -p "$candidate_pid" -o comm= 2>/dev/null || true) |
      sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
  )"
  process_exe="$(readlink "/proc/$candidate_pid/exe" 2>/dev/null || true)"
  process_exe="${process_exe##*/}"

  if [[ "$process_comm" == "$PROCESS_NAME" ||
        "$process_exe" == "$PROCESS_NAME" ]]; then
    window_id="$candidate_id"
    process_id="$candidate_pid"
    break
  fi
done <<< "$window_ids"

[[ -n "$window_id" ]] ||
  fail "No visible '$PROCESS_NAME' X11 window was found. Keep the app open and try again."

window_info="$(LC_ALL=C xwininfo -id "$window_id" 2>/dev/null)" ||
  fail "Could not read the client window rectangle."

read_metric() {
  local label="$1"
  local value

  value="$(
    printf '%s\n' "$window_info" |
      awk -F: -v label="$label" '$1 ~ label {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
        print $2
        exit
      }'
  )"
  [[ "$value" =~ ^-?[0-9]+$ ]] ||
    fail "Could not read '$label' from the client window rectangle."
  printf '%s\n' "$value"
}

client_x="$(read_metric "Absolute upper-left X")"
client_y="$(read_metric "Absolute upper-left Y")"
client_width="$(read_metric "Width")"
client_height="$(read_metric "Height")"

frame_extents="$(
  xprop -notype -id "$window_id" _NET_FRAME_EXTENTS 2>/dev/null |
    sed -n 's/^_NET_FRAME_EXTENTS = //p'
)"

if [[ "$frame_extents" =~ ^[[:space:]]*([0-9]+),[[:space:]]*([0-9]+),[[:space:]]*([0-9]+),[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
  frame_left="${BASH_REMATCH[1]}"
  frame_right="${BASH_REMATCH[2]}"
  frame_top="${BASH_REMATCH[3]}"
  frame_bottom="${BASH_REMATCH[4]}"
else
  fail "Could not read the outer window frame extents."
fi

outer_x=$((client_x - frame_left))
outer_y=$((client_y - frame_top))
outer_width=$((client_width + frame_left + frame_right))
outer_height=$((client_height + frame_top + frame_bottom))

window_title="$(
  xprop -notype -id "$window_id" _NET_WM_NAME 2>/dev/null |
    sed -n 's/^_NET_WM_NAME = //p'
)"
window_title="${window_title#\"}"
window_title="${window_title%\"}"

printf '%-11s : %s\n' "ProcessId" "$process_id"
printf '%-11s : %s\n' "WindowTitle" "$window_title"
printf '%-11s : %s x %s\n' "OuterSize" "$outer_width" "$outer_height"
printf '%-11s : %s x %s\n' "ClientSize" "$client_width" "$client_height"
printf '%-11s : %s, %s\n' "Position" "$outer_x" "$outer_y"
