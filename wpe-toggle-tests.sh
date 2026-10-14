#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WPE="${1:-$ROOT/wpe.sh}"

bash -n "$WPE"

# The help menu must include every command in the header.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/linux-wallpaperengine"
chmod +x "$tmp/bin/linux-wallpaperengine"

# Keep the test isolated from the user's real WPE state and configuration.
export XDG_STATE_HOME="$tmp/state"
export XDG_CONFIG_HOME="$tmp/config"
export HOME="$tmp/home"
mkdir -p "$HOME"

help=$(PATH="$tmp/bin:$PATH" "$WPE" invalid 2>&1 || true)
for command in list apply stop disable enable toggle restore restack; do
  grep -Fq "wpe.sh $command" <<<"$help"
done

# Every command description should start in the same column.
description_columns=$(printf '%s\n' "$help" | awk '
  /wpe\.sh list/    { print index($0, "JSON:") }
  /wpe\.sh apply/   { print index($0, "Show <dir>") }
  /wpe\.sh stop/    { print index($0, "Clear <screen>") }
  /wpe\.sh disable/ { print index($0, "Stop Wallpaper Engine") }
  /wpe\.sh enable/  { print index($0, "Re-enable Wallpaper Engine") }
  /wpe\.sh toggle/  { print index($0, "Toggle Wallpaper Engine") }
  /wpe\.sh restore/ { print index($0, "Relaunch") }
  /wpe\.sh restack/ { print index($0, "Put wallpapers") }
')
if [[ $(printf '%s\n' "$description_columns" | sort -u | wc -l) -ne 1 ]]; then
  echo "wpe-toggle-tests: help descriptions are not aligned" >&2
  exit 1
fi

source <(sed '/^if ! command -v linux-wallpaperengine/,$d' "$WPE")

# Unit-test state transitions without starting a real renderer.
stop_all() { :; }
launch() { :; }
wait_healthy() {
  if [[ ${FAIL_APPLY:-0} == 1 ]]; then
    FAILED=DP-1
    return 1
  fi
  return 0
}
failure_reason() { printf 'simulated renderer failure\n'; }
connected_monitors() { printf '%s\n' DP-1; }

project="$tmp/project"
mkdir -p "$project"
printf '{"title":"Test wallpaper","type":"video","file":"test.mp4"}\n' > "$project/project.json"
touch "$project/test.mp4"

printf '{"DP-1":"%s"}\n' "$project" | write_state
cmd_disable >/dev/null
test -f "$DISABLED_FILE"
test "$(cat "$STATE_FILE")" = "{\"DP-1\":\"$project\"}"

list=$(PATH="$tmp/bin:$PATH" "$WPE" list)
jq -e '.disabled == true' <<<"$list" >/dev/null

cmd_enable >/dev/null
test ! -e "$DISABLED_FILE"
cmd_disable >/dev/null
cmd_toggle >/dev/null
test ! -e "$DISABLED_FILE"
cmd_toggle >/dev/null
test -f "$DISABLED_FILE"

# A failed picker apply must restore the old assignment and disabled state.
failed_project="$tmp/failed-project"
mkdir -p "$failed_project"
printf '{"title":"Failing wallpaper","type":"video","file":"failed.mp4"}\n' > "$failed_project/project.json"
touch "$failed_project/failed.mp4"
mkdir -p "$RUN_DIR"
printf 'simulated renderer log\n' > "$RUN_DIR/DP-1.log"
if FAIL_APPLY=1 cmd_apply "$failed_project" DP-1; then
  echo "wpe-toggle-tests: expected failing apply to return non-zero" >&2
  exit 1
fi
test -f "$DISABLED_FILE"
jq -e --arg dir "$project" '.["DP-1"] == $dir' "$STATE_FILE" >/dev/null

# Selecting a wallpaper in the picker while disabled must re-enable WPE.
cmd_apply "$project" DP-1
test ! -e "$DISABLED_FILE"
jq -e --arg dir "$project" '."DP-1" == $dir' "$STATE_FILE" >/dev/null

printf 'wpe-toggle-tests: PASS\n'
