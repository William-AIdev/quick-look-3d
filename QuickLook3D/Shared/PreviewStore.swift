import Foundation
import CryptoKit
import Darwin

struct PreviewSettings: Codable, Equatable {
    var quality = "economy"
    var framesPerSecond = 30
    var animate = true
    var cacheEnabled = true
    var cacheMegabytes = 1024
    var maximumFileMegabytes = 256
    var recursive = true
    var textureLimit: Int { quality == "original" ? 0 : quality == "balanced" ? 2048 : 1024 }
    var pixelRatio: Double { quality == "original" ? 2 : quality == "balanced" ? 1.5 : 1 }
    mutating func validate() {
        if !["economy", "balanced", "original"].contains(quality) { quality = "economy" }
        framesPerSecond = min(60, max(10, framesPerSecond))
        cacheMegabytes = min(262144, max(64, cacheMegabytes))
        maximumFileMegabytes = min(2048, max(16, maximumFileMegabytes))
    }
}

struct CacheStatistics {
    var count = 0
    var bytes: Int64 = 0
}

struct PreparedPreview {
    let data: Data
    let cacheHit: Bool
    let reducedTextures: Int
}

final class PreviewStore {
    static let supportedExtensions: Set<String> = ["glb", "vrm", "vrma", "fbx"]
    let root: URL
    private let manager = FileManager.default
    private var cache: URL { root.appendingPathComponent("Previews-v1", isDirectory: true) }
    private struct Entry: Codable {
        let source: String
        let sourceBytes: Int64
        let sourceModified: Date
        let reducedTextures: Int
        let digest: String
    }
    init(root: URL? = nil) throws {
        let directory: URL
        if let root = root { directory = root }
        else {
            guard let home = getpwuid(getuid())?.pointee.pw_dir else { throw CocoaError(.fileReadNoPermission) }
            directory = URL(fileURLWithPath: String(cString: home), isDirectory: true).appendingPathComponent("Library/Application Support/QuickLook3D-Shared", isDirectory: true)
        }
        self.root = directory.appendingPathComponent("PreviewWorkspace", isDirectory: true)
        try manager.createDirectory(at: self.root, withIntermediateDirectories: true)
        try manager.createDirectory(at: cache, withIntermediateDirectories: true)
    }
    private func coordinated<T>(_ action: () throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: root, options: .forMerging, error: &coordinationError) { _ in
            result = Result { try action() }
        }
        if let error = coordinationError { throw error }
        guard let result = result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }
    func settings() -> PreviewSettings {
        (try? coordinated {
            var value = try JSONDecoder().decode(PreviewSettings.self, from: Data(contentsOf: root.appendingPathComponent("settings.json")))
            value.validate()
            return value
        }) ?? PreviewSettings()
    }
    func save(_ settings: PreviewSettings) throws {
        var value = settings
        value.validate()
        try coordinated {
            try JSONEncoder().encode(value).write(to: root.appendingPathComponent("settings.json"), options: .atomic)
            try evict(budget: Int64(value.cacheMegabytes) * 1024 * 1024)
        }
    }
    private func metadata(_ url: URL) throws -> (Int64, Date) {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
        return (Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
    }
    private func key(_ url: URL, _ size: Int64, _ date: Date, _ settings: PreviewSettings) -> String {
        let text = "v1|\(url.standardizedFileURL.path)|\(size)|\(date.timeIntervalSince1970)|\(settings.textureLimit)"
        return Self.digest(Data(text.utf8))
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func prepare(_ source: URL, settings: PreviewSettings, cancelled: () -> Bool = { false }) throws -> PreparedPreview {
        let initial = try metadata(source)
        guard initial.0 <= Int64(settings.maximumFileMegabytes) * 1024 * 1024 else {
            throw NSError(domain: "QuickLook3D", code: 2, userInfo: [NSLocalizedDescriptionKey: "文件超过设置的单文件大小上限"])
        }
        if cancelled() { throw CocoaError(.userCancelled) }
        let identifier = key(source, initial.0, initial.1, settings)
        let binary = cache.appendingPathComponent(identifier + ".bin")
        let manifest = cache.appendingPathComponent(identifier + ".json")
        if settings.cacheEnabled, let hit: PreparedPreview = try coordinated({
            guard let record = try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: manifest)),
                  record.source == source.standardizedFileURL.path,
                  record.sourceBytes == initial.0, record.sourceModified == initial.1,
                  let data = try? Data(contentsOf: binary), Self.digest(data) == record.digest else { return nil }
            let current = try metadata(source)
            guard current.0 == initial.0, current.1 == initial.1 else { throw CocoaError(.fileReadUnknown) }
            try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: binary.path)
            return PreparedPreview(data: data, cacheHit: true, reducedTextures: record.reducedTextures)
        }) { return hit }
        let original = try Data(contentsOf: source, options: .mappedIfSafe)
        guard original.count <= settings.maximumFileMegabytes * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        if cancelled() { throw CocoaError(.userCancelled) }
        let output = try GLBPreviewOptimizer.optimize(original, limit: settings.textureLimit, cancelled: cancelled)
        let final = try metadata(source)
        guard final.0 == initial.0, final.1 == initial.1 else { throw CocoaError(.fileReadUnknown) }
        if cancelled() { throw CocoaError(.userCancelled) }
        if settings.cacheEnabled {
            let budget = Int64(settings.cacheMegabytes) * 1024 * 1024
            try coordinated {
                if Int64(output.data.count) + 2048 <= budget || pinnedPaths().contains(source.standardizedFileURL.path) {
                    try output.data.write(to: binary, options: .atomic)
                    let entry = Entry(source: source.standardizedFileURL.path, sourceBytes: initial.0, sourceModified: initial.1, reducedTextures: output.reducedTextures, digest: Self.digest(output.data))
                    try JSONEncoder().encode(entry).write(to: manifest, options: .atomic)
                    try evict(budget: budget)
                }
            }
        }
        return PreparedPreview(data: output.data, cacheHit: false, reducedTextures: output.reducedTextures)
    }
    func statistics() throws -> CacheStatistics { try coordinated { try statisticsUnlocked() } }
    private func statisticsUnlocked() throws -> CacheStatistics {
        var result = CacheStatistics()
        for url in try manager.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.fileSizeKey]) {
            result.bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if url.pathExtension == "bin" { result.count += 1 }
        }
        return result
    }
    private func pinnedPaths() -> Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: root.appendingPathComponent("pinned.json")))) ?? []
    }
    func setPinnedPaths(_ paths: Set<String>) throws {
        try coordinated { try JSONEncoder().encode(paths).write(to: root.appendingPathComponent("pinned.json"), options: .atomic) }
    }
    private func protected(_ binary: URL, pins: Set<String>) -> Bool {
        guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: binary.deletingPathExtension().appendingPathExtension("json"))) else { return false }
        return pins.contains(entry.source)
    }
    private func evict(budget: Int64) throws {
        let files = try manager.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        // Incomplete entries can remain after a process exits between the two atomic writes.
        for file in files where file.pathExtension == "json" || file.pathExtension == "bin" {
            let partner = file.deletingPathExtension().appendingPathExtension(file.pathExtension == "json" ? "bin" : "json")
            if !manager.fileExists(atPath: partner.path) { try manager.removeItem(at: file) }
        }
        let ordered = files.filter { $0.pathExtension == "bin" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        var total = try statisticsUnlocked().bytes
        let pins = pinnedPaths()
        for file in ordered where total > budget && !protected(file, pins: pins) {
            for item in [file, file.deletingPathExtension().appendingPathExtension("json")] where manager.fileExists(atPath: item.path) {
                total -= Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                try manager.removeItem(at: item)
            }
        }
    }
    func clear(includingPinned: Bool = false) throws {
        try coordinated {
            let pins = includingPinned ? Set<String>() : pinnedPaths()
            for file in try manager.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) {
                let binary = file.deletingPathExtension().appendingPathExtension("bin")
                if !protected(binary, pins: pins) { try manager.removeItem(at: file) }
            }
        }
    }
}
