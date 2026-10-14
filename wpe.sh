#!/usr/bin/env bash
# Backend for the omarchy-wpe overlay: discovers Wallpaper Engine projects in
# every Steam library and runs one linux-wallpaperengine process per monitor.
#
#   wpe.sh list                  JSON: { active: {screen: dir}, wallpapers: [...] }
#   wpe.sh apply <dir> [screen]  Show <dir> on <screen>, or on every monitor
#   wpe.sh stop [screen]         Clear <screen>, or every monitor
#   wpe.sh disable               Stop Wallpaper Engine and keep the saved assignment
#   wpe.sh enable                Re-enable Wallpaper Engine and restore the saved assignment
#   wpe.sh toggle                Toggle Wallpaper Engine on/off
#   wpe.sh restore               Relaunch the saved assignment if not running
#   wpe.sh restack               Put wallpapers back on top of the background layer

set -uo pipefail

APP_ID=431960
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-wpe"
STATE_FILE="$STATE_DIR/screens.json"
RUN_DIR="$STATE_DIR/run"
DISABLED_FILE="$STATE_DIR/disabled"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-wpe/config"

# Persistent local disable switch. The wallpaper assignment is preserved
# while disabled so enable/toggle can restore it without re-picking a wallpaper.
is_disabled() {
  [[ -f $DISABLED_FILE ]]
}

# `list` output ends up in the long-lived shell process, so everything a
# (possibly hostile) Workshop project controls is bounded. Real project.json
# files are a few KB.
MAX_PROJECT_BYTES=262144
MAX_WALLPAPERS=5000
MAX_LIST_BYTES=4194304

WPE_FPS=30
WPE_SILENT=1
WPE_VOLUME=15
WPE_SCALING=fill
# never | active | any. linux-wallpaperengine's detector reacts to a fullscreen
# window on any monitor, so anything but never freezes every screen at once.
WPE_FULLSCREEN_PAUSE=never
WPE_EXTRA_ARGS=""
# shellcheck source=/dev/null
[[ -f $CONFIG_FILE ]] && source "$CONFIG_FILE"

steam_roots() {
  local root
  for root in \
    "$HOME/.local/share/Steam" \
    "$HOME/.steam/steam" \
    "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam" \
    "$HOME/snap/steam/common/.local/share/Steam"; do
    [[ -d $root ]] && realpath -- "$root"
  done
}

steam_libraries() {
  local root
  {
    steam_roots
    while IFS= read -r root; do
      [[ -f $root/steamapps/libraryfolders.vdf ]] &&
        sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$root/steamapps/libraryfolders.vdf"
    done < <(steam_roots)
  } | while IFS= read -r lib; do
    [[ -d $lib/steamapps ]] && realpath -- "$lib"
  done | sort -u
}

project_dirs() {
  local lib dir
  while IFS= read -r lib; do
    for dir in \
      "$lib/steamapps/workshop/content/$APP_ID"/*/ \
      "$lib/steamapps/common/wallpaper_engine/projects/myprojects"/*/ \
      "$lib/steamapps/common/wallpaper_engine/projects/defaultprojects"/*/; do
      # Output is line-oriented, so a path with a newline or tab can't be listed.
      [[ $dir == *[$'\n\t']* ]] && continue
      [[ -f ${dir}project.json ]] && printf '%s\n' "${dir%/}"
    done
  done < <(steam_libraries)
}

assets_dir() {
  local lib
  while IFS= read -r lib; do
    if [[ -d $lib/steamapps/common/wallpaper_engine/assets ]]; then
      printf '%s\n' "$lib/steamapps/common/wallpaper_engine/assets"
      return
    fi
  done < <(steam_libraries)
}

connected_monitors() {
  hyprctl monitors -j 2>/dev/null | jq -r '.[].name'
}

read_state() {
  if [[ -s $STATE_FILE ]] && jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
    cat "$STATE_FILE"
  else
    echo '{}'
  fi
}

write_state() {
  mkdir -p "$STATE_DIR"
  local tmp
  tmp=$(mktemp "$STATE_DIR/screens.XXXXXX") || return 1
  cat >"$tmp" && mv -f "$tmp" "$STATE_FILE"
}

# jq program emitting one object per project. Fields are clamped, and file
# names must be plain names inside the project folder so a project can't point
# the picker or the checks below at files elsewhere.
DESCRIBE_JQ='
  def plain_name: tostring | if test("^[^/]{1,255}$") and . != "." and . != ".." then . else "" end;
  (input_filename | sub("/project\\.json$"; "")) as $dir
  | ($dir | split("/") | last) as $id
  | {
      id: $id,
      dir: $dir,
      title: ((.title // "") | tostring | .[0:200] | if . == "" then $id else . end),
      type: ((.type // "") | tostring | ascii_downcase | .[0:32]),
      file: ((.file // "") | plain_name),
      preview: ((.preview // "") | plain_name | if . != "" then "\($dir)/\(.)" else "" end)
    }'

# Describes the given project files with one jq run, falling back to one run
# per file so a single malformed project.json only hides that wallpaper.
describe_projects() {
  jq -c "$DESCRIBE_JQ" "$@" 2>/dev/null && return
  local f
  for f; do jq -c "$DESCRIBE_JQ" "$f" 2>/dev/null; done
}

# Sets REASON to why linux-wallpaperengine cannot run a project, or to nothing
# if it should. Mirrors the checks the renderer fails on at startup so the
# picker can say so up front instead of the wallpaper silently vanishing.
unsupported_reason() {
  local dir=$1 type=$2 file=$3
  REASON=""
  case $type in
  "") REASON="No project type; unsupported by linux-wallpaperengine" ;;
  application) REASON="Application wallpapers only run on Windows" ;;
  video | web)
    [[ -n $file && -f $dir/$file ]] || REASON="Files missing; verify or re-subscribe in Steam"
    ;;
  scene)
    if [[ -n $file && -f $dir/$file ]]; then
      # Unpacked scenes can be inspected; packed scene.pkg ones are assumed
      # fine. Implausibly large files are skipped rather than parsed.
      if (($(stat -c %s "$dir/$file" 2>/dev/null || echo 0) <= 16777216)) &&
        ! jq -e '.general.orthogonalprojection.width? // empty' "$dir/$file" >/dev/null 2>&1; then
        REASON="3D perspective scenes are unsupported by linux-wallpaperengine"
      fi
    elif [[ ! -f $dir/scene.pkg ]]; then
      REASON="Files missing; verify or re-subscribe in Steam"
    fi
    ;;
  *) REASON="Unknown project type; unsupported by linux-wallpaperengine" ;;
  esac
}

# NUL-separated project.json paths no larger than MAX_PROJECT_BYTES, at most
# MAX_WALLPAPERS + 1 of them (the extra one tells cmd_list it truncated).
# Streamed through xargs so no single command gets an oversized argument list.
project_files() {
  local dir
  project_dirs | while IFS= read -r dir; do printf '%s/project.json\0' "$dir"; done |
    xargs -0 -r stat --printf '%s\t%n\0' 2>/dev/null |
    while IFS=$'\t' read -r -d '' size path; do
      ((size <= MAX_PROJECT_BYTES)) && printf '%s\0' "$path"
    done |
    head -z -n $((MAX_WALLPAPERS + 1))
}

cmd_list() {
  local -a files=()
  local truncated=false
  mapfile -t -d '' files < <(project_files)
  if ((${#files[@]} > MAX_WALLPAPERS)); then
    files=("${files[@]:0:MAX_WALLPAPERS}")
    truncated=true
  fi

  local rows=""
  if ((${#files[@]})); then
    export DESCRIBE_JQ
    export -f describe_projects
    rows=$(printf '%s\0' "${files[@]}" | xargs -0 bash -c 'describe_projects "$@"' describe)
  fi

  local active="{}"
  if ! is_disabled; then
    active=$(read_state)
  fi

  local dir type file reasons=""
  # \x1f rather than tab: tab is IFS whitespace, so an empty type would collapse.
  while IFS=$'\x1f' read -r dir type file; do
    [[ -n $dir ]] || continue
    unsupported_reason "$dir" "$type" "$file"
    reasons+="$dir"$'\t'"$REASON"$'\n'
  done < <(printf '%s\n' "$rows" | jq -r 'select(. != null) | [.dir, .type, .file] | join("\u001f")')

  # Rows and reasons go in on stdin and a file: as arguments they can exceed
  # the kernel's 128 KiB per-argument limit on large libraries.
  local disabled=false
  is_disabled && disabled=true

  local out
  out=$(printf '%s\n' "$rows" | jq -cs --argjson active "$active" --argjson disabled "$disabled" --rawfile reasons <(printf '%s' "$reasons") --argjson truncated "$truncated" '
    ($reasons | split("\n") | map(select(. != "") | split("\t") | {key: .[0], value: (.[1] // "")}) | from_entries) as $why
    | { active: $active,
        disabled: $disabled,
        truncated: $truncated,
        wallpapers: (map(select(. != null) | del(.file) | .unsupported = ($why[.dir] // ""))
          | unique_by(.dir)
          | sort_by((.unsupported != ""), (.title | ascii_downcase))) }') || return 1

  # Refuse rather than truncate: a cut-off list would be invalid JSON anyway.
  if (($(printf '%s' "$out" | wc -c) > MAX_LIST_BYTES)); then
    echo "omarchy-wpe: wallpaper list exceeds $MAX_LIST_BYTES bytes" >&2
    return 3
  fi
  printf '%s\n' "$out"
}

# One renderer per monitor. linux-wallpaperengine drives all of its outputs
# from a single loop, so when one output stops receiving frame callbacks (a
# fullscreen window covers it) every other monitor in that process freezes too.
# Separate processes keep a covered monitor from stalling the rest.

screen_alive() {
  local pid state
  pid=$(cat "$RUN_DIR/$1.pid" 2>/dev/null) || return 1
  [[ $pid =~ ^[0-9]+$ ]] && [[ $(cat "/proc/$pid/comm" 2>/dev/null) == linux-wallpaper* ]] || return 1
  # A renderer that crashed while apply still owns it lingers as a zombie.
  state=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null) || return 1
  [[ ${state:0:1} != Z ]]
}

stop_screen() {
  local screen=$1 pid
  pid=$(cat "$RUN_DIR/$screen.pid" 2>/dev/null)
  if screen_alive "$screen"; then
    kill "$pid" 2>/dev/null
    for _ in {1..20}; do
      screen_alive "$screen" || break
      sleep 0.1
    done
    screen_alive "$screen" && kill -KILL "$pid" 2>/dev/null
  fi
  rm -f "$RUN_DIR/$screen.pid" "$RUN_DIR/$screen.args"
}

# linux-wallpaperengine's comm is truncated to 15 characters. Anything not
# tracked here (a manual run, an older single-process launch) would stack on
# top of ours, so it goes.
kill_strays() {
  local pid tracked=" $(cat "$RUN_DIR"/*.pid 2>/dev/null | tr '\n' ' ') "
  for pid in $(pgrep -x linux-wallpaper); do
    [[ $tracked == *" $pid "* ]] || kill "$pid" 2>/dev/null
  done
}

# Fills ARGS with the renderer command line for one monitor.
build_args() {
  # The background layer keeps desktop widgets on the bottom layer (clocks and
  # the like) visible above the wallpaper; see cmd_restack for the ordering.
  ARGS=(--screen-root "$1" --bg "$2" --layer background --scaling "$WPE_SCALING" --fps "$WPE_FPS")
  [[ -n $ASSETS ]] && ARGS+=(--assets-dir "$ASSETS")
  case $WPE_FULLSCREEN_PAUSE in
  any) ;;
  active) ARGS+=(--fullscreen-pause-only-active) ;;
  *) ARGS+=(--no-fullscreen-pause) ;;
  esac
  if [[ $WPE_SILENT == 1 ]]; then ARGS+=(--silent); else ARGS+=(--volume "$WPE_VOLUME"); fi
  # shellcheck disable=SC2206
  [[ -n $WPE_EXTRA_ARGS ]] && ARGS+=($WPE_EXTRA_ARGS)
}

start_screen() {
  local screen=$1 signature=$2
  # setsid detaches the renderer from the shell's process group so it outlives
  # this script; $! is the renderer itself because setsid execs in place.
  # 9>&- keeps the command lock from being inherited and held for its lifetime.
  setsid linux-wallpaperengine "${ARGS[@]}" >"$RUN_DIR/$screen.log" 2>&1 </dev/null 9>&- &
  echo $! >"$RUN_DIR/$screen.pid"
  # Crashes are reported by apply; keep bash's job notice out of stderr.
  disown
  printf '%s' "$signature" >"$RUN_DIR/$screen.args"
}

# Brings the running renderers in line with the saved assignment, restarting
# only monitors whose wallpaper or settings changed. Monitors it started are
# left in STARTED for wait_healthy.
launch() {
  STARTED=()
  if is_disabled; then
    stop_all
    return 0
  fi
  mkdir -p "$RUN_DIR"
  ASSETS=$(assets_dir)

  local screen bg file signature
  local -A connected=() desired=()
  while IFS= read -r screen; do connected[$screen]=1; done < <(connected_monitors)
  while IFS=$'\t' read -r screen bg; do
    [[ -n ${connected[$screen]:-} && -d $bg ]] && desired[$screen]=$bg
  done < <(read_state | jq -r 'to_entries[] | [.key, .value] | @tsv')

  for file in "$RUN_DIR"/*.pid; do
    [[ -e $file ]] || continue
    screen=$(basename "$file" .pid)
    [[ -n ${desired[$screen]:-} ]] || stop_screen "$screen"
  done
  kill_strays

  for screen in "${!desired[@]}"; do
    build_args "$screen" "${desired[$screen]}"
    signature=$(printf '%q ' "${ARGS[@]}")
    if screen_alive "$screen" && [[ $(cat "$RUN_DIR/$screen.args" 2>/dev/null) == "$signature" ]]; then
      continue
    fi
    stop_screen "$screen"
    start_screen "$screen" "$signature"
    STARTED+=("$screen")
  done
}

stop_all() {
  local file
  for file in "$RUN_DIR"/*.pid; do
    [[ -e $file ]] && stop_screen "$(basename "$file" .pid)"
  done
  kill_strays
}

# Renderer failures (unsupported scenes, web crashes) all happen well inside
# the first second, so surviving two seconds means the wallpaper is up. Sets
# FAILED to the first monitor whose renderer died.
wait_healthy() {
  local screen
  FAILED=""
  ((${#STARTED[@]})) || return 0
  for _ in {1..20}; do
    sleep 0.1
    for screen in "${STARTED[@]}"; do
      if ! screen_alive "$screen"; then
        FAILED=$screen
        return 1
      fi
    done
  done
}

# Last line of a renderer log that explains a failure, minus the JSON dumps
# linux-wallpaperengine appends to its errors.
failure_reason() {
  local line
  line=$(grep -v -E '^(Running with|Using wallpaper engine|Failed to initialize GLEW)' "$1" 2>/dev/null |
    grep -v '^[[:space:]]*$' | tail -1 | sed -e 's/ Contents: .*//' -e 's/^[[:space:]]*what():[[:space:]]*//')
  printf '%s\n' "${line:0:160}"
}

cmd_apply() {
  local dir=${1:-} screen=${2:-all}
  if [[ ! -f $dir/project.json ]]; then
    echo "omarchy-wpe: not a wallpaper engine project: $dir" >&2
    return 1
  fi

  local previous was_disabled=false
  previous=$(read_state)
  is_disabled && was_disabled=true

  if [[ $screen == all ]]; then
    connected_monitors | jq -Rn --arg dir "$dir" '[inputs | {key: ., value: $dir}] | from_entries'
  else
    jq --arg screen "$screen" --arg dir "$dir" '.[$screen] = $dir' <<<"$previous"
  fi | write_state || return 1

  # Choosing a wallpaper from the picker is an explicit request to enable WPE.
  rm -f "$DISABLED_FILE"
  launch

  if ! wait_healthy; then
    # Put back whatever was showing before rather than leaving the plain
    # Omarchy background, and keep the failed log for troubleshooting.
    local reason title
    reason=$(failure_reason "$RUN_DIR/$FAILED.log")
    title=$(jq -r '.title // empty' "$dir/project.json" 2>/dev/null)
    cp -f "$RUN_DIR/$FAILED.log" "$STATE_DIR/wpe-failed.log" 2>/dev/null
    if write_state <<<"$previous"; then
      # Preserve a prior disabled state so rollback cannot resurrect wallpapers.
      if [[ $was_disabled == true ]]; then
        : >"$DISABLED_FILE"
      fi
      launch
    fi
    echo "omarchy-wpe: ${title:-wallpaper} failed to start: ${reason:-renderer crashed}" >&2
    return 1
  fi
}

cmd_stop() {
  local screen=${1:-all}
  if [[ $screen == all ]]; then
    rm -f "$STATE_FILE"
    stop_all
  else
    read_state | jq --arg screen "$screen" 'del(.[$screen])' | write_state && launch
  fi
}

# Safe to run repeatedly (the service calls it on every shell start): monitors
# already showing the right wallpaper are left alone.
cmd_restore() {
  launch
}

# Disable rendering without deleting the user's selected wallpapers.
# The saved screens.json remains available for enable/toggle.
cmd_disable() {
  mkdir -p "$STATE_DIR"
  : >"$DISABLED_FILE"
  stop_all
  echo "omarchy-wpe: Wallpaper Engine disabled"
}

# Re-enable rendering and restore the saved wallpaper assignment.
cmd_enable() {
  rm -f "$DISABLED_FILE"
  cmd_restore
  echo "omarchy-wpe: Wallpaper Engine enabled"
}

# Toggle between persistent enabled and disabled states.
cmd_toggle() {
  if is_disabled; then
    cmd_enable
  else
    cmd_disable
  fi
}

# Hyprland stacks surfaces within a layer in the order they were mapped, and
# has no rule to change that. Omarchy's own background shares the background
# layer and is re-created whenever the shell restarts, landing on top of the
# wallpaper. Restart the renderer of any monitor where that happened so it maps
# last again; monitors already on top are left alone.
cmd_restack() {
  is_disabled && return 0

  local layers file screen
  layers=$(hyprctl layers -j 2>/dev/null) || return 0
  for file in "$RUN_DIR"/*.pid; do
    [[ -e $file ]] || continue
    screen=$(basename "$file" .pid)
    screen_alive "$screen" || continue
    if jq -e --arg screen "$screen" '
        (.[$screen].levels["0"] // []) | map(.namespace)
        | indices("linux-wallpaperengine") as $mine
        | ($mine | length) > 0 and ($mine | last) < (length - 1)' <<<"$layers" >/dev/null; then
      stop_screen "$screen"
    fi
  done
  launch
}

if ! command -v linux-wallpaperengine >/dev/null &&
  [[ ${1:-} != list && ${1:-} != disable ]]; then
  echo "omarchy-wpe: linux-wallpaperengine is not installed" >&2
  exit 1
fi

# Everything but list changes the running renderers; serialize those so the
# service's restack can't interleave with an apply from the picker.
if [[ ${1:-} != list ]]; then
  mkdir -p "$STATE_DIR"
  exec 9>"$STATE_DIR/lock"
  if ! flock -w 10 9; then
    echo "omarchy-wpe: another wpe.sh command is still running" >&2
    exit 1
  fi
fi

case ${1:-} in
list) cmd_list ;;
apply) cmd_apply "${@:2}" ;;
stop) cmd_stop "${@:2}" ;;
disable) cmd_disable ;;
enable) cmd_enable ;;
toggle) cmd_toggle ;;
restore) cmd_restore ;;
restack) cmd_restack ;;
*)
  sed -n '2,13s/^# \{0,1\}//p' "$0" >&2
  exit 2
  ;;
esac
