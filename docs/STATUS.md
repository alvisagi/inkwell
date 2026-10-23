# Inkwell — Edist replica status

Goal: a 1:1 functional replica of Edist 1.4 (macOS Typst editor), built as a
SwiftUI/AppKit app on a Rust core (Typst 0.15.1 via UniFFI).

## Layout
- `core/` Rust crate `typst_core` (staticlib + UniFFI bindings)
  - `world.rs` project World (disk files + unsaved overlays, packages)
  - `display.rs` page → binary display list (glyph outlines, images, paints)
  - `syntax.rs` highlighting, outline, symbols
  - `packages.rs` Universe index/downloads, namespaces, templates
  - `detypify.rs` hand-drawn symbol recognition (ONNX via tract)
  - `tests/smoke.rs` end-to-end checks
- `app/` Swift package `Inkwell` (macOS 15+)
- `scripts/build-core.sh` → `app/Frameworks/TypstCoreFFI.xcframework` + bindings
- `scripts/build-docs.sh` → `build/docs-site` (official docs, bundled offline)
- `scripts/bundle.sh [debug|release]` → `build/Inkwell.app`
- `scripts/run.sh [folder]` relaunch on a folder

## Feature checklist (from Edist's UI, menus and strings)
Done:
- Welcome window (open folder / template / file, recent projects)
- Project window: sidebar (files, find, outline, symbols, diagnostics), editor, live preview, split sides
- Vector preview from display lists; zoom, fit/lock, page indicator + jump, click→source with ripple, follow caret
- Lock preview to file, live preview toggle, detach preview window, export PDF / in place
- Editor: TextKit 2, highlighting, line numbers (relative in Vim), current line, rounded selection, animated caret,
  autocomplete with snippets, hover tooltips, cmd-click definition, auto-close, list continuation, comment/duplicate,
  bold/italic/underline/heading/list/math commands, font size, spell check limited to prose, Vim mode, typing sounds
- Tabs, autosave, external change conflict banner, save error banner, diagnostics banner
- File ops: new file/folder, from clipboard, rename, duplicate, trash, show in Finder, folder from selection
- Project find/replace (containing / word / prefix / regex, match case)
- Symbols: search grid + Draw recognition (Detypify)
- Bibliography (.bib) entry editor + raw source
- Images / PDFs viewer
- Templates gallery from Typst Universe
- Settings: General, Editor (fonts, 7 themes, toggles, Vim, sounds), Packages (download/delete, namespaces)
- Offline Typst documentation browser (+ "Show Documentation" from editor)
- Older Typst compilers (0.11–0.14) downloaded on demand, compiled via their CLI
- Preview Gallery Mode, docs "Copy as Markdown", Developer settings section
- App icon, localizations (zh-Hans, de, fr, es, it, nl, pt), What's New, About credits
- Panic-safe core entry points

Not replicated on purpose:
- License / trial / App Store purchase, Sparkle auto-update (no update server)
- Sandbox security-scoped bookmarks (the app is not sandboxed)

Differences:
- Typing sounds are synthesized instead of recorded samples
- Docs browser shows the official docs site offline (WebKit) instead of a native renderer
