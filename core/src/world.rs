//! The `World` behind a project window: files come from disk, unless the
//! editor holds an unsaved buffer for them, in which case that text wins.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

use typst::diag::{FileError, FileResult};
use typst::foundations::{Bytes, Datetime, Dict, Duration};
use typst::syntax::package::PackageSpec;
use typst::syntax::{FileId, RootedPath, Source, VirtualPath, VirtualRoot};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Library, LibraryExt, World};
use typst_ide::IdeWorld;
use typst_kit::datetime::Time;

use crate::fonts::{self, SharedFonts};
use crate::packages;

/// A file loaded from disk, kept around until its modification time changes.
struct Slot {
    modified: Option<SystemTime>,
    source: Option<FileResult<Source>>,
    bytes: Option<FileResult<Bytes>>,
}

pub struct ProjectWorld {
    root: PathBuf,
    library: LazyHash<Library>,
    fonts: Arc<SharedFonts>,
    main: FileId,
    time: Time,
    /// Unsaved editor buffers, keyed by file.
    overlays: HashMap<FileId, Source>,
    slots: Mutex<HashMap<FileId, Slot>>,
    /// Known `@preview` packages, for completions.
    pub package_index: Vec<(PackageSpec, Option<typst::ecow::EcoString>)>,
}

impl ProjectWorld {
    pub fn new(root: PathBuf) -> Self {
        let root = canonicalize_lenient(&root);
        let main = id_for_path(&root, &root.join("main.typ")).expect("valid main path");
        Self {
            root,
            library: LazyHash::new(Library::builder().with_inputs(Dict::new()).build()),
            fonts: fonts::shared(),
            main,
            time: Time::system(),
            overlays: HashMap::new(),
            slots: Mutex::new(HashMap::new()),
            package_index: Vec::new(),
        }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn set_main(&mut self, id: FileId) {
        self.main = id;
    }

    /// Called before every compilation so that the date and fonts are fresh.
    pub fn prepare(&mut self) {
        self.time.reset();
        self.fonts = fonts::shared();
    }

    pub fn set_overlay(&mut self, id: FileId, text: &str) {
        match self.overlays.get_mut(&id) {
            Some(source) => {
                if source.text() != text {
                    source.replace(text);
                }
            }
            None => {
                // Start from the cached disk version if there is one, so that
                // its syntax tree can be reused incrementally.
                let mut source = Source::new(id, String::new());
                if let Some(Slot { source: Some(Ok(cached)), .. }) =
                    self.slots.get_mut().unwrap().get(&id)
                {
                    source = cached.clone();
                }
                source.replace(text);
                self.overlays.insert(id, source);
            }
        }
    }

    pub fn remove_overlay(&mut self, id: FileId) {
        self.overlays.remove(&id);
    }

    /// Forgets cached disk contents, e.g. after files changed externally.
    pub fn invalidate(&mut self) {
        self.slots.get_mut().unwrap().clear();
    }

    pub fn path_of(&self, id: FileId) -> Option<PathBuf> {
        path_for_id(&self.root, id).ok()
    }

    fn modified(path: &Path) -> Option<SystemTime> {
        std::fs::metadata(path).and_then(|m| m.modified()).ok()
    }

    fn read_bytes(&self, id: FileId) -> FileResult<Bytes> {
        let path = path_for_id(&self.root, id)?;
        if path.is_dir() {
            return Err(FileError::IsDirectory);
        }
        std::fs::read(&path).map(Bytes::new).map_err(|err| FileError::from_io(err, &path))
    }

    fn slot<T>(&self, id: FileId, f: impl FnOnce(&mut Slot, &Self) -> T) -> T {
        let path = path_for_id(&self.root, id).ok();
        let modified = path.as_deref().and_then(Self::modified);
        let mut slots = self.slots.lock().unwrap();
        let slot = slots.entry(id).or_insert(Slot { modified, source: None, bytes: None });
        if slot.modified != modified {
            *slot = Slot { modified, source: None, bytes: None };
        }
        f(slot, self)
    }
}

impl World for ProjectWorld {
    fn library(&self) -> &LazyHash<Library> {
        &self.library
    }

    fn book(&self) -> &LazyHash<FontBook> {
        self.fonts.store.book()
    }

    fn main(&self) -> FileId {
        self.main
    }

    fn source(&self, id: FileId) -> FileResult<Source> {
        if let Some(source) = self.overlays.get(&id) {
            return Ok(source.clone());
        }
        self.slot(id, |slot, world| {
            let bytes = slot.bytes.get_or_insert_with(|| world.read_bytes(id)).clone();
            let fresh = |bytes: Bytes| -> FileResult<Source> {
                let text = std::str::from_utf8(&bytes).map_err(|_| FileError::InvalidUtf8)?;
                // Strip a byte-order mark if present.
                Ok(Source::new(id, text.trim_start_matches('\u{feff}').into()))
            };
            match (&mut slot.source, bytes) {
                (Some(Ok(_)), Ok(_)) => {}
                (source, Ok(bytes)) => *source = Some(fresh(bytes)),
                (source, Err(err)) => *source = Some(Err(err)),
            }
            slot.source.clone().unwrap()
        })
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        if let Some(source) = self.overlays.get(&id) {
            return Ok(Bytes::from_string(source.text().to_string()));
        }
        self.slot(id, |slot, world| {
            slot.bytes.get_or_insert_with(|| world.read_bytes(id)).clone()
        })
    }

    fn font(&self, index: usize) -> Option<Font> {
        self.fonts.store.font(index)
    }

    fn today(&self, offset: Option<Duration>) -> Option<Datetime> {
        self.time.today(offset)
    }
}

impl IdeWorld for ProjectWorld {
    fn upcast(&self) -> &dyn World {
        self
    }

    fn packages(&self) -> &[(PackageSpec, Option<typst::ecow::EcoString>)] {
        &self.package_index
    }

    fn files(&self) -> Vec<FileId> {
        let mut out = Vec::new();
        collect_files(&self.root, &self.root, &mut out, 0);
        out
    }
}

fn collect_files(root: &Path, dir: &Path, out: &mut Vec<FileId>, depth: usize) {
    if depth > 6 || out.len() > 2000 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        if name.to_string_lossy().starts_with('.') {
            continue;
        }
        if path.is_dir() {
            collect_files(root, &path, out, depth + 1);
        } else if let Ok(id) = id_for_path(root, &path) {
            out.push(id);
        }
    }
}

/// Maps an absolute path inside the project to a file id.
pub fn id_for_path(root: &Path, path: &Path) -> Result<FileId, String> {
    let vpath = match VirtualPath::virtualize(root, path) {
        Ok(vpath) => vpath,
        // The path may reach the project through a symlink (e.g. /var vs
        // /private/var); compare canonical forms.
        Err(err) => {
            let canonical = canonicalize_lenient(path);
            VirtualPath::virtualize(root, &canonical).map_err(|_| format!("{err:?}"))?
        }
    };
    Ok(RootedPath::new(VirtualRoot::Project, vpath).intern())
}

/// Canonicalizes a path whose last component may not exist yet.
pub fn canonicalize_lenient(path: &Path) -> PathBuf {
    if let Ok(canonical) = path.canonicalize() {
        return canonical;
    }
    match (path.parent(), path.file_name()) {
        (Some(parent), Some(name)) => canonicalize_lenient(parent).join(name),
        _ => path.to_path_buf(),
    }
}

/// Maps a file id to an absolute path, downloading its package if needed.
pub fn path_for_id(root: &Path, id: FileId) -> FileResult<PathBuf> {
    let rooted = id.get();
    let base = match rooted.root() {
        VirtualRoot::Project => root.to_path_buf(),
        VirtualRoot::Package(spec) => packages::obtain(spec)?,
    };
    rooted.vpath().realize(&base).map_err(|_| FileError::AccessDenied)
}
