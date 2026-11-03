import Cocoa
import SwiftUI

struct PreloadItem: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let failed: Bool
}

final class PreloadModel: ObservableObject {
    @Published var settings = PreviewSettings()
    @Published var statistics = CacheStatistics()
    @Published var busy = false
    @Published var completed = 0
    @Published var total = 0
    @Published var status = "将模型文件夹拖到这里"
    @Published var items = [PreloadItem]()
    @Published var error: String?
    @Published var targeted = false
    var confirmLargeImport: (Int) -> Bool = { count in
        let alert = NSAlert()
        alert.messageText = "预加载 \(count) 个模型？"
        alert.informativeText = "将逐个处理并保存磁盘缓存，可能耗时较长。你可以随时取消。"
        alert.addButton(withTitle: "预加载"); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    let store: PreviewStore?
    private var cancellation = CancellationFlag()
    private let queue = DispatchQueue(label: "QuickLook3D.preload", qos: .utility)
    init(store: PreviewStore? = try? PreviewStore()) {
        self.store = store
        if let store = store { settings = store.settings(); refresh() }
        else { error = "共享存储不可用。请检查安装包的共享目录权限。" }
    }
    func update(_ value: PreviewSettings) {
        settings = value
        do { try store?.save(value); refresh() }
        catch { self.error = error.localizedDescription }
    }
    func refresh() {
        let store = store
        queue.async { [weak self] in
            let stats = (try? store?.statistics()) ?? CacheStatistics()
            DispatchQueue.main.async { self?.statistics = stats }
        }
    }
    func clear() {
        guard !busy else { return }
        busy = true
        queue.async { [weak self] in
            do { try self?.store?.clear(); DispatchQueue.main.async { self?.busy = false; self?.status = "缓存已清空"; self?.refresh() } }
            catch { DispatchQueue.main.async { self?.busy = false; self?.error = error.localizedDescription } }
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in if response == .OK, let url = panel.url { self?.importFolder(url) } }
    }
    func cancel() { cancellation.cancel(); status = "正在取消，当前文件处理结束后停止…" }
    func importFolder(_ url: URL) {
        guard !busy, store != nil else { return }
        guard settings.cacheEnabled else { error = "请先在设置中启用磁盘缓存。"; return }
        busy = true; completed = 0; total = 0; items = []; status = "正在扫描文件夹…"
        cancellation = CancellationFlag()
        let flag = cancellation
        let settings = settings
        let scoped = url.startAccessingSecurityScopedResource()
        queue.async { [weak self] in
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
                let files = try FolderScanner.scan(url, recursive: settings.recursive, cancelled: { flag.cancelled })
                DispatchQueue.main.async {
                    guard let self = self else { if scoped { url.stopAccessingSecurityScopedResource() }; return }
                    self.total = files.count
                    var proceed = !flag.cancelled
                    if files.count > 100 && proceed {
                        proceed = self.confirmLargeImport(files.count)
                    }
                    if proceed { self.process(files, folder: url, scoped: scoped, settings: settings, flag: flag) }
                    else { if scoped { url.stopAccessingSecurityScopedResource() }; self.busy = false; self.status = "已取消预加载" }
                }
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                DispatchQueue.main.async { self?.busy = false; self?.error = error.localizedDescription }
            }
        }
    }
    private func process(_ files: [URL], folder: URL, scoped: Bool, settings: PreviewSettings, flag: CancellationFlag) {
        let store = store
        status = files.isEmpty ? "未找到支持的模型文件" : "正在预加载…"
        queue.async { [weak self] in
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            var successes = 0
            var failures = 0
            for (index, file) in files.enumerated() {
                if flag.cancelled { break }
                let item: PreloadItem = autoreleasepool {
                    do {
                        let result = try store!.prepare(file, settings: settings, cancelled: { flag.cancelled })
                        successes += 1
                        let detail = result.cacheHit ? "复用已有缓存" : result.reducedTextures > 0 ? "已缩小 \(result.reducedTextures) 张纹理" : "已缓存 · 保留原始精度"
                        return PreloadItem(name: file.lastPathComponent, detail: detail, failed: false)
                    } catch {
                        failures += 1
                        return PreloadItem(name: file.lastPathComponent, detail: flag.cancelled ? "已取消" : error.localizedDescription, failed: true)
                    }
                }
                DispatchQueue.main.async {
                    self?.completed = index + 1
                    self?.items.insert(item, at: 0)
                    if self?.items.count ?? 0 > 100 { self?.items.removeLast() }
                }
            }
            let summary = "\(flag.cancelled ? "已停止" : "预加载完成")：\(successes) 成功，\(failures) 失败"
            DispatchQueue.main.async { self?.busy = false; self?.status = files.isEmpty ? "未找到支持的模型文件" : summary; self?.refresh() }
        }
    }
}

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
