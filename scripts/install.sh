#!/usr/bin/env bash
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
for tool in omarchy omarchy-shell systemctl python3; do
  command -v "$tool" >/dev/null || { echo "Required runtime command missing: $tool" >&2; exit 1; }
done
# Check runtime compatibility and package completeness before changing installed files.
"$binary" --version
for file in packaging/omabib.service manifest.json plugin/App.qml plugin/BarWidget.qml plugin/Entry.qml scripts/omabib-plugin \
  scripts/omabib-close-first scripts/omabib-chatgpt scripts/omabib-codex \
  scripts/omabib-overview scripts/omabib-settings scripts/omabib-claude \
  skills/omabib/SKILL.md LICENSE; do
  [[ -f "$source_dir/$file" ]] || { echo "Package is missing $file" >&2; exit 1; }
done
[[ -d "$source_dir/plugin/components" ]] || { echo "Package is missing plugin/components" >&2; exit 1; }
plugin_id="io.github.atomashevic.omabib"
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$plugin_id"
if [[ "$backend_only" == false && -d "$plugin_dir/.git" ]]; then
  echo "This plugin is managed by Omarchy. Use omarchy plugin update $plugin_id, then open Omabib." >&2
  echo "To install only a locally built backend, use --backend-only." >&2
  exit 1
fi
if [[ "$backend_only" == false && -e "$plugin_dir" && ! -f "$plugin_dir/.omabib-managed" ]]; then
  echo "Existing unmanaged Omabib plugin at $plugin_dir; inspect it before installing." >&2
  exit 1
fi
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user" "$HOME/.codex/skills/omabib"
install -m755 "$binary" "$HOME/.local/bin/omabib.new"
mv "$HOME/.local/bin/omabib.new" "$HOME/.local/bin/omabib"
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
  install -m755 "$source_dir/scripts/omabib-history" "$HOME/.local/bin/omabib-history"
elif [[ -f "$HOME/.local/bin/omabib-history" ]] && grep -q "history_snapshot\|sync_repo\|omabib" "$HOME/.local/bin/omabib-history"; then
  rm -f "$HOME/.local/bin/omabib-history"
fi
install -m755 "$source_dir/scripts/omabib-close-first" "$HOME/.local/bin/omabib-close-first"
# Zathura page notes moved into Omabib's reader tabs. Remove the old helpers
# only when they are Omabib's own.
for helper in omabib-quick-note omabib-capture-note; do
  if [[ -f "$HOME/.local/bin/$helper" ]] && grep -q "Zathura" "$HOME/.local/bin/$helper"; then
    rm -f "$HOME/.local/bin/$helper"
  fi
done
install -m755 "$source_dir/scripts/omabib-chatgpt" "$HOME/.local/bin/omabib-chatgpt"
install -m755 "$source_dir/scripts/omabib-codex" "$HOME/.local/bin/omabib-codex"
install -m755 "$source_dir/scripts/omabib-overview" "$HOME/.local/bin/omabib-overview"
install -m755 "$source_dir/scripts/omabib-settings" "$HOME/.local/bin/omabib-settings"
install -m755 "$source_dir/scripts/omabib-claude" "$HOME/.local/bin/omabib-claude"
install -m644 "$source_dir/skills/omabib/SKILL.md" "$HOME/.codex/skills/omabib/SKILL.md"
license_dir="${XDG_DATA_HOME:-$HOME/.local/share}/omabib/licenses"
mkdir -p "$license_dir"
install -m644 "$source_dir/LICENSE" "$license_dir/OMABIB-LICENSE"
if [[ -d "$source_dir/licenses" ]]; then
  cp -r "$source_dir/licenses/." "$license_dir/"
elif [[ -f "$source_dir/src/mitex/LICENSE" ]]; then
  install -m644 "$source_dir/src/mitex/LICENSE" "$license_dir/MITEX-LICENSE"
fi
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
printf '%s\n' 'Installed Omabib. Open with: omabib open' 'Codex registration: codex mcp add omabib -- ~/.local/bin/omabib mcp'
