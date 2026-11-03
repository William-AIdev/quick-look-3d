import Foundation

enum FolderScanner {
    static func scan(_ root: URL, recursive: Bool, cancelled: () -> Bool) throws -> [URL] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        var result = [URL]()
        var scanError: Error?
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in scanError = error; return false }) else { throw CocoaError(.fileReadUnknown) }
        for case let file as URL in enumerator {
            if cancelled() { break }
            let values = try file.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true { if !recursive { enumerator.skipDescendants() }; continue }
            if values.isRegularFile == true, PreviewStore.supportedExtensions.contains(file.pathExtension.lowercased()) { result.append(file) }
        }
        if let error = scanError { throw error }
        return result.sorted { $0.path < $1.path }
    }
}
