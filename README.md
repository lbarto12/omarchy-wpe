# Wallpaper Engine for Omarchy

A centered overlay for browsing, previewing, and applying your
[Wallpaper Engine](https://store.steampowered.com/app/431960/Wallpaper_Engine/)
wallpapers on Omarchy, powered by
[linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine).

linux-wallpaperengine deliberately leaves the UI out of scope. This plugin
provides one.

## Features

- Grid of every installed wallpaper (Workshop subscriptions plus Wallpaper
  Engine's bundled projects) across all of your Steam libraries
- Animated preview on the highlighted wallpaper
- Type to filter by title or type (`scene`, `video`, `web`)
- Apply to all monitors or to one specific monitor
- Badges show which monitor is currently running which wallpaper
- Restores your last wallpaper when you log in
- Bar button to open the picker (move or remove it with `omarchy bar`)

## Requirements

- Omarchy with the plugin-capable shell
- [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine)
  (on Arch: `yay -S linux-wallpaperengine-git`)
- Wallpaper Engine owned and installed through Steam (Proton is fine). The
  plugin reads its projects and `assets` folder, and never modifies them.
- `jq` and `hyprctl`, both of which ship with Omarchy

## Install

```bash
omarchy plugin add https://github.com/lbarto12/omarchy-wpe.git --enable
```

## Usage

Click the 󰋩 icon the plugin adds to the right of your bar, or open the picker
from a command or keybinding:

```bash
omarchy-shell shell toggle lbarto12.omarchy-wpe '{}'
```

To bind it to a key, add this to `~/.config/hypr/bindings.conf`:

```ini
bindd = SUPER CTRL, W, Wallpaper Engine, exec, omarchy-shell shell toggle lbarto12.omarchy-wpe '{}'
```

To open with a particular monitor preselected, pass
`'{"screen":"DP-1"}'` instead of `'{}'`.

| Key                 | Action                                     |
| ------------------- | ------------------------------------------ |
| Arrows, PgUp/PgDn   | Move selection                             |
| Enter / click       | Apply to the selected monitor target       |
| Tab / Shift+Tab     | Cycle target: All monitors, then each one  |
| Del                 | Stop the wallpaper on the selected target  |
| Type                | Filter; Backspace edits, Ctrl+U clears      |
| Esc                 | Clear the filter, or close                 |

After you stop a wallpaper, your regular Omarchy background shows again.

### Temporarily disable Wallpaper Engine

To temporarily stop Wallpaper Engine while keeping the current monitor
assignments:

```bash
./wpe.sh disable
```

Enable it again and restore the saved assignments with:

```bash
./wpe.sh enable
```

Or toggle between the two states:

```bash
./wpe.sh toggle
```

When disabled, Wallpaper Engine renderers are stopped and the normal Omarchy
background remains visible. The saved monitor assignments are preserved, so
enabling Wallpaper Engine restores the previous configuration.

Keybindings are not modified automatically by the plugin. With Omarchy's
current Lua-based Hyprland configuration, for example:

```lua
o.bind("SUPER + SHIFT + J", "Toggle Wallpaper Engine", "~/.config/omarchy/plugins/lbarto12.omarchy-wpe/wpe.sh toggle")
```

## Configuration

Optional. Create `~/.config/omarchy-wpe/config`:

```bash
WPE_FPS=30           # frame limit
WPE_SILENT=1         # 1 mutes wallpaper audio; 0 uses WPE_VOLUME
WPE_VOLUME=15
WPE_SCALING=fill     # stretch | fit | fill | default
WPE_FULLSCREEN_PAUSE=never  # never | active | any (see below)
WPE_EXTRA_ARGS=""    # passed straight to linux-wallpaperengine, e.g. "--disable-mouse"
```

Changes apply the next time you choose a wallpaper.

`WPE_FULLSCREEN_PAUSE` defaults to `never`. linux-wallpaperengine's own
fullscreen pause reacts to a fullscreen window on *any* monitor, so it freezes
the wallpaper everywhere, not just behind the fullscreen app. You don't lose
much by leaving it off: Hyprland stops asking a covered wallpaper for frames,
so that monitor's renderer idles on its own. `any` restores upstream's
behaviour and `active` pauses only while the fullscreen window is focused;
both only make sense with a single monitor.

## How it works

- `wpe.sh` finds Steam libraries from `libraryfolders.vdf` (native, Flatpak, and
  Snap Steam), reads each `project.json`, and runs one
  `linux-wallpaperengine` process per monitor. linux-wallpaperengine drives
  all of its outputs from a single loop, so in one shared process a fullscreen
  window on one monitor would freeze the wallpaper on every monitor. Separate
  processes also mean changing one monitor never restarts the others.
- Monitor assignments are stored in `~/.local/state/omarchy-wpe/screens.json`,
  and each monitor's renderer output goes to
  `~/.local/state/omarchy-wpe/run/<monitor>.log`.
- Wallpapers run on the Wayland background layer, so desktop widgets on the
  bottom layer (clocks such as Kronos, for example) stay visible on top.
  Hyprland stacks surfaces within a layer in the order they appear, and
  Omarchy re-creates its own background whenever the shell restarts. The
  plugin's service watches for that and restarts the affected monitor's
  renderer so the wallpaper stays on top (`wpe.sh restack`).
- The plugin owns the renderer, so applying a wallpaper stops any other
  running `linux-wallpaperengine` instance first.

## Unsupported wallpapers

linux-wallpaperengine can't run every Wallpaper Engine project. The picker
dims the ones it can tell up front and shows the reason when you select one:

- 3D perspective scenes (several of Wallpaper Engine's bundled defaults)
- Projects with no type, and `application` (Windows executable) wallpapers
- Workshop items whose files are missing (verify them in Steam)

Some wallpapers, notably many `web` ones, only fail once they start. If the
renderer exits within two seconds of applying one, the plugin puts your
previous wallpaper back and shows the error in the picker. The failed run's
output is kept in `~/.local/state/omarchy-wpe/wpe-failed.log`.

## Tests

Run the regression tests from the repository root:

```bash
./wpe-toggle-tests.sh
```

The suite checks shell syntax and help output, persistent disable/enable/toggle
state, the disabled status returned by `list`, re-enabling by choosing a
wallpaper in the picker, and restoring a prior disabled state if applying a
wallpaper fails. It uses stubs and does not start a real wallpaper renderer.

## Removal

```bash
~/.config/omarchy/plugins/lbarto12.omarchy-wpe/wpe.sh stop
omarchy plugin remove lbarto12.omarchy-wpe
rm -rf ~/.local/state/omarchy-wpe ~/.config/omarchy-wpe
```

## License

MIT
