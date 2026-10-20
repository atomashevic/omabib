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
# On Omarchy, Super+Alt+B shows or hides the window. One marked block in the
# user's bindings file. A second install does not add another. A file that
# already uses the chord, without our marker, is left as it is.
install_omarchy_key() {
  command -v omarchy >/dev/null 2>&1 || return 0
  local file="$HOME/.config/hypr/bindings.lua"
  local marker="-- omabib-keybind"
  local line='o.bind("SUPER + ALT + B", "Omabib", "omabib open")'
  local told="Show or hide Omabib with Super + Alt + B: $line"
  if [[ -f $file ]] && grep -qF -- "$marker" "$file"; then
    echo "$told"
    return 0
  fi
  if uses_super_alt_b "$file"; then
    echo "Left $file unchanged: it already uses Super + Alt + B and has no Omabib marker."
    return 0
  fi
  mkdir -p "$(dirname -- "$file")"
  if [[ ! -f $file ]]; then
    # Opening comment from Omarchy's config/hypr/bindings.lua, and nothing else.
    printf '%s\n' \
      '-- Keep only your personal keybinding overrides here. Add new bindings with' \
      '-- o.bind or replace defaults with o.rebind.' \
      '' \
      "$marker" \
      "$line" > "$file"
  else
    # Keep a missing final newline from gluing the block onto the last line.
    if [[ -s $file && -n $(tail -c1 "$file") ]]; then
      printf '\n' >> "$file"
    fi
    if [[ -s $file ]]; then
      printf '\n%s\n%s\n' "$marker" "$line" >> "$file"
    else
      printf '%s\n%s\n' "$marker" "$line" > "$file"
    fi
  fi
  echo "$told"
}
# True when a non-comment line binds SUPER + ALT + B. A longer chord such as
# SUPER + SHIFT + ALT + B does not count, and a full-line comment does not.
uses_super_alt_b() {
  local file=$1
  [[ -f $file ]] || return 1
  grep -vE '^[[:space:]]*--' "$file" \
    | grep -qiE 'SUPER[[:space:]]*\+[[:space:]]*ALT[[:space:]]*\+[[:space:]]*B([^[:alnum:]_]|$)'
}
# Release builds link fontconfig and freetype for the command, and OpenGL,
# X11 and xcb for the window. Those come from the distro. Name the packages
# and stop before any installed file is replaced.
append_word() {
  local list=$1 word=$2
  [[ -n $word ]] || { printf '%s' "$list"; return; }
  case " $list " in
    *" $word "*) printf '%s' "$list" ;;
    *) if [[ -n $list ]]; then printf '%s %s' "$list" "$word"; else printf '%s' "$word"; fi ;;
  esac
}
sonames_missing() {
  ldd "$1" 2>/dev/null | awk '/not found/ { print $1 }' || true
}
package_for() {
  local soname=$1
  case $distro in
    apt)
      case $soname in
        libfontconfig.so.1) echo libfontconfig1 ;;
        libfreetype.so.6) echo libfreetype6 ;;
        libGL.so.1) echo libgl1 ;;
        libGLX.so.0) echo libglx0 ;;
        libOpenGL.so.0) echo libopengl0 ;;
        libEGL.so.1) echo libegl1 ;;
        libxkbcommon.so.0) echo libxkbcommon0 ;;
        libX11.so.6) echo libx11-6 ;;
        libX11-xcb.so.1) echo libx11-xcb1 ;;
        libxcb-glx.so.0) echo libxcb-glx0 ;;
        libxcb-randr.so.0) echo libxcb-randr0 ;;
        libxcb-render.so.0) echo libxcb-render0 ;;
        libxcb-shape.so.0) echo libxcb-shape0 ;;
        libxcb-shm.so.0) echo libxcb-shm0 ;;
        libxcb-sync.so.1) echo libxcb-sync1 ;;
        libxcb-xfixes.so.0) echo libxcb-xfixes0 ;;
        libxcb-xkb.so.1) echo libxcb-xkb1 ;;
        libxcb.so.1) echo libxcb1 ;;
        libwayland-client.so.0) echo libwayland-client0 ;;
        libwayland-cursor.so.0) echo libwayland-cursor0 ;;
        libwayland-egl.so.1) echo libwayland-egl1 ;;
        libglib-2.0.so.0 | libgthread-2.0.so.0) echo libglib2.0-0 ;;
        libdbus-1.so.3) echo libdbus-1-3 ;;
        libbrotlidec.so.1) echo libbrotli1 ;;
        libgssapi_krb5.so.2) echo libgssapi-krb5-2 ;;
        *) echo "$soname" ;;
      esac ;;
    dnf)
      case $soname in
        libfontconfig.so.1) echo fontconfig ;;
        libfreetype.so.6) echo freetype ;;
        libGL.so.1 | libGLX.so.0) echo libglvnd-glx ;;
        libOpenGL.so.0) echo libglvnd-opengl ;;
        libEGL.so.1) echo libglvnd-egl ;;
        libxkbcommon.so.0) echo libxkbcommon ;;
        libX11.so.6) echo libX11 ;;
        libX11-xcb.so.1) echo libX11-xcb ;;
        libxcb*.so.*) echo libxcb ;;
        libwayland-client.so.0) echo libwayland-client ;;
        libwayland-cursor.so.0) echo libwayland-cursor ;;
        libwayland-egl.so.1) echo libwayland-egl ;;
        libglib-2.0.so.0 | libgthread-2.0.so.0) echo glib2 ;;
        libdbus-1.so.3) echo dbus-libs ;;
        libbrotlidec.so.1) echo libbrotli ;;
        libgssapi_krb5.so.2) echo krb5-libs ;;
        *) echo "$soname" ;;
      esac ;;
    pacman)
      case $soname in
        libfontconfig.so.1) echo fontconfig ;;
        libfreetype.so.6) echo freetype2 ;;
        libGL.so.1 | libGLX.so.0 | libOpenGL.so.0 | libEGL.so.1) echo libglvnd ;;
        libxkbcommon.so.0) echo libxkbcommon ;;
        libX11.so.6 | libX11-xcb.so.1) echo libx11 ;;
        libxcb*.so.*) echo libxcb ;;
        libwayland*.so.*) echo wayland ;;
        libglib-2.0.so.0 | libgthread-2.0.so.0) echo glib2 ;;
        libdbus-1.so.3) echo dbus ;;
        libbrotlidec.so.1) echo brotli ;;
        libgssapi_krb5.so.2) echo krb5 ;;
        *) echo "$soname" ;;
      esac ;;
    *) echo "$soname" ;;
  esac
}
packages_for() {
  local soname package names=""
  for soname in $1; do
    package=$(package_for "$soname")
    names=$(append_word "$names" "$package")
  done
  [[ -n $names ]] || return 0
  # shellcheck disable=SC2086
  printf '%s\n' $names | sort -u | paste -sd ' ' -
}
install_line() {
  case $distro in
    apt) printf 'sudo apt install %s' "$1" ;;
    dnf) printf 'sudo dnf install %s' "$1" ;;
    pacman) printf 'sudo pacman -S %s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}
require_system_libraries() {
  local binary=$1 bundle=${2:-} distro=""
  [[ $(uname -s) == Linux ]] || return 0
  command -v ldd >/dev/null 2>&1 || return 0
  if command -v apt-get >/dev/null 2>&1; then distro=apt
  elif command -v dnf >/dev/null 2>&1; then distro=dnf
  elif command -v pacman >/dev/null 2>&1; then distro=pacman
  fi
  local cli_sonames="" soname desktop_sonames="" dir paths=()
  while read -r soname; do
    [[ -n $soname ]] || continue
    cli_sonames=$(append_word "$cli_sonames" "$soname")
  done < <(sonames_missing "$binary" | sort -u)
  # fontconfig's own dependency. ldd cannot see it until fontconfig is installed.
  case " $cli_sonames " in
    *" libfontconfig.so.1 "*) cli_sonames=$(append_word "$cli_sonames" "libfreetype.so.6") ;;
  esac
  if [[ -n $bundle ]]; then
    for dir in "$bundle/bin" "$bundle/lib" "$bundle/plugins" "$bundle/qml"; do
      [[ -d $dir ]] && paths+=("$dir")
    done
    if [[ ${#paths[@]} -gt 0 ]]; then
      while read -r soname; do
        [[ -n $soname ]] || continue
        case " $cli_sonames " in
          *" $soname "*) ;;
          *) desktop_sonames=$(append_word "$desktop_sonames" "$soname") ;;
        esac
      done < <(find "${paths[@]}" -type f \( -name 'omabib-desktop' -o -name '*.so' -o -name '*.so.*' \) \
        -exec ldd {} + 2>/dev/null | awk '/not found/ { print $1 }' | sort -u || true)
    fi
  fi
  [[ -n $cli_sonames || -n $desktop_sonames ]] || return 0
  local cli_packages desktop_packages
  cli_packages=$(packages_for "$cli_sonames")
  desktop_packages=$(packages_for "$desktop_sonames")
  echo "Omabib needs libraries this system does not have. Nothing was installed." >&2
  if [[ -n $cli_packages ]]; then
    case " $cli_sonames " in
      *" libfontconfig.so.1 "* | *" libfreetype.so.6 "*)
        echo "The omabib command needs fontconfig and freetype:" >&2 ;;
      *) echo "The omabib command needs:" >&2 ;;
    esac
    echo "  $(install_line "$cli_packages")" >&2
  fi
  if [[ -n $desktop_packages ]]; then
    if [[ -n $cli_packages ]]; then
      echo "The window also needs OpenGL, X11 and xcb:" >&2
    else
      echo "The window needs OpenGL, X11 and xcb:" >&2
    fi
    echo "  $(install_line "$desktop_packages")" >&2
  fi
  echo "Install those packages, then run the installer again." >&2
  exit 1
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
if [[ -f "$source_dir/lib/libQt6Core.so.6" && -x "$source_dir/bin/omabib-desktop" ]]; then
  require_system_libraries "$binary" "$source_dir"
else
  require_system_libraries "$binary"
fi
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
install_omarchy_key
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
