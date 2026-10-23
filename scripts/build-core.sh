#!/bin/bash
# Builds the Rust core as a static library, generates the UniFFI Swift
# bindings and packages both for the Swift package in app/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
GEN="$ROOT/build/gen"
XCF="$ROOT/app/Frameworks/TypstCoreFFI.xcframework"
PROFILE="${PROFILE:-release}"
export MACOSX_DEPLOYMENT_TARGET=15.0

cd "$CORE"
cargo build --profile "$PROFILE" --lib
LIB="$CORE/target/$PROFILE/libtypst_core.a"
cargo run --quiet --release --bin uniffi-bindgen -- generate \
  --library "$LIB" --language swift --out-dir "$GEN"

# Headers + module map for the C side of the bindings.
HEADERS="$ROOT/build/headers"
rm -rf "$HEADERS" && mkdir -p "$HEADERS"
cp "$GEN/typst_coreFFI.h" "$HEADERS/"
cp "$GEN/typst_coreFFI.modulemap" "$HEADERS/module.modulemap"

rm -rf "$XCF"
xcodebuild -create-xcframework -library "$LIB" -headers "$HEADERS" -output "$XCF" >/dev/null

# Only rewrite the Swift bindings when they changed, to keep builds incremental.
if ! cmp -s "$GEN/typst_core.swift" "$ROOT/app/Sources/TypstCore/typst_core.swift"; then
  cp "$GEN/typst_core.swift" "$ROOT/app/Sources/TypstCore/typst_core.swift"
fi
echo "core ready: $XCF"
