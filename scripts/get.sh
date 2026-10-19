#!/bin/sh
# Installs Omabib for this user:
#   curl -fsSL https://github.com/atomashevic/omabib/releases/latest/download/get.sh | sh
# Downloads the release built for this computer, checks it against the
# release's SHA256SUMS, and runs the installer inside it. It needs no
# administrator access and changes nothing outside your home folder.
#   OMABIB_VERSION=v0.2.0    install that release instead
#   OMABIB_DOWNLOAD_URL=...  where the archives are, such as file:///path/to/dist
set -eu
repo=atomashevic/omabib
# A published copy names its own release here.
release=""

fail() {
  printf 'omabib: %s\n' "$*" >&2
  exit 1
}

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64 | Linux-amd64) platform=linux-x86_64 ;;
  Darwin-arm64) platform=macos-arm64 ;;
  Darwin-x86_64) fail "Omabib for macOS needs a Mac with Apple silicon (M1 or later)." ;;
  *) fail "There is no Omabib build for $(uname -s) $(uname -m) yet. See https://github.com/$repo#build-from-source" ;;
esac
for tool in curl tar; do
  command -v "$tool" >/dev/null 2>&1 || fail "Installing Omabib needs $tool."
done

version=${OMABIB_VERSION:-$release}
if [ -z "$version" ]; then
  # GitHub redirects /releases/latest to the latest release's tag.
  version=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest") ||
    fail "Could not reach GitHub."
  version=${version##*/}
fi
case $version in
  v[0-9]*) ;;
  *) fail "No Omabib release found." ;;
esac
base=${OMABIB_DOWNLOAD_URL:-https://github.com/$repo/releases/download/$version}
name="omabib-${version#v}-$platform"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 1' INT TERM
printf 'Downloading Omabib %s for %s\n' "$version" "$platform"
curl -fL --progress-bar "$base/$name.tar.gz" -o "$work/$name.tar.gz" || fail "Could not download $base/$name.tar.gz"
curl -fsSL "$base/SHA256SUMS" -o "$work/SHA256SUMS" || fail "Could not download $base/SHA256SUMS"
expected=$(awk -v file="$name.tar.gz" '$2 == file { print $1 }' "$work/SHA256SUMS")
[ -n "$expected" ] || fail "SHA256SUMS lists no $name.tar.gz."
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$work/$name.tar.gz" | awk '{ print $1 }')
else
  actual=$(shasum -a 256 "$work/$name.tar.gz" | awk '{ print $1 }')
fi
[ "$actual" = "$expected" ] || fail "The download was incomplete or changed. Please try again."
tar -xzf "$work/$name.tar.gz" -C "$work"

# An Omarchy plugin added with `omarchy plugin add` stays Omarchy's to update.
flags=""
plugin="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/io.github.atomashevic.omabib"
if [ -d "$plugin/.git" ]; then flags=--backend-only; fi
# shellcheck disable=SC2086
"$work/$name/scripts/install.sh" $flags
