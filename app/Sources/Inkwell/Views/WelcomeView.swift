import AppKit
import SwiftUI
import TypstCore

/// The launch window: open a folder, start from a template, recent projects.
struct WelcomeView: View {
    @ObservedObject private var recents = RecentProjects.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                Spacer().frame(height: 26)
                AppIconView().frame(width: 96, height: 96)
                Text("Inkwell").font(.system(size: 30, weight: .bold))
                VStack(spacing: 2) {
                    Text("Version \(Bundle.main.shortVersion)").foregroundStyle(.secondary)
                    Text("Typst \(typstVersionString)").font(.caption).foregroundStyle(.tint)
                }
                VStack(spacing: 8) {
                    action("folder", "Open Folder…") { AppActions.openFolderPanel() }
                    action("doc.badge.plus", "New Project from Template…") { openWindow(id: "templates") }
                    action("doc", "Open File…") { AppActions.openFilePanel() }
                }
                .padding(.top, 14)
                Text("Opening a file opens its folder as the project.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 40)
            .frame(width: 480)

            VStack(alignment: .leading, spacing: 0) {
                Text("Recent Projects").font(.headline).padding(16)
                if recents.urls.isEmpty {
                    Text("No recent projects").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(recents.urls, id: \.self) { url in
                        Button {
                            AppActions.open(url)
                            dismissWindow(id: "welcome")
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill").foregroundStyle(.tint).font(.title3)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.lastPathComponent).font(.system(size: 13, weight: .medium))
                                    Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Button("Remove from Recents") { recents.remove(url) }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(width: 280)
            .background(.ultraThinMaterial)
        }
        .frame(width: 760, height: 464)
        .onAppear {
            AppActions.openWindowAction = openWindow
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { dismissIfProjectsOpen() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .projectWindowOpened)) { _ in
            dismissIfProjectsOpen()
        }
    }

    private var typstVersionString: String { typstVersion() }

    private func dismissIfProjectsOpen() {
        if NSApp.windows.contains(where: { $0.representedURL != nil && $0.isVisible }) {
            dismissWindow(id: "welcome")
        }
    }

    private func action(_ icon: String, _ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 20).foregroundStyle(.tint)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The app icon.
struct AppIconView: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage).resizable().aspectRatio(contentMode: .fit)
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
}

/// Inkwell has no account or license; this shows release notes once per version.
enum WhatsNew {
    /// Shows release notes once after an update (not on first install).
    static func showIfUpdated() {
        let key = "lastSeenVersion"
        let current = Bundle.main.shortVersion
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(current, forKey: key)
        guard let previous, previous != current, ProcessInfo.processInfo.environment["INKWELL_SELFTEST"] == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated { AppActions.openWindowAction?(id: "whats-new") }
        }
    }
}

struct WhatsNewView: View {
    @State private var index = 0
    @Environment(\.dismissWindow) private var dismissWindow

    struct Slide {
        let symbol: String
        let title: LocalizedStringKey
        let text: LocalizedStringKey
    }

    let slides = [
        Slide(symbol: "bolt.horizontal", title: "Instant vector preview", text: "Pages are drawn as vectors straight from the Typst layout — crisp at every zoom, updated as you type."),
        Slide(symbol: "cursorarrow.click.2", title: "Click to jump", text: "Click anything in the preview to jump to its source. The preview follows your caret, too."),
        Slide(symbol: "text.magnifyingglass", title: "Completions and docs", text: "Autocomplete, hover documentation and the full Typst reference, available offline."),
        Slide(symbol: "keyboard", title: "Make it yours", text: "Seven editor themes, Vim key bindings and typing sounds — all in Settings."),
    ]

    var body: some View {
        VStack(spacing: 18) {
            let slide = slides[index]
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [.accentColor.opacity(0.5), .purple.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: slide.symbol).font(.system(size: 72, weight: .light)).foregroundStyle(.white)
            }
            .frame(width: 600, height: 375)
            Text(slide.title).font(.title2.bold())
            Text(slide.text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 460)
            HStack {
                Button("Previous") { index -= 1 }.disabled(index == 0)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(slides.indices, id: \.self) { i in
                        Circle().fill(i == index ? Color.accentColor : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if index == slides.count - 1 {
                    Button("Continue") { dismissWindow(id: "whats-new") }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Next") { index += 1 }.keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 600)
        }
        .padding(28)
    }
}

enum WelcomeWindow {
    /// The welcome window steps aside once a project window is open.
    static func closeIfProjectsOpen() {
        NotificationCenter.default.post(name: .projectWindowOpened, object: nil)
    }
}

extension Notification.Name {
    static let projectWindowOpened = Notification.Name("InkwellProjectWindowOpened")
}
