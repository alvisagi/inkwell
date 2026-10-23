//! Serializes a laid-out page into a compact display list that the Swift side
//! draws with Core Graphics. Text is drawn from glyph outlines (fetched once
//! per glyph and cached on the Swift side), images are referenced by id, and
//! paints Core Graphics can't express natively (gradients, tilings) become
//! pre-sampled image patterns.
//!
//! All numbers are little-endian. Coordinates are typographic points with the
//! origin in the page's top-left corner and y pointing down.

use std::collections::HashMap;
use std::sync::Arc;

use ttf_parser::{GlyphId, OutlineBuilder};
use typst::foundations::{Content, Smart};
use typst::layout::{
    Abs, Frame, FrameItem, FrameKind, GroupItem, Point, Sides, Size, Transform,
};
use typst::syntax::Span;
use typst::text::color::{glyph_frame, should_outline};
use typst::text::{FontInstance, TextItem};
use typst::visualize::{
    Curve, CurveItem, FillRule, FixedStroke, Geometry, Gradient, Image, ImageKind, ImageScaling,
    LineCap, LineJoin, Paint, RelativeTo, Shape, Tiling,
};
use typst_layout::Page;

mod op {
    pub const SAVE: u8 = 0x01;
    pub const RESTORE: u8 = 0x02;
    pub const CLIP: u8 = 0x03;
    pub const FILL: u8 = 0x10;
    pub const STROKE: u8 = 0x11;
    pub const GLYPHS: u8 = 0x20;
    pub const IMAGE: u8 = 0x30;
    pub const END: u8 = 0xFF;
}

/// Pixels per point used when sampling gradients and rasterizing vector
/// images that Core Graphics can't draw itself.
const SAMPLE_PPP: f64 = 3.0;
const MAX_SAMPLE_PX: f64 = 4096.0;

/// A raster image the Swift side can decode or blit.
pub enum ImageEntry {
    /// Original encoded bytes (PNG, JPEG, GIF, WebP).
    Encoded(typst::foundations::Bytes),
    /// Premultiplied RGBA8.
    Rgba { width: u32, height: u32, data: Arc<Vec<u8>> },
}

/// Fonts and images referenced by display lists. Ids stay stable for the
/// lifetime of a project so the Swift side can cache by id.
#[derive(Default)]
pub struct Resources {
    fonts: HashMap<FontInstance, u32>,
    pub font_list: Vec<FontInstance>,
    images: HashMap<u128, u32>,
    pub image_list: Vec<ImageEntry>,
}

impl Resources {
    fn font_id(&mut self, font: &FontInstance) -> u32 {
        if let Some(&id) = self.fonts.get(font) {
            return id;
        }
        let id = self.font_list.len() as u32;
        self.font_list.push(font.clone());
        self.fonts.insert(font.clone(), id);
        id
    }

    fn image_id(&mut self, key: u128, make: impl FnOnce() -> ImageEntry) -> u32 {
        if let Some(&id) = self.images.get(&key) {
            return id;
        }
        let id = self.image_list.len() as u32;
        self.image_list.push(make());
        self.images.insert(key, id);
        id
    }

    /// Encodes the outlines of the given glyphs in font units (y up):
    /// for each glyph `u16 id` followed by a path.
    pub fn glyph_outlines(&self, font_id: u32, glyphs: &[u16]) -> Vec<u8> {
        let mut w = Writer::default();
        let Some(font) = self.font_list.get(font_id as usize) else { return w.0 };
        w.f32(font.units_per_em() as f32);
        for &glyph in glyphs {
            let mut builder = PathCollector::default();
            font.ttf().outline_glyph(GlyphId(glyph), &mut builder);
            w.u16(glyph);
            w.u32(builder.count);
            w.0.extend_from_slice(&builder.out.0);
        }
        w.0
    }
}

/// An affine transform `x' = a*x + c*y + e`, `y' = b*x + d*y + f`.
#[derive(Copy, Clone, Debug)]
struct Affine([f64; 6]);

impl Affine {
    const IDENTITY: Self = Self([1.0, 0.0, 0.0, 1.0, 0.0, 0.0]);

    fn from_typst(t: &Transform) -> Self {
        Self([t.sx.get(), t.ky.get(), t.kx.get(), t.sy.get(), t.tx.to_pt(), t.ty.to_pt()])
    }

    fn translate(x: f64, y: f64) -> Self {
        Self([1.0, 0.0, 0.0, 1.0, x, y])
    }

    fn scale(x: f64, y: f64) -> Self {
        Self([x, 0.0, 0.0, y, 0.0, 0.0])
    }

    /// `self * other`: applies `other` first, then `self`.
    fn then_inner(self, other: Self) -> Self {
        let [a, b, c, d, e, f] = self.0;
        let [a2, b2, c2, d2, e2, f2] = other.0;
        Self([
            a * a2 + c * b2,
            b * a2 + d * b2,
            a * c2 + c * d2,
            b * c2 + d * d2,
            a * e2 + c * f2 + e,
            b * e2 + d * f2 + f,
        ])
    }

    fn pre_translate(self, x: f64, y: f64) -> Self {
        self.then_inner(Self::translate(x, y))
    }

    fn pre_scale(self, x: f64, y: f64) -> Self {
        self.then_inner(Self::scale(x, y))
    }

    fn invert(self) -> Option<Self> {
        let [a, b, c, d, e, f] = self.0;
        let det = a * d - b * c;
        if det.abs() < 1e-12 {
            return None;
        }
        let ia = d / det;
        let ib = -b / det;
        let ic = -c / det;
        let id = a / det;
        Some(Self([ia, ib, ic, id, -(ia * e + ic * f), -(ib * e + id * f)]))
    }
}

#[derive(Copy, Clone)]
struct State {
    transform: Affine,
    /// Transform of the closest hard frame (for parent-relative paints).
    container: Affine,
    /// Size of the closest hard frame.
    size: Size,
}

impl State {
    fn pre_translate(self, pos: Point) -> Self {
        Self { transform: self.transform.pre_translate(pos.x.to_pt(), pos.y.to_pt()), ..self }
    }
}

#[derive(Default)]
struct Writer(Vec<u8>);

impl Writer {
    fn u8(&mut self, v: u8) {
        self.0.push(v);
    }
    fn u16(&mut self, v: u16) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    fn u32(&mut self, v: u32) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    fn f32(&mut self, v: f32) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    fn affine(&mut self, t: Affine) {
        for v in t.0 {
            self.f32(v as f32);
        }
    }
}

#[derive(Default)]
struct PathCollector {
    out: Writer,
    count: u32,
}

impl PathCollector {
    fn verb(&mut self, verb: u8, points: &[f32]) {
        self.out.u8(verb);
        for &p in points {
            self.out.f32(p);
        }
        self.count += 1;
    }
}

impl OutlineBuilder for PathCollector {
    fn move_to(&mut self, x: f32, y: f32) {
        self.verb(0, &[x, y]);
    }
    fn line_to(&mut self, x: f32, y: f32) {
        self.verb(1, &[x, y]);
    }
    fn quad_to(&mut self, x1: f32, y1: f32, x: f32, y: f32) {
        self.verb(4, &[x1, y1, x, y]);
    }
    fn curve_to(&mut self, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) {
        self.verb(2, &[x1, y1, x2, y2, x, y]);
    }
    fn close(&mut self) {
        self.verb(3, &[]);
    }
}

fn pt(v: Abs) -> f32 {
    v.to_pt() as f32
}

fn write_curve(w: &mut Writer, curve: &Curve) {
    let mut p = PathCollector::default();
    for item in curve.0.iter() {
        match *item {
            CurveItem::Move(a) => p.verb(0, &[pt(a.x), pt(a.y)]),
            CurveItem::Line(a) => p.verb(1, &[pt(a.x), pt(a.y)]),
            CurveItem::Cubic(a, b, c) => {
                p.verb(2, &[pt(a.x), pt(a.y), pt(b.x), pt(b.y), pt(c.x), pt(c.y)])
            }
            CurveItem::Close => p.verb(3, &[]),
        }
    }
    w.u32(p.count);
    w.0.extend_from_slice(&p.out.0);
}

fn write_geometry(w: &mut Writer, geometry: &Geometry) {
    match geometry {
        Geometry::Line(to) => {
            let mut c = Curve::new();
            c.move_(Point::zero());
            c.line(*to);
            write_curve(w, &c);
        }
        Geometry::Rect(size) => write_curve(w, &Curve::rect(*size)),
        Geometry::Curve(curve) => write_curve(w, curve),
    }
}

pub struct Encoder<'a> {
    res: &'a mut Resources,
    w: Writer,
}

/// Encodes one page.
pub fn encode_page(res: &mut Resources, page: &Page) -> Vec<u8> {
    let size = page.frame.size();
    let mut enc = Encoder { res, w: Writer::default() };
    enc.w.0.extend_from_slice(b"TDL1");
    enc.w.f32(pt(size.x));
    enc.w.f32(pt(size.y));

    let state = State { transform: Affine::IDENTITY, container: Affine::IDENTITY, size };
    if let Some(fill) = page.fill_or_white() {
        let shape = Geometry::Rect(size).filled(fill);
        enc.shape(state, &shape);
    }
    enc.frame(state, &page.frame);
    enc.w.u8(op::END);
    enc.w.0
}

impl Encoder<'_> {
    fn frame(&mut self, state: State, frame: &Frame) {
        for (pos, item) in frame.items() {
            match item {
                FrameItem::Group(group) => self.group(state, *pos, group),
                FrameItem::Text(text) => self.text(state.pre_translate(*pos), text),
                FrameItem::Shape(shape, _) => self.shape(state.pre_translate(*pos), shape),
                FrameItem::Image(image, size, _) => {
                    self.image(state.pre_translate(*pos), image, *size)
                }
                FrameItem::Link(..) | FrameItem::Tag(_) => {}
            }
        }
    }

    fn group(&mut self, state: State, pos: Point, group: &GroupItem) {
        let local = Affine::from_typst(&group.transform);
        let transform = state.transform.pre_translate(pos.x.to_pt(), pos.y.to_pt()).then_inner(local);
        let state = match group.frame.kind() {
            FrameKind::Soft => State { transform, ..state },
            FrameKind::Hard => State {
                transform,
                container: transform,
                size: group.frame.size(),
            },
        };

        let clipped = group.clip.is_some();
        if let Some(clip) = &group.clip {
            self.w.u8(op::SAVE);
            self.w.u8(op::CLIP);
            self.w.affine(state.transform);
            write_curve(&mut self.w, clip);
        }
        self.frame(state, &group.frame);
        if clipped {
            self.w.u8(op::RESTORE);
        }
    }

    fn shape(&mut self, state: State, shape: &Shape) {
        if let Some(fill) = &shape.fill {
            // A line has no area to fill.
            if !matches!(shape.geometry, Geometry::Line(_)) {
                self.w.u8(op::FILL);
                self.w.affine(state.transform);
                write_geometry(&mut self.w, &shape.geometry);
                self.w.u8(matches!(shape.fill_rule, FillRule::EvenOdd) as u8);
                self.paint(state, fill, false, Some(shape), false);
            }
        }
        if let Some(stroke) = &shape.stroke
            && stroke.thickness > Abs::zero()
        {
            self.w.u8(op::STROKE);
            self.w.affine(state.transform);
            write_geometry(&mut self.w, &shape.geometry);
            self.stroke(state, stroke, false, Some(shape));
        }
    }

    fn stroke(&mut self, state: State, stroke: &FixedStroke, on_text: bool, shape: Option<&Shape>) {
        self.paint(state, &stroke.paint, on_text, shape, true);
        self.w.f32(pt(stroke.thickness));
        self.w.u8(match stroke.cap {
            LineCap::Butt => 0,
            LineCap::Round => 1,
            LineCap::Square => 2,
        });
        self.w.u8(match stroke.join {
            LineJoin::Miter => 0,
            LineJoin::Round => 1,
            LineJoin::Bevel => 2,
        });
        self.w.f32(stroke.miter_limit.get() as f32);
        match &stroke.dash {
            Some(dash) if !dash.array.is_empty() => {
                self.w.u32(dash.array.len() as u32);
                self.w.f32(pt(dash.phase));
                for v in &dash.array {
                    self.w.f32(pt(*v));
                }
            }
            _ => self.w.u32(0),
        }
    }

    /// Writes a paint. Solid colors are written directly; gradients and
    /// tilings become an image pattern with a pixel -> item-space transform.
    fn paint(
        &mut self,
        state: State,
        paint: &Paint,
        on_text: bool,
        shape: Option<&Shape>,
        include_stroke: bool,
    ) {
        let (item_size, self_transform, mirror) = match shape {
            Some(shape) => {
                let bbox = shape.bbox(include_stroke);
                let flip = match shape.geometry {
                    Geometry::Rect(rect) => Some((rect.x.signum(), rect.y.signum())),
                    _ => None,
                };
                (bbox.size(), Affine::translate(bbox.min.x.to_pt(), bbox.min.y.to_pt()), flip)
            }
            None => (Size::zero(), Affine::IDENTITY, None),
        };
        let parent_transform = || {
            state
                .transform
                .invert()
                .map(|inv| inv.then_inner(state.container))
                .unwrap_or(Affine::IDENTITY)
        };

        match paint {
            Paint::Solid(color) => {
                let (r, g, b, a) = color.to_process().to_rgb().into_format::<u8, u8>().into_components();
                self.w.u8(0);
                for v in [r, g, b, a] {
                    self.w.u8(v);
                }
            }
            Paint::Gradient(gradient) => {
                let relative = gradient.unwrap_relative(on_text);
                let (size, fill_transform, mirror) = match relative {
                    RelativeTo::Self_ => (item_size, self_transform, mirror),
                    RelativeTo::Parent => (state.size, parent_transform(), None),
                };
                let ppp = sample_ppp(size);
                let width = ((size.x.to_pt().abs() * ppp).ceil() as u32).max(1);
                let height = ((size.y.to_pt().abs() * ppp).ceil() as u32).max(1);
                let key = typst::utils::hash128(&(gradient, width, height, mirror.map(|(x, y)| (x.to_bits(), y.to_bits()))));
                let id = self.res.image_id(key, || sample_gradient(gradient, width, height, mirror));
                let sx = size.x.to_pt().signum() / ppp;
                let sy = size.y.to_pt().signum() / ppp;
                let transform = fill_transform.pre_scale(sx, sy);
                self.w.u8(1);
                self.w.u32(id);
                self.w.affine(transform);
                self.w.u8(0); // pad
            }
            Paint::Tiling(tiling) => {
                let relative = tiling.unwrap_relative(on_text);
                let fill_transform = match relative {
                    RelativeTo::Self_ => self_transform,
                    RelativeTo::Parent => parent_transform(),
                };
                let ppp: f64 = 4.0;
                let key = typst::utils::hash128(&(tiling, ppp.to_bits()));
                let id = self.res.image_id(key, || render_tiling(tiling, ppp));
                let transform = fill_transform
                    .pre_translate(tiling.offset().x.to_pt(), tiling.offset().y.to_pt())
                    .pre_scale(1.0 / ppp, 1.0 / ppp);
                self.w.u8(1);
                self.w.u32(id);
                self.w.affine(transform);
                self.w.u8(1); // repeat
            }
        }
    }

    fn text(&mut self, state: State, text: &TextItem) {
        let scale = text.size.to_pt() / text.font.units_per_em();
        let mut outlined: Vec<(u16, f32, f32)> = Vec::with_capacity(text.glyphs.len());
        let mut x = Abs::zero();
        let mut y = Abs::zero();
        let mut color_glyphs = Vec::new();
        for glyph in &text.glyphs {
            let gx = x + glyph.x_offset.at(text.size);
            let gy = y + glyph.y_offset.at(text.size);
            if should_outline(&text.font, GlyphId(glyph.id)) {
                outlined.push((glyph.id, pt(gx), -pt(gy)));
            } else {
                color_glyphs.push((glyph.id, gx, gy));
            }
            x += glyph.x_advance.at(text.size);
            y += glyph.y_advance.at(text.size);
        }

        if !outlined.is_empty() {
            let font_id = self.res.font_id(&text.font);
            self.w.u8(op::GLYPHS);
            self.w.affine(state.transform);
            self.w.u32(font_id);
            self.w.f32(scale as f32);
            self.paint(state, &text.fill, true, None, false);
            match &text.stroke {
                Some(stroke) => {
                    self.w.u8(1);
                    self.stroke(state, stroke, true, None);
                }
                None => self.w.u8(0),
            }
            self.w.u32(outlined.len() as u32);
            for (id, gx, gy) in outlined {
                self.w.u16(id);
                self.w.f32(gx);
                self.w.f32(gy);
            }
        }

        for (id, gx, gy) in color_glyphs {
            if let Some(frame) = glyph_frame(&text.font, id) {
                let transform = state
                    .transform
                    .pre_translate(gx.to_pt(), -gy.to_pt())
                    .pre_scale(scale, scale);
                let frame: Frame = frame.into();
                self.frame(State { transform, ..state }, &frame);
            }
        }
    }

    fn image(&mut self, state: State, image: &Image, size: Size) {
        let smooth = !matches!(image.scaling(), Smart::Custom(ImageScaling::Pixelated));
        let id = match image.kind() {
            ImageKind::Raster(raster) => {
                let key = typst::utils::hash128(raster.data());
                let data = raster.data().clone();
                self.res.image_id(key, || ImageEntry::Encoded(data))
            }
            ImageKind::Svg(_) | ImageKind::Pdf(_) => {
                let ppp = sample_ppp(size);
                let key = typst::utils::hash128(&(image, size, ppp.to_bits()));
                self.res.image_id(key, || rasterize_image(image, size, ppp))
            }
        };
        self.w.u8(op::IMAGE);
        self.w.affine(state.transform);
        self.w.u32(id);
        self.w.f32(pt(size.x));
        self.w.f32(pt(size.y));
        self.w.u8(smooth as u8);
    }
}

/// Picks a sampling density that stays within the pixel budget.
fn sample_ppp(size: Size) -> f64 {
    let longest = size.x.to_pt().abs().max(size.y.to_pt().abs()).max(1.0);
    SAMPLE_PPP.min(MAX_SAMPLE_PX / longest)
}

fn sample_gradient(gradient: &Gradient, width: u32, height: u32, mirror: Option<(f64, f64)>) -> ImageEntry {
    let (sx, sy) = mirror.unwrap_or((1.0, 1.0));
    let (ox, oy) = (if sx < 0.0 { -(width as f32) } else { 0.0 }, if sy < 0.0 { -(height as f32) } else { 0.0 });
    let mut data = vec![0u8; (width * height * 4) as usize];
    for y in 0..height {
        for x in 0..width {
            let color = gradient.sample_at(
                ((x as f32 + ox) * sx as f32, (y as f32 + oy) * sy as f32),
                (width as f32, height as f32),
            );
            let (r, g, b, a) = color.to_process().to_rgb().into_components();
            let i = ((y * width + x) * 4) as usize;
            data[i] = (r * a * 255.0).round() as u8;
            data[i + 1] = (g * a * 255.0).round() as u8;
            data[i + 2] = (b * a * 255.0).round() as u8;
            data[i + 3] = (a * 255.0).round() as u8;
        }
    }
    ImageEntry::Rgba { width, height, data: Arc::new(data) }
}

fn page_for(frame: Frame) -> Page {
    Page {
        frame,
        bleed: Sides::splat(Abs::zero()),
        fill: Smart::Custom(None),
        numbering: None,
        supplement: Content::empty(),
        number: 1,
    }
}

fn render(frame: Frame, ppp: f64) -> ImageEntry {
    let options = typst_render::RenderOptions { pixel_per_pt: ppp.into(), render_bleed: false };
    let pixmap = typst_render::render(&page_for(frame), &options);
    ImageEntry::Rgba { width: pixmap.width(), height: pixmap.height(), data: Arc::new(pixmap.take()) }
}

fn rasterize_image(image: &Image, size: Size, ppp: f64) -> ImageEntry {
    let mut frame = Frame::hard(size);
    frame.push(Point::zero(), FrameItem::Image(image.clone(), size, Span::detached()));
    render(frame, ppp)
}

fn render_tiling(tiling: &Tiling, ppp: f64) -> ImageEntry {
    let size = tiling.size() + tiling.spacing();
    let mut frame = Frame::hard(size);
    frame.push(Point::zero(), FrameItem::Group(GroupItem::new(tiling.frame().clone())));
    render(frame, ppp)
}
