import AppKit
import TypstCore

/// Older Typst releases, downloaded on demand and run as a CLI for documents
/// that only build on an earlier version.
final class CompilerManager: ObservableObject {
    static let shared = CompilerManager()

    struct Release: Identifiable, Hashable {
        let version: String
        let note: String
        var id: String { version }
    }

    static let latest = "latest"

    let releases: [Release] = [
        Release(version: "0.14.2", note: "Compile with an older release for documents that don't build on the latest."),
        Release(version: "0.13.1", note: "Compile with an older release for documents that don't build on the latest."),
        Release(version: "0.12.0", note: "Compile with an older release for documents that don't build on the latest."),
        Release(version: "0.11.1", note: "For documents that only build on an early Typst. Only the built-in default fonts are available, jump from preview to editor does not work."),
    ]

    @Published var selected: String {
        didSet { UserDefaults.standard.set(selected, forKey: "compilerVersion") }
    }
    @Published private(set) var downloading: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var installedVersions: Set<String> = []

    private init() {
        selected = UserDefaults.standard.string(forKey: "compilerVersion") ?? Self.latest
        refresh()
        if selected != Self.latest, !installedVersions.contains(selected) { selected = Self.latest }
    }

    var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Inkwell/compilers", isDirectory: true)
    }

    func binary(_ version: String) -> URL {
        directory.appendingPathComponent(version).appendingPathComponent("typst")
    }

    /// The CLI to use, or nil for the built-in compiler.
    var activeBinary: URL? {
        guard selected != Self.latest, installedVersions.contains(selected) else { return nil }
        return binary(selected)
    }

    var activeVersionLabel: String {
        selected == Self.latest ? typstVersion() : selected
    }

    func refresh() {
        installedVersions = Set(releases.map(\.version).filter {
            FileManager.default.isExecutableFile(atPath: binary($0).path)
        })
    }

    func download(_ version: String) {
        guard !downloading.contains(version) else { return }
        downloading.insert(version)
        errors[version] = nil
        let target = directory.appendingPathComponent(version)
        let arch = ProcessInfo.processInfo.machineHardwareName == "x86_64" ? "x86_64" : "aarch64"
        let name = "typst-\(arch)-apple-darwin"
        let url = "https://github.com/typst/typst/releases/download/v\(version)/\(name).tar.xz"
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Void, Error> = Result {
                let data = try httpGet(url: url)
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: temp) }
                let archive = temp.appendingPathComponent("typst.tar.xz")
                try data.write(to: archive)
                let tar = Process()
                tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                tar.arguments = ["-xJf", archive.path, "-C", temp.path]
                try tar.run()
                tar.waitUntilExit()
                guard tar.terminationStatus == 0 else { throw CompilerError.message("Couldn't unpack the download.") }
                let extracted = temp.appendingPathComponent(name).appendingPathComponent("typst")
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let dest = target.appendingPathComponent("typst")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: extracted, to: dest)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
                // Downloaded binaries carry a quarantine flag; we fetched it ourselves.
                let xattr = Process()
                xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                xattr.arguments = ["-d", "com.apple.quarantine", dest.path]
                try? xattr.run()
                xattr.waitUntilExit()
            }
            DispatchQueue.main.async {
                self.downloading.remove(version)
                if case let .failure(error) = result { self.errors[version] = "\(error)" }
                self.refresh()
            }
        }
    }

    func delete(_ version: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(version))
        if selected == version { selected = Self.latest }
        refresh()
    }

    enum CompilerError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self {
            case let .message(m): m
            }
        }
    }
}

extension ProcessInfo {
    var machineHardwareName: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
    }
}

/// Runs an older Typst CLI and turns its output into preview pages.
enum LegacyCompiler {
    struct Output {
        var pages: [(info: PageInfo, image: NSImage)]
        var diagnostics: [TypstCore.Diagnostic]
        var success: Bool
    }

    static func compile(binary: URL, root: URL, main: URL) -> Output {
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("inkwell-legacy-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "compile", "--root", root.path, "--diagnostic-format", "short",
            main.path, outDir.appendingPathComponent("page-{p}.svg").path,
        ]
        process.currentDirectoryURL = root
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            return Output(pages: [], diagnostics: [plain("Couldn't run Typst: \(error.localizedDescription)")], success: false)
        }
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let diagnostics = parse(String(decoding: errData, as: UTF8.self), root: root)

        var pages: [(PageInfo, NSImage)] = []
        let files = ((try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "svg" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for file in files {
            guard let data = try? Data(contentsOf: file), let image = NSImage(data: data) else { continue }
            let hash = String(data.hashValue, radix: 16) + "-\(data.count)"
            pages.append((PageInfo(width: image.size.width, height: image.size.height, hash: "legacy-" + hash), image))
        }
        return Output(pages: pages, diagnostics: diagnostics, success: process.terminationStatus == 0)
    }

    private static func plain(_ message: String) -> TypstCore.Diagnostic {
        TypstCore.Diagnostic(isError: true, message: message, hints: [], path: nil, inPackage: false, line: nil, column: nil, start: nil, end: nil)
    }

    /// Parses `path:line:col: error: message` lines.
    static func parse(_ text: String, root: URL) -> [TypstCore.Diagnostic] {
        var out: [TypstCore.Diagnostic] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5, let lineNo = UInt32(parts[1]), let col = UInt32(parts[2]) else {
                if line.hasPrefix("error:") { out.append(plain(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces))) }
                continue
            }
            let severity = parts[3].trimmingCharacters(in: .whitespaces)
            let path = parts[0].hasPrefix("/") ? parts[0] : root.appendingPathComponent(parts[0]).path
            var diag = plain(parts[4].trimmingCharacters(in: .whitespaces))
            diag.isError = severity == "error"
            diag.path = path
            diag.line = lineNo
            diag.column = col
            diag.inPackage = parts[0].contains("@")
            // Convert line/column to a UTF-16 offset for jumping.
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                let ns = text as NSString
                var offset = 0
                var current: UInt32 = 1
                while current < lineNo, offset < ns.length {
                    let range = ns.lineRange(for: NSRange(location: offset, length: 0))
                    offset = NSMaxRange(range)
                    current += 1
                }
                diag.start = UInt64(min(offset + Int(col) - 1, ns.length))
                diag.end = diag.start
            }
            out.append(diag)
        }
        return out
    }
}
