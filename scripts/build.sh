#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# MuPDF is compiled from source; bindgen needs clang.
for tool in cargo clang make; do
  command -v "$tool" >/dev/null || { echo "Building Omabib requires $tool." >&2; exit 1; }
done
cd "$source_dir"
cargo build --release --locked "$@"
