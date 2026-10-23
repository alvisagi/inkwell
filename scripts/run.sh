#!/bin/bash
# Relaunches the built app on a folder (default: samples/demo).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pkill -f "Inkwell.app/Contents/MacOS/Inkwell" 2>/dev/null
sleep 0.5
open -a "$ROOT/build/Inkwell.app" "${1:-$ROOT/samples/demo}"
