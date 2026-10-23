//! One font store shared by all projects. Scanning system fonts is slow, so it
//! happens once and again only when the user asks to reload fonts.

use std::path::PathBuf;
use std::sync::{Arc, LazyLock, RwLock};

use typst::text::FontInfo;
use typst_kit::fonts::{self, FontStore};

pub struct SharedFonts {
    pub store: FontStore,
    /// Family names, sorted and deduplicated, for the font picker.
    pub families: Vec<String>,
}

static FONTS: LazyLock<RwLock<Option<Arc<SharedFonts>>>> = LazyLock::new(|| RwLock::new(None));
static EXTRA_DIRS: LazyLock<RwLock<Vec<PathBuf>>> = LazyLock::new(|| RwLock::new(Vec::new()));

fn build() -> SharedFonts {
    let mut store = FontStore::new();
    let mut infos: Vec<FontInfo> = Vec::new();
    for (font, info) in fonts::embedded() {
        infos.push(info.clone());
        store.push((font, info));
    }
    for (path, info) in fonts::system() {
        infos.push(info.clone());
        store.push((path, info));
    }
    for dir in EXTRA_DIRS.read().unwrap().iter() {
        for (path, info) in fonts::scan(dir) {
            infos.push(info.clone());
            store.push((path, info));
        }
    }
    let mut families: Vec<String> = infos.iter().map(|i| i.family.clone()).collect();
    families.sort_by_key(|f| f.to_lowercase());
    families.dedup();
    SharedFonts { store, families }
}

pub fn shared() -> Arc<SharedFonts> {
    if let Some(fonts) = FONTS.read().unwrap().as_ref() {
        return fonts.clone();
    }
    let mut slot = FONTS.write().unwrap();
    slot.get_or_insert_with(|| Arc::new(build())).clone()
}

/// Rescans fonts; projects pick the new store up on their next compile.
pub fn reload() {
    let fresh = Arc::new(build());
    *FONTS.write().unwrap() = Some(fresh);
}

pub fn add_dir(dir: PathBuf) {
    let mut dirs = EXTRA_DIRS.write().unwrap();
    if !dirs.contains(&dir) {
        dirs.push(dir);
    }
}
