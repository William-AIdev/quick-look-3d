import Cocoa
import CryptoKit
import Darwin

struct FileSignature: Codable, Equatable {
    let identity: String
    let size: Int64
    let modified: Date
    static func read(_ url: URL) throws -> FileSignature {
        var value = stat()
        guard lstat(url.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG else { throw CocoaError(.fileReadNoSuchFile) }
        return FileSignature(identity: "\(value.st_dev):\(value.st_ino)", size: value.st_size,
            modified: Date(timeIntervalSince1970: Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1_000_000_000))
    }
    var key: String {
        let value = "browser-v1|\(identity)|\(size)|\(modified.timeIntervalSince1970)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

final class FileArtifacts {
    let directory: URL
    private let manager = FileManager.default
    init(root: URL) throws {
        directory = root.appendingPathComponent("Browser-v1", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    private func file(_ key: String, _ ext: String) -> URL { directory.appendingPathComponent(key).appendingPathExtension(ext) }
    private func touch(_ url: URL) { try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
    func information(_ signature: FileSignature) -> ModelInformation? {
        let url = file(signature.key, "json")
        guard let data = try? Data(contentsOf: url), let info = try? JSONDecoder().decode(ModelInformation.self, from: data) else { return nil }
        touch(url); return info
    }
    func save(_ info: ModelInformation, signature: FileSignature) throws {
        try JSONEncoder().encode(info).write(to: file(signature.key, "json"), options: .atomic)
    }
    func thumbnail(_ signature: FileSignature) -> NSImage? {
        let url = file(signature.key, "png")
        guard let image = NSImage(contentsOf: url) else { return nil }
        touch(url); return image
    }
    func save(_ image: NSImage, signature: FileSignature) throws {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: file(signature.key, "png"), options: .atomic)
    }
    func statistics() -> CacheStatistics {
        let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return CacheStatistics(count: files.filter { $0.pathExtension == "png" }.count,
            bytes: files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) })
    }
    func trim(megabytes: Int, protectedKeys: Set<String>) throws {
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        let ordered = files.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        var bytes = statistics().bytes
        for url in ordered where bytes > Int64(megabytes) * 1024 * 1024 && !protectedKeys.contains(url.deletingPathExtension().lastPathComponent) {
            bytes -= Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try manager.removeItem(at: url)
        }
    }
    func clear(protectedKeys: Set<String> = []) throws {
        for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where !protectedKeys.contains(url.deletingPathExtension().lastPathComponent) { try manager.removeItem(at: url) }
    }
}
