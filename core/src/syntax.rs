//! Source-level helpers that don't need a compilation: highlighting, the
//! heading outline and the symbol table.

use typst::syntax::ast;
use typst::syntax::{LinkedNode, Source, SyntaxKind, Tag};

/// Highlight tags, numbered for the Swift side.
fn tag_code(tag: Tag) -> u8 {
    match tag {
        Tag::Comment => 1,
        Tag::Punctuation => 2,
        Tag::Escape => 3,
        Tag::Strong => 4,
        Tag::Emph => 5,
        Tag::Link => 6,
        Tag::Raw => 7,
        Tag::Label => 8,
        Tag::Ref => 9,
        Tag::Heading => 10,
        Tag::ListMarker => 11,
        Tag::ListTerm => 12,
        Tag::MathDelimiter => 13,
        Tag::MathOperator => 14,
        Tag::Keyword => 15,
        Tag::Operator => 16,
        Tag::Number => 17,
        Tag::String => 18,
        Tag::Function => 19,
        Tag::Interpolated => 20,
        Tag::Error => 21,
        _ => 0,
    }
}

/// Context flags OR-ed into the tag byte for nested markup.
const IN_CODE: u8 = 0x20;
const IN_STRONG: u8 = 0x40;
const IN_EMPH: u8 = 0x80;

/// Returns packed spans `[u32 start, u32 len, u8 tag]` in UTF-16 units.
pub fn highlight(text: &str) -> Vec<u8> {
    let source = Source::detached(text);
    let mut out = Vec::with_capacity(text.len());
    let mut utf16_pos = 0u32;
    let mut byte_pos = 0usize;
    walk(&LinkedNode::new(source.root()), 0, text, &mut byte_pos, &mut utf16_pos, &mut out);
    out
}

fn walk(
    node: &LinkedNode,
    context: u8,
    text: &str,
    byte_pos: &mut usize,
    utf16_pos: &mut u32,
    out: &mut Vec<u8>,
) {
    let mut context = context;
    match node.kind() {
        SyntaxKind::Strong => context |= IN_STRONG,
        SyntaxKind::Emph => context |= IN_EMPH,
        SyntaxKind::Code | SyntaxKind::CodeBlock | SyntaxKind::Equation | SyntaxKind::Raw
        | SyntaxKind::FuncCall | SyntaxKind::SetRule | SyntaxKind::ShowRule | SyntaxKind::LetBinding
        | SyntaxKind::ModuleImport | SyntaxKind::ModuleInclude => context |= IN_CODE,
        // Content inside code is prose again.
        SyntaxKind::ContentBlock => context &= !IN_CODE,
        _ => {}
    }

    if node.children().len() == 0 {
        let range = node.range();
        // Advance the UTF-16 cursor to the node's start.
        if range.start > *byte_pos {
            *utf16_pos += text[*byte_pos..range.start].encode_utf16().count() as u32;
            *byte_pos = range.start;
        }
        let len = text[range.clone()].encode_utf16().count() as u32;
        let tag = typst::syntax::highlight(node).map(tag_code).unwrap_or(0);
        let code = tag | context;
        if code != 0 && len > 0 {
            out.extend_from_slice(&utf16_pos.to_le_bytes());
            out.extend_from_slice(&len.to_le_bytes());
            out.push(code);
        }
        *utf16_pos += len;
        *byte_pos = range.end;
        return;
    }

    // Headings are highlighted as a whole.
    if let Some(tag) = typst::syntax::highlight(node)
        && matches!(tag, Tag::Heading | Tag::Raw | Tag::Label | Tag::Ref | Tag::Link)
    {
        let range = node.range();
        if range.start > *byte_pos {
            *utf16_pos += text[*byte_pos..range.start].encode_utf16().count() as u32;
            *byte_pos = range.start;
        }
        let len = text[range.clone()].encode_utf16().count() as u32;
        out.extend_from_slice(&utf16_pos.to_le_bytes());
        out.extend_from_slice(&len.to_le_bytes());
        out.push(tag_code(tag) | context);
        // Still visit children so comments inside raw etc. keep positions;
        // children are emitted after and override where they have tags.
    }

    for child in node.children() {
        walk(&child, context, text, byte_pos, utf16_pos, out);
    }
}

#[derive(uniffi::Record)]
pub struct OutlineItem {
    pub level: u32,
    pub title: String,
    /// UTF-16 offset of the heading.
    pub offset: u64,
    /// 1-based line.
    pub line: u32,
}

pub fn outline(text: &str) -> Vec<OutlineItem> {
    let source = Source::detached(text);
    let mut out = Vec::new();
    visit_headings(&LinkedNode::new(source.root()), &source, &mut out);
    out
}

fn visit_headings(node: &LinkedNode, source: &Source, out: &mut Vec<OutlineItem>) {
    if let Some(heading) = node.cast::<ast::Heading>() {
        let range = node.range();
        let title = source.text()[range.clone()].trim_start_matches('=').trim().to_string();
        let lines = source.lines();
        out.push(OutlineItem {
            level: heading.depth().get() as u32,
            title,
            offset: lines.byte_to_utf16(range.start).unwrap_or(0) as u64,
            line: lines.byte_to_line(range.start).unwrap_or(0) as u32 + 1,
        });
        return;
    }
    for child in node.children() {
        visit_headings(&child, source, out);
    }
}

#[derive(uniffi::Record)]
pub struct SymbolEntry {
    /// Full name, e.g. `arrow.r.long`.
    pub name: String,
    pub value: String,
    /// Top-level module: `sym` or `emoji`.
    pub module: String,
    pub deprecated: bool,
}

pub fn symbols() -> Vec<SymbolEntry> {
    let mut out = Vec::new();
    for (module_name, binding) in codex::ROOT.iter() {
        if let codex::Def::Module(module) = binding.def {
            collect_symbols(module, module_name, module_name.to_string(), &mut out);
        }
    }
    out
}

fn collect_symbols(module: codex::Module, root: &str, prefix: String, out: &mut Vec<SymbolEntry>) {
    for (name, binding) in module.iter() {
        let full = if prefix == root { name.to_string() } else { format!("{prefix}.{name}") };
        match binding.def {
            codex::Def::Symbol(symbol) => {
                for (modifiers, value, deprecation) in symbol.variants() {
                    let mut full_name = full.clone();
                    for m in modifiers.into_iter() {
                        full_name.push('.');
                        full_name.push_str(m);
                    }
                    out.push(SymbolEntry {
                        name: full_name,
                        value: value.to_string(),
                        module: root.to_string(),
                        deprecated: deprecation.is_some() || binding.deprecation.is_some(),
                    });
                }
            }
            codex::Def::Module(sub) => collect_symbols(sub, root, full, out),
        }
    }
}
