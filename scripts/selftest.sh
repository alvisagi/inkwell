#!/bin/bash
# Runs the in-app editor self-test against a scratch copy of samples/demo.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)/demo"
cp -R "$ROOT/samples/demo" "$WORK"
pkill -f "Inkwell.app/Contents/MacOS/Inkwell" 2>/dev/null
sleep 0.5
LOG="$(mktemp)"
MODE="${1:-1}"
open -W -a "$ROOT/build/Inkwell.app" --env INKWELL_SELFTEST="$MODE" --stderr "$LOG" "$WORK"
grep SELFTEST "$LOG"
grep -q "failures=0" "$LOG"
