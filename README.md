# y3
**y3** is a wrapper for [yabai](https://github.com/koekeishiya/yabai) that attempts to emulate i3 behavior and adds additional logic to improve the experience. It may not match 1:1, please let me know if something is missing or incorrect.

## Installation
1. Clone repo
2. Build with Zig 0.13.0
3. Copy `y3` binary to PATH
4. Copy `config.json` to `~/.config/y3/`
5. Add the following lines to your `yabairc` file (window rules are managed in y3):
```
yabai -m rule --add app="$" manage=off
yabai -m signal --add event=window_created action='y3 window-created $YABAI_WINDOW_ID'
yabai -m signal --add event=window_focused action='y3 window-focused $YABAI_WINDOW_ID'
```

## Configuration
Edit `~/.config/y3/config.json` (refer to `Config` struct for details):

Sample config:
```json
{
  "allow_list": {
    "Finder": ["Copy"],
    "System Settings": null
  },
  "layout": "two_columns",
  "placement": "focused_window"
}
```
This config will:
- float all windows from `System Settings` app
- float only the window titled `Copy` from `Finder` app
- enforce a two column layout
- stack new windows on top of the currently focused window (unless the layout is `bsp`)

## Usage
* `y3 focus <dir>` behaves like yabai's `focus --window`. Works across displays and cycles stacks.  
* `y3 move <dir>` emulates i3 `move` command. It will stack, unstack, and warp based on direction and layout. Works across displays.
* `y3 run` launches y3
* `y3 start-service` installs a LaunchAgent and starts the service
* `y3 stop-service` stops the service and removes the LaunchAgent

## TODO
- add `y3 restart-service` command
- manual layout 
- runtime layout switching
- handle `SIGINT`
