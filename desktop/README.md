# omabib-desktop

Omabib's window, an ordinary Qt 6 desktop app for Linux and macOS. It runs
the same `plugin/App.qml` the Omarchy plugin runs, unchanged, compiled into the
binary as Qt resources (`qrc:/ui`). Releases bundle it with its Qt; see
[docs/development.md](../docs/development.md).

## Build and run

Needs Qt 6.5+ (Quick, Quick Controls, Network) and CMake. The library service
(`omabib serve`) and the `omabib-*` helper scripts come from the normal install.

```bash
cmake -S desktop -B build/desktop -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build/desktop -j
build/desktop/omabib-desktop
```

The first launch stays running; closing the window only hides it. Later
launches hand their request to the running copy:

```bash
omabib-desktop --toggle            # show and focus, or hide when focused (bind to Super+B)
omabib-desktop --add               # the add box
omabib-desktop --query "polarization"
omabib-desktop --pdf REF_ID        # a PDF reader tab
omabib-desktop ipc state           # any IpcHandler function in App.qml
omabib-desktop screenshot out.png
omabib-desktop --quit
```

If nothing answers on the service socket, the app starts `omabib serve` itself,
preferring an `omabib` binary next to its own.

To work on the UI without rebuilding, point `OMABIB_UI_DIR` at a `plugin/`
folder; the app then loads QML from there instead of its compiled-in copy:

```bash
OMABIB_UI_DIR=$PWD/plugin build/desktop/omabib-desktop
```

## How it works

The window draws its own light and dark themes (Settings → Theme: System,
Light, Dark, and Omarchy when an Omarchy theme is present). It bundles its
typefaces in `plugin/components/fonts`: Mona Sans in three weights, loaded at
start, Source Serif 4, loaded only for the serif reading font, and Lucide icons
cut to the glyphs `Icons.js` names (`scripts/subset-icons` redoes the cut).
Monospace text uses the platform's own monospace font.

App.qml imports `Quickshell`, `Quickshell.Io` and `qs.Commons`. This host
compiles in stand-ins under those names and puts them ahead of any
installed Quickshell on the import path:

| Module | Stand-in |
|---|---|
| `Quickshell` | `env`, `execDetached` (Omarchy's browser launcher and `xdg-open` fall back to the platform opener), `clipboardText`, `FloatingWindow` as a plain `Window` |
| `Quickshell.Io` | `Process`, `SplitParser`, `StdioCollector` on QProcess; `Socket` on QLocalSocket; `FileView` on QSaveFile; `IpcHandler` reachable through `omabib-desktop ipc` |
| `qs.Commons` | `Color`: the current Omarchy theme's colors from `~/.local/state/omarchy/current/theme/colors.toml`, when there is one, for the Omarchy theme choice; `Style.space()` |

`DesktopHost` (in `Quickshell/host.*`) takes the shell's place: one running
copy, a local socket for later launches, window raising and IPC dispatch.

## Not done yet

- The helpers behind terminal chat need `xdg-terminal-exec`, and desktop chat
  the `chatgpt` and `claude-desktop` commands, so neither works on macOS yet.
  The in-app chat works everywhere.
- **Install rclone** in the Sync dialog runs `omarchy-pkg-add`, so elsewhere
  rclone has to be installed by hand.
- On Wayland, raising a window that is shown but unfocused depends on the
  compositor honoring xdg-activation (Hyprland: `misc:focus_on_activate`).
  Showing it from hidden always takes focus.
