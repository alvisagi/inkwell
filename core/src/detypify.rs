//! Hand-drawn symbol recognition with the Detypify model.
//!
//! Strokes are normalized and drawn white-on-black onto a 224x224 canvas,
//! exactly like the reference implementation, then classified.

use std::sync::LazyLock;

use serde::Deserialize;
use tiny_skia::{Color, LineCap, LineJoin, Paint, PathBuilder, Pixmap, Stroke, Transform};
use tract_onnx::prelude::*;

const SIZE: usize = 224;
static MODEL_BYTES: &[u8] = include_bytes!("../assets/detypify/model.onnx");
static CLASSES_JSON: &str = include_str!("../assets/detypify/infer.json");

#[derive(Deserialize)]
struct Class {
    names: Vec<String>,
}

type Model = Arc<TypedRunnableModel>;

static MODEL: LazyLock<Option<Model>> = LazyLock::new(|| match load() {
    Ok(model) => Some(model),
    Err(err) => {
        eprintln!("detypify: failed to load model: {err:?}");
        None
    }
});

fn load() -> TractResult<Model> {
    tract_onnx::onnx()
        .model_for_read(&mut std::io::Cursor::new(MODEL_BYTES))?
        .with_input_fact(0, f32::fact([1, 1, SIZE, SIZE]).into())?
        .into_optimized()?
        .into_runnable()
}

static CLASSES: LazyLock<Vec<Class>> =
    LazyLock::new(|| serde_json::from_str(CLASSES_JSON).unwrap_or_default());

fn rasterize(strokes: &[Vec<[f32; 2]>]) -> Option<Vec<f32>> {
    let points = strokes.iter().flatten();
    let (mut min_x, mut max_x, mut min_y, mut max_y) = (f32::MAX, f32::MIN, f32::MAX, f32::MIN);
    for [x, y] in points {
        min_x = min_x.min(*x);
        max_x = max_x.max(*x);
        min_y = min_y.min(*y);
        max_y = max_y.max(*y);
    }
    if min_x > max_x {
        return None;
    }
    let width = (max_x - min_x).max(max_y - min_y);
    let scale = if width > 1e-6 { (SIZE as f32 - 20.0) / width } else { 1.0 };
    let (cx, cy) = ((min_x + max_x) / 2.0, (min_y + max_y) / 2.0);

    let mut pixmap = Pixmap::new(SIZE as u32, SIZE as u32)?;
    pixmap.fill(Color::BLACK);
    let mut paint = Paint::default();
    paint.set_color(Color::WHITE);
    paint.anti_alias = true;
    let stroke = Stroke { width: 8.0, line_cap: LineCap::Butt, line_join: LineJoin::Miter, ..Default::default() };
    for points in strokes {
        let mut builder = PathBuilder::new();
        for (i, [x, y]) in points.iter().enumerate() {
            let tx = ((x - cx) * scale + SIZE as f32 / 2.0).round();
            let ty = ((y - cy) * scale + SIZE as f32 / 2.0).round();
            if i == 0 {
                builder.move_to(tx, ty);
            } else {
                builder.line_to(tx, ty);
            }
        }
        if points.len() == 1 {
            let [x, y] = points[0];
            let tx = ((x - cx) * scale + SIZE as f32 / 2.0).round();
            let ty = ((y - cy) * scale + SIZE as f32 / 2.0).round();
            builder.line_to(tx + 0.5, ty);
        }
        if let Some(path) = builder.finish() {
            pixmap.stroke_path(&path, &paint, &stroke, Transform::identity(), None);
        }
    }
    Some(pixmap.data().chunks_exact(4).map(|px| px[0] as f32 / 255.0).collect())
}

/// Returns symbol names, most likely first.
pub fn recognize(strokes: &[Vec<[f32; 2]>], limit: usize) -> Vec<String> {
    let (Some(model), Some(grey)) = (MODEL.as_ref(), rasterize(strokes)) else { return vec![] };
    let Ok(input) = tract_ndarray::Array4::from_shape_vec((1, 1, SIZE, SIZE), grey) else { return vec![] };
    let outputs = match model.run(tvec!(Tensor::from(input).into())) {
        Ok(outputs) => outputs,
        Err(err) => {
            eprintln!("detypify: inference failed: {err:?}");
            return vec![];
        }
    };
    let Ok(scores) = outputs[0].to_plain_array_view::<f32>() else { return vec![] };
    let mut ranked: Vec<(usize, f32)> = scores.iter().copied().enumerate().collect();
    ranked.sort_by(|a, b| b.1.total_cmp(&a.1));
    let mut out = Vec::new();
    for (index, _) in ranked.into_iter().take(limit) {
        if let Some(class) = CLASSES.get(index) {
            out.extend(class.names.iter().cloned());
        }
    }
    out
}
