#!/usr/bin/env bash
# Installs Omabib for this user from a release archive or a built source
# checkout. It never compiles and needs no administrator access.
#   Linux: ~/.local/bin, with the app and its own Qt under ~/.local/lib/omabib
#          when the archive bundles them. On Omarchy, also the shell plugin
#          and the systemd user service.
#   macOS: ~/Applications/Omabib.app, with omabib on ~/.local/bin.
# Runs on macOS's bash 3.2.
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
backend_only=false
if [[ ${1:-} == --backend-only ]]; then
  backend_only=true
  shift
fi
# Installation never compiles. Source checkouts must run scripts/build.sh first.
if [[ ${1:-} == --help ]]; then
  echo "Usage: $0 [--backend-only] [path/to/prebuilt/omabib]"
  echo "Release archives include bin/omabib; source builds use target/release/omabib."
  exit 0
fi
if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [--backend-only] [path/to/prebuilt/omabib]" >&2
  exit 2
fi
helpers=(omabib-chatgpt omabib-codex omabib-overview omabib-settings omabib-claude)
bin_dir="$HOME/.local/bin"
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}"

missing() { echo "Package is missing $1" >&2; exit 1; }
# Installs a file by replacing the old one, never writing through it: an
# earlier install may have left a link into the app's folder there.
put() {
  install -m "$3" "$1" "$2.new"
  mv "$2.new" "$2"
}
# Agent skill and licenses, the same on every system.
install_shared() {
  mkdir -p "${CODEX_HOME:-$HOME/.codex}/skills/omabib" "$data_dir/omabib/skills/omabib" "$data_dir/omabib/licenses"
  install -m644 "$source_dir/skills/omabib/SKILL.md" "${CODEX_HOME:-$HOME/.codex}/skills/omabib/SKILL.md"
  install -m644 "$source_dir/skills/omabib/SKILL.md" "$data_dir/omabib/skills/omabib/SKILL.md"
  install -m644 "$source_dir/LICENSE" "$data_dir/omabib/licenses/OMABIB-LICENSE"
  if [[ -d "$source_dir/licenses" ]]; then
    cp -r "$source_dir/licenses/." "$data_dir/omabib/licenses/"
  elif [[ -f "$source_dir/src/mitex/LICENSE" ]]; then
    install -m644 "$source_dir/src/mitex/LICENSE" "$data_dir/omabib/licenses/MITEX-LICENSE"
  fi
}
path_hint() {
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "Add $bin_dir to your PATH to use the omabib command, for example in ~/.profile or ~/.zprofile:"
       echo "  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
  esac
}

if [[ $(uname -s) == Darwin ]]; then
  app="$source_dir/Omabib.app"
  [[ -x "$app/Contents/MacOS/omabib" && -x "$app/Contents/MacOS/omabib-desktop" ]] || missing Omabib.app
  for file in skills/omabib/SKILL.md LICENSE; do [[ -f "$source_dir/$file" ]] || missing "$file"; done
  "$app/Contents/MacOS/omabib" --version
  target="$HOME/Applications/Omabib.app"
  # A running copy quits, so the next open runs this one.
  [[ -x "$target/Contents/MacOS/omabib-desktop" ]] && { "$target/Contents/MacOS/omabib-desktop" --quit 2>/dev/null || true; }
  mkdir -p "$HOME/Applications" "$bin_dir"
  rm -rf "$target.new"
  ditto "$app" "$target.new"
  rm -rf "$target"
  mv "$target.new" "$target"
  xattr -dr com.apple.quarantine "$target" 2>/dev/null || true
  # Small scripts rather than links: run from inside the bundle, the app
  # finds its Qt frameworks and omabib finds the app beside it.
  for name in omabib omabib-desktop "${helpers[@]}"; do
    printf '#!/bin/sh\nexec "%s/Contents/MacOS/%s" "$@"\n' "$target" "$name" > "$bin_dir/$name.new"
    chmod 755 "$bin_dir/$name.new"
    mv "$bin_dir/$name.new" "$bin_dir/$name"
  done
  install_shared
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$target" 2>/dev/null || true
  echo "Installed Omabib in ~/Applications. Open it from Spotlight or Launchpad, or run: omabib open"
  path_hint
  if ! xcode-select -p >/dev/null 2>&1 && ! [[ -x /opt/homebrew/bin/python3 ]]; then
    echo "Settings and chat need Python 3. Install it with: xcode-select --install"
  fi
  exit 0
fi

if [[ $# -eq 1 ]]; then
  binary=$1
elif [[ -f "$source_dir/bin/omabib" ]]; then
  binary="$source_dir/bin/omabib"
else
  build_dir="${CARGO_TARGET_DIR:-$source_dir/target}"
  [[ "$build_dir" == /* ]] || build_dir="$source_dir/$build_dir"
  binary="$build_dir/release/omabib"
fi
if [[ ! -x "$binary" ]]; then
  echo "No executable Omabib binary at $binary." >&2
  echo "Download a release archive, or run ./scripts/build.sh before installing from source." >&2
  exit 1
fi
# On Omarchy, Omabib also installs its shell plugin and systemd service.
# Elsewhere, any omabib command starts the service when it is needed.
omarchy=false
if command -v omarchy >/dev/null && command -v omarchy-shell >/dev/null; then omarchy=true; fi
required=(python3)
if [[ $omarchy == true ]]; then required+=(systemctl); fi
for tool in "${required[@]}"; do
  command -v "$tool" >/dev/null || { echo "Required runtime command missing: $tool" >&2; exit 1; }
done
# Check runtime compatibility and package completeness before changing installed files.
"$binary" --version
files=(skills/omabib/SKILL.md LICENSE)
for helper in "${helpers[@]}"; do files+=("scripts/$helper"); done
if [[ $omarchy == true ]]; then
  files+=(packaging/omabib.service manifest.json plugin/App.qml plugin/BarWidget.qml plugin/Entry.qml
          scripts/omabib-plugin scripts/omabib-close-first)
fi
for file in "${files[@]}"; do [[ -f "$source_dir/$file" ]] || missing "$file"; done
if [[ $omarchy == true ]]; then [[ -d "$source_dir/plugin/components" ]] || missing plugin/components; fi
plugin_id="io.github.atomashevic.omabib"
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$plugin_id"
if [[ $omarchy == false ]]; then backend_only=true; fi
if [[ "$backend_only" == false && -d "$plugin_dir/.git" ]]; then
  echo "This plugin is managed by Omarchy. Use omarchy plugin update $plugin_id, then open Omabib." >&2
  echo "To install only a locally built backend, use --backend-only." >&2
  exit 1
fi
if [[ "$backend_only" == false && -e "$plugin_dir" && ! -f "$plugin_dir/.omabib-managed" ]]; then
  echo "Existing unmanaged Omabib plugin at $plugin_dir; inspect it before installing." >&2
  exit 1
fi
mkdir -p "$bin_dir"
# The standalone app: in a release archive with its own Qt (bin/, lib/,
# plugins/, qml/), otherwise beside the binary or built into build/desktop.
# Once installed, `omabib open` and the shell plugin show Omabib through it.
# A running copy quits, so the next open runs this one.
app_dir="$HOME/.local/lib/omabib"
desktop_binary="$(dirname -- "$binary")/omabib-desktop"
[[ -x "$desktop_binary" ]] || desktop_binary="$source_dir/build/desktop/omabib-desktop"
if [[ -x "$desktop_binary" && -x "$bin_dir/omabib-desktop" ]]; then
  "$bin_dir/omabib-desktop" --quit 2>/dev/null || true
fi
if [[ -f "$source_dir/lib/libQt6Core.so.6" && -x "$source_dir/bin/omabib-desktop" ]]; then
  # The whole app goes to ~/.local/lib/omabib, linked from ~/.local/bin; the
  # app puts its own folder first on PATH, so the helpers live there too.
  rm -rf "$app_dir.new" "$app_dir.old"
  mkdir -p "$app_dir.new"
  cp -r "$source_dir/bin" "$source_dir/lib" "$source_dir/plugins" "$source_dir/qml" "$app_dir.new/"
  for helper in "${helpers[@]}"; do install -m755 "$source_dir/scripts/$helper" "$app_dir.new/bin/$helper"; done
  if [[ -e "$app_dir" ]]; then mv "$app_dir" "$app_dir.old"; fi
  mv "$app_dir.new" "$app_dir"
  rm -rf "$app_dir.old"
  for name in omabib omabib-desktop "${helpers[@]}"; do ln -sfn "$app_dir/bin/$name" "$bin_dir/$name"; done
else
  rm -rf "$app_dir"
  put "$binary" "$bin_dir/omabib" 755
  if [[ -x "$desktop_binary" ]]; then put "$desktop_binary" "$bin_dir/omabib-desktop" 755; fi
  for helper in "${helpers[@]}"; do put "$source_dir/scripts/$helper" "$bin_dir/$helper" 755; done
fi
# A launcher entry and icon, for app menus and docks.
if [[ -x "$bin_dir/omabib-desktop" ]]; then
  entry="$source_dir/share/applications/omabib.desktop"
  [[ -f "$entry" ]] || entry="$source_dir/packaging/omabib.desktop"
  icons="$source_dir/share/icons/hicolor"
  [[ -d "$icons" ]] || icons="$source_dir/packaging/icons/hicolor"
  if [[ -f "$entry" && -d "$icons" ]]; then
    mkdir -p "$data_dir/applications"
    # Every size the launchers and taskbars ask for, and the drawing itself.
    for file in "$icons"/*/apps/omabib.png "$icons/scalable/apps/omabib.svg" "$source_dir/packaging/omabib.svg"; do
      [[ -f $file ]] || continue
      # The size folder above apps/, such as 48x48; the bare drawing is scalable.
      size=scalable
      if [[ $file == */apps/* ]]; then size=${file%/apps/*}; size=${size##*/}; fi
      mkdir -p "$data_dir/icons/hicolor/$size/apps"
      install -m644 "$file" "$data_dir/icons/hicolor/$size/apps/${file##*/}"
    done
    while IFS= read -r line; do
      [[ $line == Exec=* ]] && line="Exec=$bin_dir/omabib-desktop"
      printf '%s\n' "$line"
    done < "$entry" > "$data_dir/applications/omabib.desktop"
    # Launchers that cache icons and entries see the new ones without a new login.
    if command -v gtk-update-icon-cache >/dev/null; then gtk-update-icon-cache -q -f -t "$data_dir/icons/hicolor" || true; fi
    if command -v update-desktop-database >/dev/null; then update-desktop-database -q "$data_dir/applications" || true; fi
  fi
fi
install_shared
if [[ $omarchy == false ]]; then
  echo "Installed Omabib. Open it from your applications, or run: omabib open"
  path_hint
  exit 0
fi

mkdir -p "$HOME/.config/systemd/user"
install -m644 "$source_dir/packaging/omabib.service" "$HOME/.config/systemd/user/omabib.service"
if [[ "$backend_only" == false ]]; then
  mkdir -p "$plugin_dir/scripts"
  install -m644 "$source_dir/manifest.json" "$plugin_dir/manifest.json"
  install -m755 "$source_dir/scripts/omabib-plugin" "$plugin_dir/scripts/omabib-plugin"
  rm -rf "$plugin_dir/plugin.new"
  cp -r "$source_dir/plugin" "$plugin_dir/plugin.new"
  rm -rf "$plugin_dir/plugin"
  mv "$plugin_dir/plugin.new" "$plugin_dir/plugin"
  touch "$plugin_dir/.omabib-managed"
fi
# Older releases still use this helper; newer source trees remove it.
if [[ -f "$source_dir/scripts/omabib-history" ]]; then
  install -m755 "$source_dir/scripts/omabib-history" "$bin_dir/omabib-history"
elif [[ -f "$bin_dir/omabib-history" ]] && grep -q "history_snapshot\|sync_repo\|omabib" "$bin_dir/omabib-history"; then
  rm -f "$bin_dir/omabib-history"
fi
put "$source_dir/scripts/omabib-close-first" "$bin_dir/omabib-close-first" 755
# Zathura page notes moved into Omabib's reader tabs. Remove the old helpers
# only when they are Omabib's own.
for helper in omabib-quick-note omabib-capture-note; do
  if [[ -f "$bin_dir/$helper" ]] && grep -q "Zathura" "$bin_dir/$helper"; then
    rm -f "$bin_dir/$helper"
  fi
done
if [[ "$backend_only" == false ]]; then omarchy plugin validate "$plugin_dir"; fi
systemctl --user daemon-reload
systemctl --user enable --now omabib.service
systemctl --user restart omabib.service
# Retire the old managed UI without deleting its files or the library.
legacy_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/omabib"
if [[ -f "$legacy_dir/.omabib-managed" ]]; then
  omarchy plugin disable omabib
fi
python3 - "$source_dir/manifest.json" <<'PYTHON'
import json, os, pathlib, sys
version = json.loads(pathlib.Path(sys.argv[1]).read_text())["version"]
state = pathlib.Path(os.environ.get("XDG_STATE_HOME") or pathlib.Path.home() / ".local/state") / "omabib/backend.json"
state.parent.mkdir(parents=True, exist_ok=True)
temporary = state.with_suffix(".tmp")
temporary.write_text(json.dumps({"version": version, "plugin_id": "io.github.atomashevic.omabib"}) + "\n")
temporary.replace(state)
PYTHON
if [[ "$backend_only" == false ]]; then
  omarchy-shell shell rescanPlugins
  omarchy plugin enable "$plugin_id"
fi
printf '%s\n' 'Installed Omabib. Open with: omabib open' 'Connect Codex from Settings, or run: omabib-settings register-codex'
