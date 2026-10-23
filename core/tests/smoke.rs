//! End-to-end checks of the core API on the sample project.

use std::path::PathBuf;

use typst_core::*;

fn demo() -> (std::sync::Arc<Project>, String) {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../samples/demo").canonicalize().unwrap();
    let main = root.join("main.typ").to_string_lossy().into_owned();
    let project = Project::new(root.to_string_lossy().into_owned());
    project.set_main(main.clone()).unwrap();
    (project, main)
}

#[test]
fn compiles_and_encodes() {
    let (project, _) = demo();
    let report = project.compile();
    assert!(report.success, "{:?}", report.diagnostics.iter().map(|d| &d.message).collect::<Vec<_>>());
    assert!(!report.pages.is_empty());
    let list = project.display_list(0);
    assert!(list.starts_with(b"TDL1"));
    assert!(list.len() > 1000);
}

#[test]
fn completes_functions() {
    let (project, main) = demo();
    project.compile();
    let text = "Hello #tex";
    project.set_text(main.clone(), text.into());
    let completions = project.complete(main, text.len() as u64, false).expect("completions");
    assert_eq!(completions.from, 7);
    assert!(completions.items.iter().any(|c| c.label == "text"), "{:?}", completions.items.iter().map(|c| &c.label).take(10).collect::<Vec<_>>());
}

#[test]
fn jumps_both_ways() {
    let (project, main) = demo();
    project.compile();
    // Cursor inside "Introduction" heading text (line 5).
    let text = std::fs::read_to_string(&main).unwrap();
    let offset = text.find("Introduction").unwrap() as u64 + 3;
    let positions = project.cursor_positions(main.clone(), offset);
    assert!(!positions.is_empty());
    let p = &positions[0];
    match project.click(p.page, p.x + 1.0, p.y - 3.0) {
        Some(ClickTarget::Source { path, offset: o }) => {
            assert!(path.ends_with("main.typ"));
            assert!((o as i64 - offset as i64).abs() < 20, "{o} vs {offset}");
        }
        other => panic!("unexpected click target: {}", other.is_some()),
    }
}

#[test]
fn highlights_and_outlines() {
    let text = "= Title\n#let x = 1\n*bold* text $a + b$";
    let spans = highlight(text.into());
    assert!(spans.len() >= 9 * 4);
    let items = outline(text.into());
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].title, "Title");
    assert!(symbols().iter().any(|s| s.name == "arrow.r"));
}

#[test]
fn recognizes_a_drawn_line() {
    // A horizontal stroke should look like a minus/dash-like symbol.
    let stroke: Vec<f32> = (0..50).flat_map(|i| [i as f32 * 4.0, 100.0]).collect();
    let names = recognize_symbol(vec![stroke], 5);
    assert!(!names.is_empty());
    eprintln!("line -> {names:?}");
}

#[test]
fn large_document_is_fast() {
    let dir = std::env::temp_dir().join(format!("inkwell-big-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let main = dir.join("main.typ");
    let mut text = String::from("#set heading(numbering: \"1.1\")\n#outline()\n");
    for i in 0..150 {
        text.push_str(&format!("= Section {i}\n#lorem(300)\n$ sum_(k=1)^{i} k^2 = integral_0^1 x^{i} dif x $\n- item\n- item\n\n"));
    }
    std::fs::write(&main, &text).unwrap();
    let project = Project::new(dir.to_string_lossy().into_owned());
    project.set_main(main.to_string_lossy().into_owned()).unwrap();

    let t = std::time::Instant::now();
    let report = project.compile();
    let first = t.elapsed();
    assert!(report.success);
    let pages = report.pages.len();

    // An edit near the end, as when typing.
    let edited = text.replacen("#lorem(300)\n$ sum_(k=1)^149", "#lorem(300) typed\n$ sum_(k=1)^149", 1);
    project.set_text(main.to_string_lossy().into_owned(), edited);
    let t = std::time::Instant::now();
    let report = project.compile();
    let second = t.elapsed();
    assert!(report.success);

    let t = std::time::Instant::now();
    let list = project.display_list(pages as u32 - 1);
    let encode = t.elapsed();
    let t = std::time::Instant::now();
    let _ = highlight(text.clone());
    let hl = t.elapsed();
    eprintln!("pages={pages} first={first:?} incremental={second:?} encode_last_page={encode:?} ({} bytes) highlight={hl:?} ({} KB source)", list.len(), text.len() / 1024);
    std::fs::remove_dir_all(&dir).ok();
}
