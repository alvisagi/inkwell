import AppKit
import CoreGraphics
import TypstCore

/// A paint: a solid color or an image pattern (gradients and tilings are
/// pre-sampled by the core).
enum DLPaint {
    case solid(CGColor)
    case pattern(image: UInt32, transform: CGAffineTransform, repeats: Bool)
}

struct DLStroke {
    var paint: DLPaint
    var width: CGFloat
    var cap: CGLineCap
    var join: CGLineJoin
    var miter: CGFloat
    var dash: [CGFloat]
    var phase: CGFloat
}

struct GlyphRun {
    var font: UInt32
    var scale: CGFloat
    var glyphs: [(id: UInt16, x: Float, y: Float)]
}

enum DLOp {
    case save
    case restore
    case clip(CGAffineTransform, CGPath)
    case fill(CGAffineTransform, CGPath, evenOdd: Bool, DLPaint)
    case stroke(CGAffineTransform, CGPath, DLStroke)
    /// `path` is filled in by `PreviewResources.prepare` from glyph outlines.
    case glyphs(CGAffineTransform, GlyphRun, DLPaint, DLStroke?, path: CGPath?)
    case image(CGAffineTransform, UInt32, CGSize, smooth: Bool)
}

/// A parsed page.
struct DisplayList {
    var size: CGSize
    var ops: [DLOp]
}

/// Little-endian reader over the core's binary format.
struct ByteReader {
    let data: Data
    var offset = 0

    init(_ data: Data) { self.data = data }

    var atEnd: Bool { offset >= data.count }

    mutating func u8() -> UInt8 {
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func u16() -> UInt16 {
        defer { offset += 2 }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
    }

    mutating func u32() -> UInt32 {
        defer { offset += 4 }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    mutating func f32() -> Float {
        defer { offset += 4 }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
    }

    mutating func cg() -> CGFloat { CGFloat(f32()) }

    mutating func affine() -> CGAffineTransform {
        CGAffineTransform(a: cg(), b: cg(), c: cg(), d: cg(), tx: cg(), ty: cg())
    }

    mutating func path() -> CGPath {
        let path = CGMutablePath()
        let count = u32()
        for _ in 0..<count {
            switch u8() {
            case 0: path.move(to: CGPoint(x: cg(), y: cg()))
            case 1: path.addLine(to: CGPoint(x: cg(), y: cg()))
            case 2:
                let c1 = CGPoint(x: cg(), y: cg())
                let c2 = CGPoint(x: cg(), y: cg())
                let p = CGPoint(x: cg(), y: cg())
                path.addCurve(to: p, control1: c1, control2: c2)
            case 3: path.closeSubpath()
            case 4:
                let c = CGPoint(x: cg(), y: cg())
                let p = CGPoint(x: cg(), y: cg())
                path.addQuadCurve(to: p, control: c)
            default: break
            }
        }
        return path
    }

    mutating func paint() -> DLPaint {
        switch u8() {
        case 0:
            let r = u8(), g = u8(), b = u8(), a = u8()
            return .solid(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255))
        default:
            let id = u32()
            let transform = affine()
            let repeats = u8() == 1
            return .pattern(image: id, transform: transform, repeats: repeats)
        }
    }

    mutating func stroke() -> DLStroke {
        let paint = paint()
        let width = cg()
        let cap: CGLineCap = [.butt, .round, .square][Int(min(u8(), 2))]
        let join: CGLineJoin = [.miter, .round, .bevel][Int(min(u8(), 2))]
        let miter = cg()
        let count = u32()
        var dash: [CGFloat] = []
        var phase: CGFloat = 0
        if count > 0 {
            phase = cg()
            for _ in 0..<count { dash.append(cg()) }
        }
        return DLStroke(paint: paint, width: width, cap: cap, join: join, miter: miter, dash: dash, phase: phase)
    }
}

extension DisplayList {
    /// Parses the core's binary display list.
    init?(data: Data) {
        guard data.count >= 12, data.prefix(4) == Data("TDL1".utf8) else { return nil }
        var r = ByteReader(data)
        r.offset = 4
        size = CGSize(width: r.cg(), height: r.cg())
        ops = []
        loop: while !r.atEnd {
            switch r.u8() {
            case 0x01: ops.append(.save)
            case 0x02: ops.append(.restore)
            case 0x03:
                let t = r.affine()
                ops.append(.clip(t, r.path()))
            case 0x10:
                let t = r.affine()
                let path = r.path()
                let evenOdd = r.u8() == 1
                ops.append(.fill(t, path, evenOdd: evenOdd, r.paint()))
            case 0x11:
                let t = r.affine()
                let path = r.path()
                ops.append(.stroke(t, path, r.stroke()))
            case 0x20:
                let t = r.affine()
                let font = r.u32()
                let scale = r.cg()
                let paint = r.paint()
                let stroke = r.u8() == 1 ? r.stroke() : nil
                let count = Int(r.u32())
                var glyphs: [(id: UInt16, x: Float, y: Float)] = []
                glyphs.reserveCapacity(count)
                for _ in 0..<count {
                    glyphs.append((r.u16(), r.f32(), r.f32()))
                }
                ops.append(.glyphs(t, GlyphRun(font: font, scale: scale, glyphs: glyphs), paint, stroke, path: nil))
            case 0x30:
                let t = r.affine()
                let id = r.u32()
                let size = CGSize(width: r.cg(), height: r.cg())
                ops.append(.image(t, id, size, smooth: r.u8() == 1))
            default:
                break loop
            }
        }
    }
}

/// Fonts' glyph outlines and decoded images for one project. Shared by all
/// preview windows of a workspace; accessed from background queues.
final class PreviewResources: @unchecked Sendable {
    private let lock = NSLock()
    private var glyphs: [UInt32: [UInt16: CGPath]] = [:]
    private var images: [UInt32: CGImage] = [:]
    private let project: Project

    init(project: Project) {
        self.project = project
    }

    /// Resolves glyph paths and images used by a display list.
    func prepare(_ list: inout DisplayList) {
        // Collect missing glyphs per font.
        var missing: [UInt32: Set<UInt16>] = [:]
        var imageIDs: Set<UInt32> = []
        lock.lock()
        for op in list.ops {
            switch op {
            case let .glyphs(_, run, paint, stroke, _):
                let known = glyphs[run.font]
                for g in run.glyphs where known?[g.id] == nil {
                    missing[run.font, default: []].insert(g.id)
                }
                if case let .pattern(id, _, _) = paint { imageIDs.insert(id) }
                if case let .pattern(id, _, _)? = stroke?.paint { imageIDs.insert(id) }
            case let .fill(_, _, _, .pattern(id, _, _)):
                imageIDs.insert(id)
            case let .stroke(_, _, stroke):
                if case let .pattern(id, _, _) = stroke.paint { imageIDs.insert(id) }
            case let .image(_, id, _, _):
                imageIDs.insert(id)
            default:
                break
            }
        }
        imageIDs = imageIDs.filter { images[$0] == nil }
        lock.unlock()

        for (font, ids) in missing {
            let blob = project.glyphOutlines(font: font, glyphs: Array(ids))
            let parsed = Self.parseOutlines(blob)
            lock.lock()
            glyphs[font, default: [:]].merge(parsed) { a, _ in a }
            lock.unlock()
        }
        for id in imageIDs {
            guard let data = project.image(id: id), let image = Self.decode(data) else { continue }
            lock.lock()
            images[id] = image
            lock.unlock()
        }

        // Build one path per glyph run.
        lock.lock()
        defer { lock.unlock() }
        for i in list.ops.indices {
            guard case let .glyphs(t, run, paint, stroke, _) = list.ops[i] else { continue }
            let path = CGMutablePath()
            let table = glyphs[run.font] ?? [:]
            for g in run.glyphs {
                guard let outline = table[g.id] else { continue }
                let transform = CGAffineTransform(a: run.scale, b: 0, c: 0, d: -run.scale, tx: CGFloat(g.x), ty: CGFloat(g.y))
                path.addPath(outline, transform: transform)
            }
            list.ops[i] = .glyphs(t, run, paint, stroke, path: path)
        }
    }

    func image(_ id: UInt32) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[id]
    }

    private static func parseOutlines(_ data: Data) -> [UInt16: CGPath] {
        guard data.count >= 4 else { return [:] }
        var r = ByteReader(data)
        _ = r.f32()  // units per em
        var out: [UInt16: CGPath] = [:]
        while !r.atEnd {
            let id = r.u16()
            out[id] = r.path()
        }
        return out
    }

    private static func decode(_ data: ImageData) -> CGImage? {
        if data.rgba {
            guard let provider = CGDataProvider(data: data.bytes as CFData) else { return nil }
            return CGImage(
                width: Int(data.width), height: Int(data.height),
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(data.width) * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        guard let source = CGImageSourceCreateWithData(data.bytes as CFData, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        if let image = CGImageSourceCreateImageAtIndex(source, 0, options) {
            return image
        }
        // WebP and other formats ImageIO may hand to NSImage instead.
        return NSImage(data: data.bytes)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

/// Draws display lists into a y-down Core Graphics context.
enum DisplayListRenderer {
    static func draw(_ list: DisplayList, in ctx: CGContext, resources: PreviewResources) {
        var depth = 0
        for op in list.ops {
            switch op {
            case .save:
                ctx.saveGState()
                depth += 1
            case .restore:
                if depth > 0 {
                    ctx.restoreGState()
                    depth -= 1
                }
            case let .clip(t, path):
                ctx.addPath(path.copy(using: [t]) ?? path)
                ctx.clip()
            case let .fill(t, path, evenOdd, paint):
                ctx.saveGState()
                ctx.concatenate(t)
                fill(path, evenOdd: evenOdd, paint: paint, in: ctx, resources: resources)
                ctx.restoreGState()
            case let .stroke(t, path, stroke):
                ctx.saveGState()
                ctx.concatenate(t)
                self.stroke(path, stroke, in: ctx, resources: resources)
                ctx.restoreGState()
            case let .glyphs(t, _, paint, stroke, path):
                guard let path, !path.isEmpty else { continue }
                ctx.saveGState()
                ctx.concatenate(t)
                fill(path, evenOdd: false, paint: paint, in: ctx, resources: resources)
                if let stroke {
                    self.stroke(path, stroke, in: ctx, resources: resources)
                }
                ctx.restoreGState()
            case let .image(t, id, size, smooth):
                guard let image = resources.image(id) else { continue }
                ctx.saveGState()
                ctx.concatenate(t)
                ctx.interpolationQuality = smooth ? .high : .none
                drawFlipped(image, in: CGRect(origin: .zero, size: size), ctx: ctx)
                ctx.restoreGState()
            }
        }
        while depth > 0 {
            ctx.restoreGState()
            depth -= 1
        }
    }

    private static func drawFlipped(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    private static func fill(_ path: CGPath, evenOdd: Bool, paint: DLPaint, in ctx: CGContext, resources: PreviewResources) {
        switch paint {
        case let .solid(color):
            ctx.setFillColor(color)
            ctx.addPath(path)
            ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
        case let .pattern(id, transform, repeats):
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip(using: evenOdd ? .evenOdd : .winding)
            drawPattern(id, transform: transform, repeats: repeats, bounds: path.boundingBoxOfPath, in: ctx, resources: resources)
            ctx.restoreGState()
        }
    }

    private static func stroke(_ path: CGPath, _ stroke: DLStroke, in ctx: CGContext, resources: PreviewResources) {
        ctx.setLineWidth(stroke.width)
        ctx.setLineCap(stroke.cap)
        ctx.setLineJoin(stroke.join)
        ctx.setMiterLimit(stroke.miter)
        if !stroke.dash.isEmpty {
            ctx.setLineDash(phase: stroke.phase, lengths: stroke.dash)
        }
        switch stroke.paint {
        case let .solid(color):
            ctx.setStrokeColor(color)
            ctx.addPath(path)
            ctx.strokePath()
        case let .pattern(id, transform, repeats):
            ctx.saveGState()
            ctx.addPath(path)
            ctx.replacePathWithStrokedPath()
            let bounds = ctx.boundingBoxOfPath
            ctx.clip()
            drawPattern(id, transform: transform, repeats: repeats, bounds: bounds, in: ctx, resources: resources)
            ctx.restoreGState()
        }
    }

    /// Draws an image pattern whose pixels map to item space via `transform`.
    private static func drawPattern(
        _ id: UInt32, transform: CGAffineTransform, repeats: Bool, bounds: CGRect,
        in ctx: CGContext, resources: PreviewResources
    ) {
        guard let image = resources.image(id) else { return }
        ctx.concatenate(transform)
        let tile = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.interpolationQuality = .medium
        if !repeats {
            drawFlipped(image, in: tile, ctx: ctx)
            return
        }
        // Cover the bounds (mapped into pattern space) with tiles.
        let area = bounds.applying(transform.inverted())
        guard tile.width > 0, tile.height > 0, area.width.isFinite, area.height.isFinite else { return }
        let x0 = floor(area.minX / tile.width), x1 = ceil(area.maxX / tile.width)
        let y0 = floor(area.minY / tile.height), y1 = ceil(area.maxY / tile.height)
        guard (x1 - x0) * (y1 - y0) < 20_000 else { return }
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                drawFlipped(image, in: tile.offsetBy(dx: x * tile.width, dy: y * tile.height), ctx: ctx)
                x += 1
            }
            y += 1
        }
    }
}
