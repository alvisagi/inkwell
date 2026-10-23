import AppKit
import PDFKit
import SwiftUI

/// Shows images and PDFs selected in the sidebar.
struct MediaView: View {
    let url: URL

    var body: some View {
        switch FileKind(url: url, isDirectory: false) {
        case .image:
            if let image = NSImage(contentsOf: url) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: max(image.size.width, 100), maxHeight: max(image.size.height, 100))
                        .padding(20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            } else {
                unsupported
            }
        case .pdf:
            PDFViewer(url: url)
        default:
            unsupported
        }
    }

    private var unsupported: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.questionmark").font(.system(size: 32)).foregroundStyle(.tertiary)
            Text("Not Supported").font(.headline)
            Text("This file format is not supported. Please select a .typ file, a PDF, or an image.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open with Default App") { NSWorkspace.shared.open(url) }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PDFViewer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}
