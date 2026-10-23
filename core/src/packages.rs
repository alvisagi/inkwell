//! Package resolution: user-registered namespaces, the standard Typst data and
//! cache directories (shared with the CLI), and downloads from Typst Universe.

use std::any::Any;
use std::collections::BTreeMap;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, RwLock};

use serde::Deserialize;
use typst::diag::{PackageError, PackageResult};
use typst::syntax::package::{PackageSpec, PackageVersion};
use typst_kit::downloader::Downloader;
use typst_kit::packages::{FsPackages, SystemPackages, UniversePackages};

/// HTTPS downloads via ureq + rustls.
pub struct HttpDownloader;

impl Downloader for HttpDownloader {
    fn stream(&self, _key: &dyn Any, url: &str) -> io::Result<(Option<usize>, Box<dyn Read>)> {
        let response = agent().get(url).call().map_err(|err| match err {
            ureq::Error::Status(404, _) => io::Error::new(io::ErrorKind::NotFound, "not found"),
            other => io::Error::other(other.to_string()),
        })?;
        let len = response.header("Content-Length").and_then(|v| v.parse().ok());
        Ok((len, Box::new(response.into_reader())))
    }
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .user_agent(concat!("typst-editor/", env!("CARGO_PKG_VERSION")))
        .timeout(std::time::Duration::from_secs(60))
        .build()
}

static SYSTEM: LazyLock<SystemPackages> = LazyLock::new(|| SystemPackages::new(HttpDownloader));

/// namespace -> folder containing `<name>/<version>/`.
static NAMESPACES: LazyLock<RwLock<BTreeMap<String, PathBuf>>> =
    LazyLock::new(|| RwLock::new(BTreeMap::new()));

pub fn set_namespaces(map: BTreeMap<String, PathBuf>) {
    *NAMESPACES.write().unwrap() = map;
}

/// Returns the directory a package's files live in, downloading if needed.
pub fn obtain(spec: &PackageSpec) -> PackageResult<PathBuf> {
    if let Some(folder) = NAMESPACES.read().unwrap().get(spec.namespace.as_str()) {
        let dir = folder.join(spec.name.as_str()).join(spec.version.to_string());
        if dir.is_dir() {
            return Ok(dir);
        }
        return Err(PackageError::NotFound(spec.clone()));
    }
    SYSTEM.obtain(spec).map(|root| root.path().to_path_buf())
}

pub fn cache_dir() -> Option<PathBuf> {
    FsPackages::system_cache().map(|p| p.path().to_path_buf())
}

pub fn data_dir() -> Option<PathBuf> {
    FsPackages::system_data().map(|p| p.path().to_path_buf())
}

/// All `@preview` packages present in the cache directory.
pub fn downloaded() -> Vec<(String, String, PathBuf)> {
    let mut out = Vec::new();
    let Some(cache) = cache_dir() else { return out };
    let preview = cache.join(UniversePackages::NAMESPACE);
    let Ok(names) = std::fs::read_dir(&preview) else { return out };
    for name in names.flatten().filter(|e| e.path().is_dir()) {
        let Ok(versions) = std::fs::read_dir(name.path()) else { continue };
        for version in versions.flatten().filter(|e| e.path().is_dir()) {
            out.push((
                name.file_name().to_string_lossy().into_owned(),
                version.file_name().to_string_lossy().into_owned(),
                version.path(),
            ));
        }
    }
    out.sort();
    out
}

/// Deletes a downloaded package (and its now-empty parent folder).
pub fn delete(dir: &Path) -> io::Result<()> {
    std::fs::remove_dir_all(dir)?;
    if let Some(parent) = dir.parent()
        && std::fs::read_dir(parent).map(|mut d| d.next().is_none()).unwrap_or(false)
    {
        let _ = std::fs::remove_dir(parent);
    }
    Ok(())
}

#[derive(Deserialize, Clone)]
pub struct IndexEntry {
    pub name: String,
    pub version: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub authors: Vec<String>,
    #[serde(default)]
    pub keywords: Vec<String>,
    #[serde(default)]
    pub categories: Vec<String>,
    #[serde(default)]
    pub template: Option<TemplateInfo>,
}

#[derive(Deserialize, Clone)]
pub struct TemplateInfo {
    pub path: String,
    pub entrypoint: String,
    #[serde(default)]
    pub thumbnail: Option<String>,
}

/// Fetches the Typst Universe index (one entry per published version).
pub fn fetch_index() -> Result<Vec<IndexEntry>, String> {
    let url = format!("{}/preview/index.json", SYSTEM.universe().url());
    let bytes = HttpDownloader.download(&(), &url).map_err(|e| e.to_string())?;
    serde_json::from_slice(&bytes).map_err(|e| e.to_string())
}

/// Keeps only the newest version of every package.
pub fn latest_only(entries: Vec<IndexEntry>) -> Vec<IndexEntry> {
    let mut best: BTreeMap<String, (PackageVersion, IndexEntry)> = BTreeMap::new();
    for entry in entries {
        let Ok(version) = entry.version.parse::<PackageVersion>() else { continue };
        match best.get(&entry.name) {
            Some((v, _)) if *v >= version => {}
            _ => {
                best.insert(entry.name.clone(), (version, entry));
            }
        }
    }
    best.into_values().map(|(_, e)| e).collect()
}

/// Copies a template package's template folder into `dest`.
pub fn instantiate_template(spec: &PackageSpec, template_path: &str, dest: &Path) -> Result<(), String> {
    let dir = obtain(spec).map_err(|e| e.to_string())?;
    let source = dir.join(template_path);
    if !source.is_dir() {
        return Err(format!("template folder `{template_path}` is missing"));
    }
    copy_dir(&source, dest).map_err(|e| e.to_string())
}

fn copy_dir(from: &Path, to: &Path) -> io::Result<()> {
    std::fs::create_dir_all(to)?;
    for entry in std::fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_dir(&entry.path(), &target)?;
        } else if !target.exists() {
            std::fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}

/// Downloads an arbitrary URL; used for template thumbnails.
pub fn download(url: &str) -> Result<Vec<u8>, String> {
    HttpDownloader.download(&(), url).map_err(|e| e.to_string())
}

pub fn universe_url() -> String {
    SYSTEM.universe().url().to_string()
}
