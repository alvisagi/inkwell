#!/bin/bash
# Builds the official Typst documentation site (for the offline docs browser)
# from the matching Typst release and stores it in build/docs-site.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="v0.15.1"
SRC="$ROOT/build/typst-src"
if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$VERSION" https://github.com/typst/typst.git "$SRC"
fi
(cd "$SRC" && cargo docit compile)
rm -rf "$ROOT/build/docs-site"
cp -R "$SRC/docs/dist/site" "$ROOT/build/docs-site"
echo "docs ready: $ROOT/build/docs-site"
