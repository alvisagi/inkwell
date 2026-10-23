//! Rust core of the editor. Everything Typst-related lives here and is exposed
//! to Swift through UniFFI: compilation, the preview display list, IDE
//! features (completion, tooltips, jumps), highlighting, packages and fonts.

mod detypify;
mod display;
mod fonts;
mod packages;
mod syntax;
mod world;

use std::collections::{BTreeMap, HashMap};
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use typst::World;
use typst::diag::{Severity, SourceDiagnostic, Warned};
use typst::layout::{Frame, FrameItem, Point};
use typst_layout::PagedDocument;
use typst::syntax::package::PackageSpec;
use typst::syntax::{FileId, Side, Source, VirtualRoot};
use typst::WorldExt;
use typst_ide::{Jump, Tooltip};

use crate::display::{ImageEntry, Resources};
use crate::world::{ProjectWorld, id_for_path};

uniffi::setup_scaffolding!();

// ---------------------------------------------------------------------------
// Records shared with Swift

#[derive(uniffi::Error, Debug)]
pub enum CoreError {
    Message { message: String },
}

impl fmt::Display for CoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Message { message } => f.write_str(message),
        }
    }
}

impl std::error::Error for CoreError {}

impl CoreError {
    fn msg(message: impl ToString) -> Self {
        Self::Message { message: message.to_string() }
    }
}

#[derive(uniffi::Record, Clone)]
pub struct Diagnostic {
    pub is_error: bool,
    pub message: String,
    pub hints: Vec<String>,
    /// Absolute path of the file the diagnostic points into.
    pub path: Option<String>,
    /// Whether that file belongs to a package (a "library" diagnostic).
    pub in_package: bool,
    /// 1-based line and column (in UTF-16 code units).
    pub line: Option<u32>,
    pub column: Option<u32>,
    /// UTF-16 range in the file.
    pub start: Option<u64>,
    pub end: Option<u64>,
}

impl Diagnostic {
    fn plain(message: String) -> Self {
        Self {
            is_error: true,
            message,
            hints: vec![],
            path: None,
            in_package: false,
            line: None,
            column: None,
            start: None,
            end: None,
        }
    }
}

#[derive(uniffi::Record, Clone)]
pub struct PageInfo {
    pub width: f64,
    pub height: f64,
    /// Changes whenever the page's content changes.
    pub hash: String,
}

#[derive(uniffi::Record)]
pub struct CompileReport {
    /// False if compilation failed; the previous pages then stay valid.
    pub success: bool,
    pub pages: Vec<PageInfo>,
    pub diagnostics: Vec<Diagnostic>,
    pub duration_ms: f64,
    pub word_count: u64,
    pub character_count: u64,
}

#[derive(uniffi::Enum)]
pub enum ClickTarget {
    Source { path: String, offset: u64 },
    Url { url: String },
    Position { page: u32, x: f64, y: f64 },
}

#[derive(uniffi::Record)]
pub struct PreviewPosition {
    /// 0-based page index.
    pub page: u32,
    pub x: f64,
    pub y: f64,
}

#[derive(uniffi::Record)]
pub struct CompletionItem {
    pub kind: String,
    pub label: String,
    /// Snippet syntax: `${name}` placeholders.
    pub apply: Option<String>,
    pub detail: Option<String>,
    /// For symbol completions: the symbol's text.
    pub symbol: Option<String>,
}

#[derive(uniffi::Record)]
pub struct Completions {
    /// UTF-16 offset where the completed text starts.
    pub from: u64,
    pub items: Vec<CompletionItem>,
}

#[derive(uniffi::Record)]
pub struct TooltipInfo {
    pub text: String,
    pub is_code: bool,
}

#[derive(uniffi::Record)]
pub struct ImageData {
    pub width: u32,
    pub height: u32,
    /// True: premultiplied RGBA8. False: an encoded image file.
    pub rgba: bool,
    pub bytes: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct DefinitionTarget {
    pub path: String,
    pub offset: u64,
}

// ---------------------------------------------------------------------------
// Project

struct Inner {
    world: ProjectWorld,
    document: Option<Arc<PagedDocument>>,
    resources: Resources,
    /// Display lists of the current document, built lazily.
    page_cache: HashMap<u128, Arc<Vec<u8>>>,
}

#[derive(uniffi::Object)]
pub struct Project {
    inner: Mutex<Inner>,
}

impl Project {
    /// Locks the project state, recovering from a panic in an earlier call.
    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// Runs `f`, turning a panic inside Typst into `fallback` instead of
/// aborting the app.
fn guarded<T>(fallback: impl FnOnce() -> T, f: impl FnOnce() -> T) -> T {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(value) => value,
        Err(_) => fallback(),
    }
}

#[uniffi::export]
impl Project {
    /// Opens a project rooted at `root` (a folder).
    #[uniffi::constructor]
    pub fn new(root: String) -> Arc<Self> {
        let world = ProjectWorld::new(PathBuf::from(root));
        Arc::new(Self {
            inner: Mutex::new(Inner {
                world,
                document: None,
                resources: Resources::default(),
                page_cache: HashMap::new(),
            }),
        })
    }

    /// Chooses the file that is compiled.
    pub fn set_main(&self, path: String) -> Result<(), CoreError> {
        let mut inner = self.lock();
        let id = id_for_path(inner.world.root(), Path::new(&path)).map_err(CoreError::msg)?;
        inner.world.set_main(id);
        Ok(())
    }

    /// Provides the editor's (possibly unsaved) text for a file.
    pub fn set_text(&self, path: String, text: String) {
        let mut inner = self.lock();
        if let Ok(id) = id_for_path(inner.world.root(), Path::new(&path)) {
            inner.world.set_overlay(id, &text);
        }
    }

    /// Stops overriding a file's disk contents.
    pub fn clear_text(&self, path: String) {
        let mut inner = self.lock();
        if let Ok(id) = id_for_path(inner.world.root(), Path::new(&path)) {
            inner.world.remove_overlay(id);
        }
    }

    /// Forgets cached disk contents after external changes.
    pub fn invalidate_files(&self) {
        self.lock().world.invalidate();
    }

    pub fn compile(&self) -> CompileReport {
        guarded(
            || CompileReport {
                success: false,
                pages: vec![],
                diagnostics: vec![Diagnostic::plain("The compiler crashed. Please report this document.".into())],
                duration_ms: 0.0,
                word_count: 0,
                character_count: 0,
            },
            || self.compile_inner(),
        )
    }

    pub fn display_list(&self, page: u32) -> Vec<u8> {
        guarded(Vec::new, || self.display_list_inner(page))
    }

    pub fn complete(&self, path: String, offset: u64, explicit: bool) -> Option<Completions> {
        guarded(|| None, || self.complete_inner(path, offset, explicit))
    }

    pub fn tooltip(&self, path: String, offset: u64) -> Option<TooltipInfo> {
        guarded(|| None, || self.tooltip_inner(path, offset))
    }

    pub fn click(&self, page: u32, x: f64, y: f64) -> Option<ClickTarget> {
        guarded(|| None, || self.click_inner(page, x, y))
    }

    pub fn cursor_positions(&self, path: String, offset: u64) -> Vec<PreviewPosition> {
        guarded(Vec::new, || self.cursor_positions_inner(path, offset))
    }

    pub fn definition(&self, path: String, offset: u64) -> Option<DefinitionTarget> {
        guarded(|| None, || self.definition_inner(path, offset))
    }
}

impl Project {
    fn compile_inner(&self) -> CompileReport {
        let start = std::time::Instant::now();
        let mut inner = self.lock();
        inner.world.prepare();

        let Warned { output, warnings } = typst::compile::<PagedDocument>(&inner.world);
        let mut diagnostics: Vec<Diagnostic> =
            warnings.iter().map(|d| convert_diagnostic(&inner.world, d)).collect();

        let success = match output {
            Ok(document) => {
                let document = Arc::new(document);
                // Keep only display lists for pages that still exist.
                let live: Vec<u128> =
                    document.pages().iter().map(|p| typst::utils::hash128(&p.frame)).collect();
                inner.page_cache.retain(|k, _| live.contains(k));
                inner.document = Some(document);
                true
            }
            Err(errors) => {
                let errors: Vec<Diagnostic> =
                    errors.iter().map(|d| convert_diagnostic(&inner.world, d)).collect();
                diagnostics.splice(0..0, errors);
                false
            }
        };

        typst::comemo::evict(10);

        let (pages, word_count, character_count) = match &inner.document {
            Some(document) => {
                let pages = document
                    .pages()
                    .iter()
                    .map(|page| PageInfo {
                        width: page.frame.width().to_pt(),
                        height: page.frame.height().to_pt(),
                        hash: format!("{:032x}", typst::utils::hash128(&page.frame)),
                    })
                    .collect();
                let mut text = String::new();
                for page in document.pages() {
                    collect_text(&page.frame, &mut text);
                }
                let words = text.split_whitespace().count() as u64;
                let chars = text.chars().filter(|c| !c.is_whitespace()).count() as u64;
                (pages, words, chars)
            }
            None => (Vec::new(), 0, 0),
        };

        CompileReport {
            success,
            pages,
            diagnostics,
            duration_ms: start.elapsed().as_secs_f64() * 1000.0,
            word_count,
            character_count,
        }
    }

    fn display_list_inner(&self, page: u32) -> Vec<u8> {
        let mut inner = self.lock();
        let Some(document) = inner.document.clone() else { return Vec::new() };
        let Some(page) = document.pages().get(page as usize) else { return Vec::new() };
        let key = typst::utils::hash128(&page.frame);
        if let Some(list) = inner.page_cache.get(&key) {
            return list.as_ref().clone();
        }
        let list = Arc::new(display::encode_page(&mut inner.resources, page));
        inner.page_cache.insert(key, list.clone());
        list.as_ref().clone()
    }

    fn click_inner(&self, page: u32, x: f64, y: f64) -> Option<ClickTarget> {
        let inner = self.lock();
        let document = inner.document.clone()?;
        let page = document.pages().get(page as usize)?;
        let point = Point::new(typst::layout::Abs::pt(x), typst::layout::Abs::pt(y));
        let jump = typst_ide::jump_from_click_in_frame(&inner.world, &*document, &page.frame, point)?;
        Some(match jump {
            Jump::File(id, offset) => {
                let source = inner.world.source(id).ok()?;
                let path = inner.world.path_of(id)?;
                ClickTarget::Source {
                    path: path.to_string_lossy().into_owned(),
                    offset: source.lines().byte_to_utf16(offset)? as u64,
                }
            }
            Jump::Url(url) => ClickTarget::Url { url: url.to_string() },
            Jump::Position(pos) => ClickTarget::Position {
                page: pos.page.get() as u32 - 1,
                x: pos.point.x.to_pt(),
                y: pos.point.y.to_pt(),
            },
        })
    }

    fn cursor_positions_inner(&self, path: String, offset: u64) -> Vec<PreviewPosition> {
        let inner = self.lock();
        let Some(document) = inner.document.clone() else { return vec![] };
        let Some((source, byte)) = inner.source_at(&path, offset) else { return vec![] };
        typst_ide::jump_from_cursor(&*document, &source, byte)
            .into_iter()
            .map(|pos| PreviewPosition {
                page: pos.page.get() as u32 - 1,
                x: pos.point.x.to_pt(),
                y: pos.point.y.to_pt(),
            })
            .collect()
    }

    fn complete_inner(&self, path: String, offset: u64, explicit: bool) -> Option<Completions> {
        let inner = self.lock();
        let (source, byte) = inner.source_at(&path, offset)?;
        let document = inner.document.clone();
        let (from, items) =
            typst_ide::autocomplete(&inner.world, document.as_deref(), &source, byte, explicit)?;
        Some(Completions {
            from: source.lines().byte_to_utf16(from)? as u64,
            items: items
                .into_iter()
                .map(|c| {
                    let (kind, symbol) = match &c.kind {
                        typst_ide::CompletionKind::Syntax => ("syntax", None),
                        typst_ide::CompletionKind::Func => ("function", None),
                        typst_ide::CompletionKind::Type => ("type", None),
                        typst_ide::CompletionKind::Param => ("param", None),
                        typst_ide::CompletionKind::Constant => ("constant", None),
                        typst_ide::CompletionKind::Path => ("path", None),
                        typst_ide::CompletionKind::Package => ("package", None),
                        typst_ide::CompletionKind::Label => ("label", None),
                        typst_ide::CompletionKind::Font => ("font", None),
                        typst_ide::CompletionKind::Symbol(s) => ("symbol", Some(s.to_string())),
                    };
                    CompletionItem {
                        kind: kind.into(),
                        label: c.label.to_string(),
                        apply: c.apply.map(|a| a.to_string()),
                        detail: c.detail.map(|d| d.to_string()),
                        symbol,
                    }
                })
                .collect(),
        })
    }

    fn tooltip_inner(&self, path: String, offset: u64) -> Option<TooltipInfo> {
        let inner = self.lock();
        let (source, byte) = inner.source_at(&path, offset)?;
        let document = inner.document.clone();
        match typst_ide::tooltip(&inner.world, document.as_deref(), &source, byte, Side::After)? {
            Tooltip::Text(text) => Some(TooltipInfo { text: text.to_string(), is_code: false }),
            Tooltip::Code(code) => Some(TooltipInfo { text: code.to_string(), is_code: true }),
        }
    }

    fn definition_inner(&self, path: String, offset: u64) -> Option<DefinitionTarget> {
        let inner = self.lock();
        let (source, byte) = inner.source_at(&path, offset)?;
        let document = inner.document.clone();
        let def = typst_ide::definition(&inner.world, document.as_deref(), &source, byte, Side::Before)?;
        let (id, byte) = match def {
            typst_ide::Definition::Span(span) => (span.id()?, inner.world.range(span)?.start),
            typst_ide::Definition::File(id) => (id, 0),
            typst_ide::Definition::Std(_) => return None,
        };
        let target = inner.world.source(id).ok()?;
        Some(DefinitionTarget {
            path: inner.world.path_of(id)?.to_string_lossy().into_owned(),
            offset: target.lines().byte_to_utf16(byte)? as u64,
        })
    }

}

#[uniffi::export]
impl Project {
    /// The display list of a page of the last successful compilation.
    /// Outlines of glyphs in a font referenced by a display list.
    pub fn glyph_outlines(&self, font: u32, glyphs: Vec<u16>) -> Vec<u8> {
        self.lock().resources.glyph_outlines(font, &glyphs)
    }

    /// An image referenced by a display list.
    pub fn image(&self, id: u32) -> Option<ImageData> {
        let inner = self.lock();
        Some(match inner.resources.image_list.get(id as usize)? {
            ImageEntry::Encoded(bytes) => {
                ImageData { width: 0, height: 0, rgba: false, bytes: bytes.as_slice().to_vec() }
            }
            ImageEntry::Rgba { width, height, data } => ImageData {
                width: *width,
                height: *height,
                rgba: true,
                bytes: data.as_ref().clone(),
            },
        })
    }

    /// Resolves a click in the preview (page is 0-based, coordinates in pt).
    /// Where the text at a cursor position ended up in the preview.
    /// Autocompletion at a UTF-16 offset of a file.
    /// Hover information at a UTF-16 offset of a file.
    /// Go-to-definition for the identifier at a UTF-16 offset.
    /// Exports the last successful compilation as PDF.
    pub fn export_pdf(&self, destination: String) -> Result<(), CoreError> {
        guarded(
            || Err(CoreError::msg("The exporter crashed")),
            || {
        let inner = self.lock();
        let document = inner.document.clone().ok_or_else(|| CoreError::msg("Nothing to export yet"))?;
        let bytes = typst_pdf::pdf(&document, &typst_pdf::PdfOptions::default()).map_err(|errors| {
            CoreError::msg(errors.iter().map(|e| e.message.to_string()).collect::<Vec<_>>().join("\n"))
        })?;
        std::fs::write(&destination, bytes).map_err(CoreError::msg)
            },
        )
    }

    /// Exports one page as PNG at the given pixels per point.
    pub fn export_png(&self, page: u32, pixel_per_pt: f32, destination: String) -> Result<(), CoreError> {
        guarded(
            || Err(CoreError::msg("The exporter crashed")),
            || {
        let inner = self.lock();
        let document = inner.document.clone().ok_or_else(|| CoreError::msg("Nothing to export yet"))?;
        let page = document.pages().get(page as usize).ok_or_else(|| CoreError::msg("No such page"))?;
        let options = typst_render::RenderOptions { pixel_per_pt: (pixel_per_pt as f64).into(), render_bleed: false };
        let pixmap = typst_render::render(page, &options);
        let png = pixmap.encode_png().map_err(CoreError::msg)?;
        std::fs::write(&destination, png).map_err(CoreError::msg)
            },
        )
    }

    /// Exports one page as SVG.
    pub fn export_svg(&self, page: u32, destination: String) -> Result<(), CoreError> {
        guarded(
            || Err(CoreError::msg("The exporter crashed")),
            || {
        let inner = self.lock();
        let document = inner.document.clone().ok_or_else(|| CoreError::msg("Nothing to export yet"))?;
        let page = document.pages().get(page as usize).ok_or_else(|| CoreError::msg("No such page"))?;
        let svg = typst_svg::svg(page, &Default::default());
        std::fs::write(&destination, svg).map_err(CoreError::msg)
            },
        )
    }

    /// Supplies known Universe packages for import completions.
    pub fn set_package_index(&self, entries: Vec<UniversePackage>) {
        let index = entries
            .into_iter()
            .filter_map(|e| {
                let spec: PackageSpec = format!("@preview/{}:{}", e.name, e.version).parse().ok()?;
                Some((spec, e.description.map(Into::into)))
            })
            .collect();
        self.lock().world.package_index = index;
    }
}

impl Inner {
    /// Returns the current source of a file and converts a UTF-16 offset in
    /// it to a byte offset.
    fn source_at(&self, path: &str, offset: u64) -> Option<(Source, usize)> {
        let id: FileId = id_for_path(self.world.root(), Path::new(path)).ok()?;
        let source = self.world.source(id).ok()?;
        let byte = source.lines().utf16_to_byte(offset as usize)?;
        Some((source, byte))
    }
}

fn convert_diagnostic(world: &ProjectWorld, diag: &SourceDiagnostic) -> Diagnostic {
    let mut out = Diagnostic::plain(diag.message.to_string());
    out.is_error = diag.severity == Severity::Error;
    out.hints = diag.hints.iter().map(|h| h.v.to_string()).collect();
    if let Some(id) = diag.span.id() {
        out.in_package = matches!(id.get().root(), VirtualRoot::Package(_));
        out.path = world.path_of(id).map(|p| p.to_string_lossy().into_owned());
        if let (Some(range), Ok(source)) = (world.range(diag.span), world.source(id)) {
            let lines = source.lines();
            if let Some((line, _)) = lines.byte_to_line_column(range.start) {
                out.line = Some(line as u32 + 1);
                let line_start = lines.line_to_byte(line).unwrap_or(0);
                let col = lines.byte_to_utf16(range.start).unwrap_or(0)
                    - lines.byte_to_utf16(line_start).unwrap_or(0);
                out.column = Some(col as u32 + 1);
            }
            out.start = lines.byte_to_utf16(range.start).map(|v| v as u64);
            out.end = lines.byte_to_utf16(range.end).map(|v| v as u64);
        }
    }
    out
}

fn collect_text(frame: &Frame, out: &mut String) {
    for (_, item) in frame.items() {
        match item {
            FrameItem::Group(group) => collect_text(&group.frame, out),
            FrameItem::Text(text) => {
                out.push_str(&text.text);
                out.push(' ');
            }
            _ => {}
        }
    }
}

// ---------------------------------------------------------------------------
// Free functions

/// Syntax highlighting: packed `[u32 start, u32 len, u8 tag]` in UTF-16 units.
#[uniffi::export]
pub fn highlight(text: String) -> Vec<u8> {
    syntax::highlight(&text)
}

/// Headings in a file's source.
#[uniffi::export]
pub fn outline(text: String) -> Vec<syntax::OutlineItem> {
    syntax::outline(&text)
}

/// All `sym` and `emoji` symbols.
#[uniffi::export]
pub fn symbols() -> Vec<syntax::SymbolEntry> {
    syntax::symbols()
}

#[uniffi::export]
pub fn typst_version() -> String {
    "0.15.1".into()
}

#[uniffi::export]
pub fn font_families() -> Vec<String> {
    fonts::shared().families.clone()
}

#[uniffi::export]
pub fn reload_fonts() {
    fonts::reload();
}

/// Adds a folder whose fonts are available in every project.
#[uniffi::export]
pub fn add_font_dir(path: String) {
    fonts::add_dir(PathBuf::from(path));
}

/// Registers local package namespaces: namespace -> folder.
#[uniffi::export]
pub fn set_namespaces(namespaces: HashMap<String, String>) {
    packages::set_namespaces(
        namespaces.into_iter().map(|(k, v)| (k, PathBuf::from(v))).collect::<BTreeMap<_, _>>(),
    );
}

#[derive(uniffi::Record)]
pub struct DownloadedPackage {
    pub name: String,
    pub version: String,
    pub path: String,
}

#[uniffi::export]
pub fn downloaded_packages() -> Vec<DownloadedPackage> {
    packages::downloaded()
        .into_iter()
        .map(|(name, version, path)| DownloadedPackage {
            name,
            version,
            path: path.to_string_lossy().into_owned(),
        })
        .collect()
}

#[uniffi::export]
pub fn delete_package(path: String) -> Result<(), CoreError> {
    packages::delete(Path::new(&path)).map_err(CoreError::msg)
}

/// Downloads a package by spec, e.g. `@preview/cetz:0.3.1`.
#[uniffi::export]
pub fn download_package(spec: String) -> Result<String, CoreError> {
    let spec: PackageSpec = spec.trim().parse().map_err(CoreError::msg)?;
    let dir = packages::obtain(&spec).map_err(CoreError::msg)?;
    Ok(dir.to_string_lossy().into_owned())
}

#[derive(uniffi::Record, Clone)]
pub struct UniversePackage {
    pub name: String,
    pub version: String,
    pub description: Option<String>,
    pub authors: Vec<String>,
    pub keywords: Vec<String>,
    pub categories: Vec<String>,
    pub template_path: Option<String>,
    pub template_entrypoint: Option<String>,
    pub thumbnail: Option<String>,
}

/// Fetches the latest version of every Typst Universe package.
#[uniffi::export]
pub fn fetch_universe() -> Result<Vec<UniversePackage>, CoreError> {
    let entries = packages::fetch_index().map_err(CoreError::msg)?;
    let base = packages::universe_url();
    Ok(packages::latest_only(entries)
        .into_iter()
        .map(|e| UniversePackage {
            thumbnail: e.template.as_ref().and_then(|t| t.thumbnail.as_ref()).map(|_| {
                format!("{base}/preview/thumbnails/{}-{}-small.webp", e.name, e.version)
            }),
            template_path: e.template.as_ref().map(|t| t.path.clone()),
            template_entrypoint: e.template.as_ref().map(|t| t.entrypoint.clone()),
            name: e.name,
            version: e.version,
            description: e.description,
            authors: e.authors,
            keywords: e.keywords,
            categories: e.categories,
        })
        .collect())
}

/// Copies a template into `destination` and returns the entrypoint's path.
#[uniffi::export]
pub fn create_from_template(
    name: String,
    version: String,
    template_path: String,
    entrypoint: String,
    destination: String,
) -> Result<String, CoreError> {
    let spec: PackageSpec = format!("@preview/{name}:{version}").parse().map_err(CoreError::msg)?;
    let dest = PathBuf::from(destination);
    packages::instantiate_template(&spec, &template_path, &dest).map_err(CoreError::msg)?;
    Ok(dest.join(entrypoint).to_string_lossy().into_owned())
}

/// Plain HTTPS GET (for thumbnails).
#[uniffi::export]
pub fn http_get(url: String) -> Result<Vec<u8>, CoreError> {
    packages::download(&url).map_err(CoreError::msg)
}

#[uniffi::export]
pub fn package_cache_dir() -> Option<String> {
    packages::cache_dir().map(|p| p.to_string_lossy().into_owned())
}

#[uniffi::export]
pub fn package_data_dir() -> Option<String> {
    packages::data_dir().map(|p| p.to_string_lossy().into_owned())
}

/// Recognizes a hand-drawn symbol. `strokes` holds `[x, y]` pairs per stroke
/// (flattened). Returns `sym` names, best first.
#[uniffi::export]
pub fn recognize_symbol(strokes: Vec<Vec<f32>>, limit: u32) -> Vec<String> {
    let strokes: Vec<Vec<[f32; 2]>> = strokes
        .into_iter()
        .map(|flat| flat.chunks_exact(2).map(|p| [p[0], p[1]]).collect())
        .collect();
    detypify::recognize(&strokes, limit as usize)
}
