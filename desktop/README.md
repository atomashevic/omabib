# omabib-desktop (prototype)

Omabib as an ordinary Qt 6 desktop app, without Omarchy or Quickshell. It runs
the same `plugin/App.qml` the Omarchy plugin runs, unchanged, compiled into the
binary as Qt resources (`qrc:/ui`).

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

App.qml imports `Quickshell`, `Quickshell.Io`, `qs.Commons` and `qs.Ui`. This
host compiles in stand-ins under those names and puts them ahead of any
installed Quickshell on the import path:

| Module | Stand-in |
|---|---|
| `Quickshell` | `env`, `execDetached` (Omarchy's browser launcher and `xdg-open` fall back to the platform opener), `clipboardText`, `FloatingWindow` as a plain `Window` |
| `Quickshell.Io` | `Process`, `SplitParser`, `StdioCollector` on QProcess; `Socket` on QLocalSocket; `FileView` on QSaveFile; `IpcHandler` reachable through `omabib-desktop ipc` |
| `qs.Commons` | `Color` and `Style`: a light and a dark palette following the system scheme (`OMABIB_COLOR_SCHEME=light\|dark` overrides) |
| `qs.Ui` | `PanelToolTip` |

`DesktopHost` (in `Quickshell/host.*`) takes the shell's place: one running
copy, a local socket for later launches, window raising and IPC dispatch.

## Not done yet

- `omabib open`, `omabib add` and `omabib pdf open` in `src/main.rs` still go
  through `omarchy-shell` and `hyprctl`; they should call `omabib-desktop`
  when the Omarchy shell is absent.
- Icons and monospace text need JetBrainsMono Nerd Font installed; a
  standalone build should bundle a font.
- Terminal chat uses `xdg-terminal-exec`, and installing rclone uses
  `omarchy-pkg-add`.
- On Wayland, raising a window that is shown but unfocused depends on the
  compositor honoring xdg-activation (Hyprland: `misc:focus_on_activate`).
  Showing it from hidden always takes focus.
- No macOS build yet. `Process`'s `stdout`/`stderr` property names will
  likely collide with the C library's macros there.
- No `.desktop` file, icon or package.
