import AppKit
import TypstCore

/// The Typst Universe package list, fetched once per launch.
final class PackageIndex: ObservableObject {
    static let shared = PackageIndex()

    @Published private(set) var packages: [UniversePackage] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var thumbnails: [String: NSImage] = [:]
    private let thumbnailQueue = DispatchQueue(label: "inkwell.thumbnails", attributes: .concurrent)

    private init() {}

    var templates: [UniversePackage] { packages.filter { $0.templatePath != nil } }

    func load(force: Bool = false) {
        guard force || (packages.isEmpty && !isLoading) else { return }
        isLoading = true
        error = nil
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try fetchUniverse() }
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case let .success(list): self.packages = list.sorted { $0.name < $1.name }
                case let .failure(err): self.error = "\(err)"
                }
            }
        }
    }

    func thumbnail(for package: UniversePackage, completion: @escaping (NSImage?) -> Void) {
        guard let url = package.thumbnail else {
            completion(nil)
            return
        }
        if let cached = thumbnails[url] {
            completion(cached)
            return
        }
        thumbnailQueue.async {
            let image = (try? httpGet(url: url)).flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                if let image { self.thumbnails[url] = image }
                completion(image)
            }
        }
    }
}
