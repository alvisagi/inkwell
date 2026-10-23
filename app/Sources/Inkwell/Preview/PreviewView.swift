import AppKit
import Combine
import SwiftUI
import TypstCore

/// Caches parsed display lists by page hash.
final class PreviewStore {
    private var lists: [String: DisplayList] = [:]
    private var loading: Set<String> = []
    private let queue = DispatchQueue(label: "inkwell.preview", qos: .userInitiated)
    private let project: Project
    private let resources: PreviewResources

    init(project: Project, resources: PreviewResources) {
        self.project = project
        self.resources = resources
    }

    func cached(_ hash: String) -> DisplayList? { lists[hash] }

    /// Pages rendered by an older Typst CLI (no display list available).
    private var legacyImages: [String: NSImage] = [:]

    func setLegacyImage(_ image: NSImage, for hash: String) {
        legacyImages[hash] = image
    }

    func legacyImage(_ hash: String) -> NSImage? { legacyImages[hash] }

    /// Loads a page's display list in the background.
    func load(page: Int, hash: String, current: @escaping () -> String?, completion: @escaping (DisplayList) -> Void) {
        if let list = lists[hash] {
            completion(list)
            return
        }
        guard !loading.contains(hash) else { return }
        loading.insert(hash)
        let project = project, resources = resources
        queue.async {
            let data = project.displayList(page: UInt32(page))
            var list = DisplayList(data: data)
            if list != nil { resources.prepare(&list!) }
            DispatchQueue.main.async {
                self.loading.remove(hash)
                // The page may have changed while we were loading.
                guard current() == hash, let list else { return }
                self.lists[hash] = list
                completion(list)
            }
        }
    }

    func prune(keeping hashes: Set<String>) {
        lists = lists.filter { hashes.contains($0.key) }
        legacyImages = legacyImages.filter { hashes.contains($0.key) }
    }
}

/// UI state of one preview (main window or detached).
final class PreviewState: ObservableObject {
    @Published var magnification: CGFloat = 1
    @Published var currentPage = 0
    @Published var fitLocked = true
    /// Pages side by side in a grid instead of a single column.
    @Published var galleryMode = false {
        didSet { relayout() }
    }
    var relayout: () -> Void = {}
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var fit: () -> Void = {}
    var setZoom: (CGFloat) -> Void = { _ in }
    var goToPage: (Int) -> Void = { _ in }
}

/// One page of the preview.
final class PageView: NSView {
    var index = 0
    var info: PageInfo?
    var list: DisplayList? { didSet { needsDisplay = true } }
    var legacyImage: NSImage? { didSet { needsDisplay = true } }
    weak var resources: PreviewResources?
    var onClick: ((Int, CGPoint) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.white.setFill()
        bounds.fill()
        if list == nil, let legacyImage {
            legacyImage.draw(in: bounds)
            return
        }
        guard let list, let resources, list.size.width > 0 else { return }
        ctx.saveGState()
        ctx.clip(to: dirtyRect)
        ctx.scaleBy(x: bounds.width / list.size.width, y: bounds.height / list.size.height)
        DisplayListRenderer.draw(list, in: ctx, resources: resources)
        ctx.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let info, bounds.width > 0 else { return }
        let pt = CGPoint(x: point.x / bounds.width * info.width, y: point.y / bounds.height * info.height)
        if AppSettings.shared.rippleOnClick { ripple(at: point) }
        // Pages from an older compiler carry no source information.
        if legacyImage == nil { onClick?(index, pt) }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// A soft expanding circle where the user clicked.
    func ripple(at point: CGPoint) {
        guard let layer else { return }
        let ripple = CAShapeLayer()
        let radius: CGFloat = 26
        ripple.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        ripple.position = point
        ripple.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        ripple.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        ripple.lineWidth = 1.5
        layer.addSublayer(ripple)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.2
        scale.toValue = 1.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.55
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ripple.opacity = 0
        ripple.add(group, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ripple.removeFromSuperlayer() }
    }

    /// Briefly marks a point (after jumping from the editor).
    func flash(at point: CGPoint) {
        guard let layer, let info, info.width > 0 else { return }
        let x = point.x / info.width * bounds.width
        let y = point.y / info.height * bounds.height
        let marker = CALayer()
        let height = max(10, 14 * bounds.width / info.width)
        marker.frame = CGRect(x: x - 1.5, y: y - height * 0.8, width: 3, height: height)
        marker.cornerRadius = 1.5
        marker.backgroundColor = NSColor.controlAccentColor.cgColor
        layer.addSublayer(marker)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 0.6
        fade.duration = 0.6
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        marker.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { marker.removeFromSuperlayer() }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The scrollable stack of pages.
final class PreviewScrollView: NSScrollView {
    static let gap: CGFloat = 14
    static let padding: CGFloat = 18

    private let container = FlippedView()
    private var pageViews: [PageView] = []
    private var cancellables: Set<AnyCancellable> = []
    weak var workspace: Workspace?
    var store: PreviewStore?
    var state: PreviewState?
    private var pages: [PageInfo] = []
    private var ignoreScroll = false

    init(workspace: Workspace, state: PreviewState) {
        super.init(frame: .zero)
        self.workspace = workspace
        self.state = state
        store = workspace.previewStore
        documentView = container
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.1
        maxMagnification = 10
        drawsBackground = true
        backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.88, alpha: 1)
        }
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(magnified), name: NSScrollView.didEndLiveMagnifyNotification, object: self)

        workspace.$pages.receive(on: DispatchQueue.main).sink { [weak self] pages in
            self?.update(pages)
        }.store(in: &cancellables)
        workspace.previewScroll.receive(on: DispatchQueue.main).sink { [weak self] target in
            self?.scroll(to: target)
        }.store(in: &cancellables)

        state.zoomIn = { [weak self] in self?.zoom(by: 1.25) }
        state.zoomOut = { [weak self] in self?.zoom(by: 0.8) }
        state.fit = { [weak self] in self?.fitButton() }
        state.setZoom = { [weak self] value in self?.setMagnification(value, keepFit: false) }
        state.relayout = { [weak self] in
            guard let self else { return }
            if state.galleryMode {
                self.state?.fitLocked = false
                self.setMagnification(0.35, keepFit: true)
            } else {
                self.fitWidth()
                self.state?.fitLocked = true
            }
            self.layoutPages()
        }
        state.goToPage = { [weak self] page in self?.scroll(to: PreviewTarget(page: page, point: .zero, highlight: false), top: true) }
        update(workspace.pages)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func update(_ newPages: [PageInfo]) {
        let old = pages
        pages = newPages
        while pageViews.count < pages.count {
            let view = PageView()
            view.resources = workspace?.resources
            view.onClick = { [weak self] page, point in self?.workspace?.previewClicked(page: page, point: point) }
            container.addSubview(view)
            pageViews.append(view)
        }
        while pageViews.count > pages.count {
            pageViews.removeLast().removeFromSuperview()
        }
        for (i, info) in pages.enumerated() {
            let view = pageViews[i]
            view.index = i
            let changed = i >= old.count || old[i].hash != info.hash
            view.info = info
            if changed {
                if let image = store?.legacyImage(info.hash) {
                    view.list = nil
                    view.legacyImage = image
                } else if let cached = store?.cached(info.hash) {
                    view.legacyImage = nil
                    view.list = cached
                } else {
                    view.legacyImage = nil
                    load(i)
                }
            }
        }
        store?.prune(keeping: Set(pages.map(\.hash)))
        layoutPages()
        if state?.fitLocked == true, old.isEmpty || old.first?.width != pages.first?.width {
            fitWidth()
        }
    }

    private func load(_ index: Int) {
        guard index < pages.count else { return }
        let hash = pages[index].hash
        store?.load(page: index, hash: hash, current: { [weak self] in
            guard let self, index < self.pages.count else { return nil }
            return self.pages[index].hash
        }) { [weak self] list in
            guard let self, index < self.pageViews.count else { return }
            self.pageViews[index].list = list
        }
    }

    private func layoutPages() {
        let maxWidth = pages.map(\.width).max() ?? 0
        let visibleWidth = contentView.bounds.width
        let width = max(maxWidth + Self.padding * 2, visibleWidth)
        guard state?.galleryMode == true, maxWidth > 0 else {
            var y = Self.padding
            for (i, info) in pages.enumerated() {
                let x = (width - info.width) / 2
                pageViews[i].frame = NSRect(x: x, y: y, width: info.width, height: info.height)
                y += info.height + Self.gap
            }
            container.frame = NSRect(x: 0, y: 0, width: width, height: max(y - Self.gap + Self.padding, contentView.bounds.height))
            return
        }
        // Gallery: as many columns as fit the visible width.
        let columns = max(1, Int((visibleWidth - Self.padding * 2 + Self.gap) / (maxWidth + Self.gap)))
        let rowWidth = CGFloat(columns) * maxWidth + CGFloat(columns - 1) * Self.gap
        let left = max(Self.padding, (width - rowWidth) / 2)
        var y = Self.padding
        var index = 0
        while index < pages.count {
            let row = pages[index..<min(index + columns, pages.count)]
            let rowHeight = row.map(\.height).max() ?? 0
            for (column, info) in row.enumerated() {
                let x = left + CGFloat(column) * (maxWidth + Self.gap) + (maxWidth - info.width) / 2
                pageViews[index + column].frame = NSRect(x: x, y: y, width: info.width, height: info.height)
            }
            y += rowHeight + Self.gap
            index += columns
        }
        container.frame = NSRect(x: 0, y: 0, width: width, height: max(y - Self.gap + Self.padding, contentView.bounds.height))
    }

    override func layout() {
        super.layout()
        layoutPages()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if state?.fitLocked == true { fitWidth() }
    }

    // MARK: Zoom

    private func zoom(by factor: CGFloat) {
        state?.fitLocked = false
        setMagnification(magnification * factor, keepFit: false)
    }

    private func setMagnification(_ value: CGFloat, keepFit: Bool) {
        let clamped = max(minMagnification, min(maxMagnification, value))
        let center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(clamped, centeredAt: center)
        if !keepFit { state?.fitLocked = false }
        state?.magnification = clamped
    }

    /// First click fits once; clicking again while fitted locks the fit.
    private func fitButton() {
        let fitted = abs(magnification - fitMagnification) < 0.005
        if fitted {
            state?.fitLocked.toggle()
        } else {
            fitWidth()
        }
    }

    private var fitMagnification: CGFloat {
        let maxWidth = pages.map(\.width).max() ?? 595
        let available = frame.width - 2 * Self.padding / max(magnification, 0.1) - (verticalScroller?.frame.width ?? 0)
        return max(minMagnification, min(maxMagnification, available / (maxWidth + 2 * Self.padding)))
    }

    private func fitWidth() {
        guard !pages.isEmpty, frame.width > 0, state?.galleryMode != true else { return }
        let target = fitMagnification
        let anchorY = contentView.bounds.minY
        magnification = target
        state?.magnification = target
        layoutPages()
        contentView.scroll(to: NSPoint(x: 0, y: anchorY))
        reflectScrolledClipView(contentView)
    }

    @objc private func magnified() {
        state?.magnification = magnification
        state?.fitLocked = false
    }

    // MARK: Scrolling

    @objc private func scrolled() {
        guard !pageViews.isEmpty else { return }
        let mid = contentView.bounds.midY
        let page = pageViews.firstIndex { $0.frame.maxY + Self.gap / 2 >= mid } ?? pageViews.count - 1
        if state?.currentPage != page { state?.currentPage = page }
    }

    func scroll(to target: PreviewTarget, top: Bool = false) {
        guard target.page < pageViews.count else { return }
        let view = pageViews[target.page]
        guard let info = view.info else { return }
        let local = CGPoint(x: target.point.x / info.width * view.bounds.width, y: target.point.y / info.height * view.bounds.height)
        let point = container.convert(local, from: view)
        let visible = contentView.bounds
        var origin = visible.origin
        if top {
            origin.y = view.frame.minY - Self.padding
        } else if !visible.insetBy(dx: 0, dy: visible.height * 0.15).contains(CGPoint(x: visible.midX, y: point.y)) {
            origin.y = point.y - visible.height / 3
        } else if !target.highlight {
            return
        }
        origin.y = max(0, min(origin.y, container.frame.height - visible.height))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            contentView.animator().setBoundsOrigin(origin)
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.reflectScrolledClipView(self.contentView)
        }
        if target.highlight { view.flash(at: target.point) }
    }
}

struct PreviewRepresentable: NSViewRepresentable {
    let workspace: Workspace
    let state: PreviewState

    func makeNSView(context: Context) -> PreviewScrollView {
        PreviewScrollView(workspace: workspace, state: state)
    }

    func updateNSView(_ view: PreviewScrollView, context: Context) {}
}
