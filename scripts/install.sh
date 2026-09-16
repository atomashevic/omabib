#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
build_dir="${CARGO_TARGET_DIR:-$source_dir/target}"
# MuPDF is compiled from source by the mupdf crate; it needs clang (for bindgen) and make.
for tool in clang make; do
  if ! command -v "$tool" >/dev/null; then
    echo "Building Omabib's PDF reader needs $tool (pacman -S clang make)." >&2
    exit 1
  fi
done
cargo build --release --locked --manifest-path "$source_dir/Cargo.toml"
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/omabib"
if [[ -e "$plugin_dir" && ! -f "$plugin_dir/.omabib-managed" ]]; then
  echo "Existing unmanaged Omabib plugin at $plugin_dir; inspect it before installing." >&2
  exit 1
fi
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user" "$plugin_dir" "$HOME/.codex/skills/omabib"
install -m755 "$build_dir/release/omabib" "$HOME/.local/bin/omabib.new"
mv "$HOME/.local/bin/omabib.new" "$HOME/.local/bin/omabib"
install -m644 "$source_dir/packaging/omabib.service" "$HOME/.config/systemd/user/omabib.service"
install -m644 "$source_dir/plugin/manifest.json" "$source_dir/plugin/App.qml" "$source_dir/plugin/BarWidget.qml" "$plugin_dir/"
# Replace the UI components as a whole so renamed or removed files don't linger.
rm -rf "$plugin_dir/components.new"
cp -r "$source_dir/plugin/components" "$plugin_dir/components.new"
rm -rf "$plugin_dir/components"
mv "$plugin_dir/components.new" "$plugin_dir/components"
touch "$plugin_dir/.omabib-managed"
install -m755 "$source_dir/scripts/omabib-history" "$HOME/.local/bin/omabib-history"
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
omarchy plugin validate "$plugin_dir"
systemctl --user daemon-reload
systemctl --user enable --now omabib.service
systemctl --user restart omabib.service
omarchy-shell shell rescanPlugins
omarchy plugin enable omabib
printf '%s\n' 'Installed Omabib. Open with: omabib open' 'Codex registration: codex mcp add omabib -- ~/.local/bin/omabib mcp'
