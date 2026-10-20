#!/usr/bin/env bash
# The installer names missing libraries and writes nothing. Uses a fake ldd
# and a temporary home, never a real library.
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

if command -v apt-get >/dev/null 2>&1; then
  cli_font=libfontconfig1
  cli_free=libfreetype6
  win_gl=libgl1
  win_xcb=libxcb1
  install_prefix='sudo apt install'
elif command -v dnf >/dev/null 2>&1; then
  cli_font=fontconfig
  cli_free=freetype
  win_gl=libglvnd-glx
  win_xcb=libxcb
  install_prefix='sudo dnf install'
elif command -v pacman >/dev/null 2>&1; then
  cli_font=fontconfig
  cli_free=freetype2
  win_gl=libglvnd
  win_xcb=libxcb
  install_prefix='sudo pacman -S'
else
  echo "FAIL: expected apt, dnf or pacman" >&2
  exit 1
fi

bindir=$root/bin
mkdir -p "$bindir"
cat > "$bindir/ldd" <<'EOF'
#!/bin/sh
case "$1" in
  *clean*) exit 0 ;;
  *omabib-desktop | *.so*)
    printf '\tlibGL.so.1 => not found\n\tlibxcb.so.1 => not found\n\tlibX11.so.6 => not found\n'
    exit 1
    ;;
  *)
    printf '\tlibfontconfig.so.1 => not found\n'
    exit 1
    ;;
esac
EOF
cat > "$bindir/omabib" <<'EOF'
#!/bin/sh
echo omabib 0.0.0
EOF
chmod 755 "$bindir/ldd" "$bindir/omabib"

run_install() {
  local home=$1
  shift
  mkdir -p "$home"
  set +e
  out=$(PATH="$bindir:$PATH" HOME="$home" \
    XDG_DATA_HOME="$home/.local/share" XDG_CONFIG_HOME="$home/.config" \
    XDG_STATE_HOME="$home/.local/state" CODEX_HOME="$home/.codex" \
    "$@" 2>&1)
  status=$?
  set -e
}
assert_empty() {
  local home=$1
  if find "$home" -mindepth 1 -print | grep -q .; then
    echo "FAIL: installer wrote into $home" >&2
    find "$home" -mindepth 1 -print >&2
    exit 1
  fi
}
assert_split() {
  local cli_line window_line
  printf '%s\n' "$out" | grep -q 'Nothing was installed' || { echo "FAIL: missing refusal" >&2; printf '%s\n' "$out" >&2; exit 1; }
  printf '%s\n' "$out" | grep -q 'error while loading shared libraries' && { echo "FAIL: raw loader error" >&2; exit 1; }
  mapfile -t lines < <(printf '%s\n' "$out" | grep -E '^  ')
  [[ ${#lines[@]} -eq 2 ]] || { echo "FAIL: expected two package lines" >&2; printf '%s\n' "$out" >&2; exit 1; }
  cli_line=${lines[0]}
  window_line=${lines[1]}
  [[ $cli_line == *" $install_prefix "* && $cli_line == *"$cli_font"* && $cli_line == *"$cli_free"* ]] || {
    echo "FAIL: CLI package line" >&2; printf '%s\n' "$cli_line" >&2; exit 1
  }
  [[ $cli_line != *"$win_gl"* && $window_line == *" $install_prefix "* && $window_line == *"$win_gl"* && $window_line == *"$win_xcb"* ]] || {
    echo "FAIL: window package line" >&2; printf '%s\n' "$window_line" >&2; exit 1
  }
  [[ $window_line != *"$cli_font"* && $window_line != *"$cli_free"* ]] || {
    echo "FAIL: window line lists a CLI package" >&2; printf '%s\n' "$window_line" >&2; exit 1
  }
}

home=$root/home-cli
run_install "$home" "$source_dir/scripts/install.sh" "$bindir/omabib"
[[ $status -ne 0 && $status -ne 127 ]] || { echo "FAIL: CLI exit $status" >&2; printf '%s\n' "$out" >&2; exit 1; }
printf '%s\n' "$out" | grep -q 'fontconfig and freetype' || { echo "FAIL: CLI heading" >&2; exit 1; }
printf '%s\n' "$out" | grep -q "$install_prefix" || { echo "FAIL: no install command" >&2; exit 1; }
printf '%s\n' "$out" | grep -q "$cli_font" || { echo "FAIL: missing $cli_font" >&2; exit 1; }
printf '%s\n' "$out" | grep -q "$cli_free" || { echo "FAIL: missing $cli_free" >&2; exit 1; }
printf '%s\n' "$out" | grep -q 'The window' && { echo "FAIL: CLI-only install mentioned the window" >&2; exit 1; }
assert_empty "$home"

bundle=$root/bundle
mkdir -p "$bundle/scripts" "$bundle/bin" "$bundle/lib" "$bundle/plugins" "$bundle/qml"
cp "$source_dir/scripts/install.sh" "$bundle/scripts/install.sh"
cp "$bindir/omabib" "$bundle/bin/omabib"
cp "$bindir/omabib" "$bundle/bin/omabib-desktop"
printf 'not a library\n' > "$bundle/lib/libQt6Core.so.6"
home=$root/home-bundle
run_install "$home" "$bundle/scripts/install.sh"
[[ $status -eq 1 ]] || { echo "FAIL: bundle exit $status" >&2; printf '%s\n' "$out" >&2; exit 1; }
assert_split
assert_empty "$home"

clean=$root/clean
mkdir -p "$clean/scripts" "$clean/bin"
cp "$source_dir/scripts/install.sh" "$clean/scripts/install.sh"
cp "$bindir/omabib" "$clean/bin/omabib-clean"
home=$root/home-clean
run_install "$home" "$clean/scripts/install.sh" "$clean/bin/omabib-clean"
[[ $status -ne 0 ]] || { echo "FAIL: clean ldd installed an incomplete tree" >&2; exit 1; }
printf '%s\n' "$out" | grep -q 'Package is missing' || { echo "FAIL: expected a missing-file error" >&2; printf '%s\n' "$out" >&2; exit 1; }
printf '%s\n' "$out" | grep -q 'Nothing was installed' && { echo "FAIL: present libraries were reported missing" >&2; exit 1; }
assert_empty "$home"

echo "PASS: missing libraries are named and nothing is installed"
