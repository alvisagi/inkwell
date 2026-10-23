"""Writes app/Resources/<lang>.lproj/Localizable.strings from translations.py.

Pass a keys.json (from `swiftc -emit-localized-strings`) to list untranslated keys."""
import json, os, sys

sys.path.insert(0, os.path.dirname(__file__))
from translations import LANGS, T

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
RES = os.path.join(ROOT, "app", "Resources")

def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

for i, lang in enumerate(LANGS):
    d = os.path.join(RES, f"{lang}.lproj")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as f:
        for key in sorted(T):
            f.write(f'"{esc(key)}" = "{esc(T[key][i])}";\n')
os.makedirs(os.path.join(RES, "en.lproj"), exist_ok=True)
open(os.path.join(RES, "en.lproj", "Localizable.strings"), "w").write("/* English is the development language. */\n")

if len(sys.argv) > 1:
    keys = json.load(open(sys.argv[1]))
    missing = [k for k in keys if k not in T and any(c.isalpha() for c in k)]
    print("untranslated:", missing)
print("wrote", len(T), "strings for", ", ".join(LANGS))
