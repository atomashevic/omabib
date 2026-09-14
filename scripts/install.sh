#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
build_dir="${CARGO_TARGET_DIR:-$source_dir/target}"
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
touch "$plugin_dir/.omabib-managed"
install -m755 "$source_dir/scripts/omabib-history" "$HOME/.local/bin/omabib-history"
install -m644 "$source_dir/skills/omabib/SKILL.md" "$HOME/.codex/skills/omabib/SKILL.md"
omarchy plugin validate "$plugin_dir"
systemctl --user daemon-reload
systemctl --user enable --now omabib.service
systemctl --user restart omabib.service
omarchy-shell shell rescanPlugins
omarchy plugin enable omabib
printf '%s\n' 'Installed Omabib. Open with: omabib open' 'Codex registration: codex mcp add omabib -- ~/.local/bin/omabib mcp'
