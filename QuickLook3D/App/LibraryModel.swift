import Cocoa
import SwiftUI

struct LibraryFolder: Codable, Identifiable {
    var id = UUID()
    var path: String
    var bookmark: Data
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}
struct LibraryFile: Codable, Identifiable {
    let folderID: UUID
    let path: String
    let signature: FileSignature
    var information: ModelInformation?
    var id: String { folderID.uuidString + "|" + signature.identity }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}
struct ViewerState: Codable {
    var folders = [LibraryFolder]()
    var files = [LibraryFile]()
    var favorites = Set<String>()
    var fields = Set(InformationField.allCases)
    var thumbnailMegabytes = 2048
    var sort = "name"
}

final class LibraryModel: ObservableObject {
    @Published var state = ViewerState()
    @Published var selectedID: String?
    @Published var folderID: UUID?
    @Published var favoritesOnly = false
    @Published var search = ""
    @Published var showing3D = false
    @Published var busy = false
    @Published var progress = 0
    @Published var total = 0
    @Published var status = "导入文件夹，开始浏览模型"
    @Published var error: String?
    @Published var unavailable = Set<UUID>()
    @Published var settings = PreviewSettings()
    @Published var cacheStatistics = CacheStatistics()
    @Published var thumbnailStatistics = CacheStatistics()
    @Published var measuredFPS: Double?
    @Published var renderStatus = "静止"
    @Published var targeted = false
    let store: PreviewStore?
    let artifacts: FileArtifacts?
    let thumbnails: BrowserThumbnailService?
    var confirmImport: (Int) -> Bool = { count in
        let alert = NSAlert()
        alert.messageText = "导入 \(count) 个模型文件？"
        alert.informativeText = "先建立文件列表，不读取全部模型。缩略图按需生成，也可以导入后手动批量生成。"
        alert.addButton(withTitle: "导入列表"); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    var confirmPreload: (Int) -> Bool = { count in
        let alert = NSAlert()
        alert.messageText = "处理 \(count) 个模型？"
        alert.informativeText = "会逐个生成缩略图或写入磁盘缓存；可随时取消，已完成的结果会保留。"
        alert.addButton(withTitle: "开始"); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private let queue = DispatchQueue(label: "QuickLook3D.library", qos: .utility)
    private var cancellation = CancellationFlag()
    private var grants = [UUID: (URL, Bool)]()
    private var batchThumbnail: UUID?
    private var stateURL: URL? { store?.root.appendingPathComponent("viewer-v1.json") }
    var files: [LibraryFile] { state.files }
    var selected: LibraryFile? { files.first { $0.id == selectedID } }
    var favoriteKeys: Set<String> { Set(files.filter { state.favorites.contains($0.signature.identity) }.map { $0.signature.key }) }
    var visibleFiles: [LibraryFile] {
        var seen = Set<String>()
        let filtered = files.filter {
            (folderID == nil || $0.folderID == folderID) && (!favoritesOnly || state.favorites.contains($0.signature.identity)) &&
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) && seen.insert($0.signature.identity).inserted
        }
        return filtered.sorted {
            if state.sort == "size", $0.signature.size != $1.signature.size { return $0.signature.size > $1.signature.size }
            if state.sort == "modified", $0.signature.modified != $1.signature.modified { return $0.signature.modified > $1.signature.modified }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    init(store: PreviewStore? = try? PreviewStore()) {
        self.store = store
        let artifacts = store.flatMap { try? FileArtifacts(root: $0.root) }
        self.artifacts = artifacts
        self.thumbnails = artifacts.map(BrowserThumbnailService.init)
        settings = store?.settings() ?? PreviewSettings()
        if let url = stateURL, FileManager.default.fileExists(atPath: url.path) {
            do { state = try JSONDecoder().decode(ViewerState.self, from: Data(contentsOf: url)) }
            catch { self.error = "文件列表无法读取：" + error.localizedDescription }
        }
        for index in state.folders.indices {
            let folder = state.folders[index]
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: folder.bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
                let scoped = url.startAccessingSecurityScopedResource()
                grants[folder.id] = (url, scoped)
                state.folders[index].path = url.path
                if stale { state.folders[index].bookmark = try bookmark(url) }
            } catch { unavailable.insert(folder.id) }
        }
        configureCaches(); refreshStatistics()
        if !files.isEmpty { status = "已恢复 \(files.count) 个文件，刷新可检查源目录变化" }
    }
    deinit { for grant in grants.values where grant.1 { grant.0.stopAccessingSecurityScopedResource() } }
    private func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    func persist() {
        guard let url = stateURL else { error = "存储不可用"; return }
        do { try JSONEncoder().encode(state).write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
        configureCaches()
    }
    private func configureCaches() {
        thumbnails?.settings = settings
        thumbnails?.budgetMegabytes = state.thumbnailMegabytes
        thumbnails?.protectedKeys = favoriteKeys
        do { try store?.setPinnedPaths(Set(files.filter { state.favorites.contains($0.signature.identity) }.map { $0.path })) }
        catch { self.error = error.localizedDescription }
    }
    func updateSettings(_ value: PreviewSettings) {
        settings = value
        do { try store?.save(value); configureCaches(); refreshStatistics() }
        catch { self.error = error.localizedDescription }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.begin { [weak self] response in if response == .OK, let url = panel.url { self?.importFolder(url) } }
    }
    func openFile(_ url: URL) {
        guard PreviewStore.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            error = "不支持此文件格式"; return
        }
        importFolder(url, openInViewer: true)
    }
    func importFolder(_ url: URL, refreshing: UUID? = nil, openInViewer: Bool = false) {
        guard !busy, store != nil else { return }
        busy = true; total = 0; progress = 0; status = "正在扫描文件列表…"
        cancellation = CancellationFlag(); let flag = cancellation
        let scoped = url.startAccessingSecurityScopedResource(), recursive = settings.recursive
        queue.async { [weak self] in
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true,
                      values.isDirectory == true || PreviewStore.supportedExtensions.contains(url.pathExtension.lowercased()) else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                let urls = values.isDirectory == true
                    ? try FolderScanner.scan(url, recursive: recursive, cancelled: { flag.cancelled }) : [url]
                let signatures = try urls.map { ($0, try FileSignature.read($0)) }
                DispatchQueue.main.async {
                    guard let self = self else { if scoped { url.stopAccessingSecurityScopedResource() }; return }
                    self.total = urls.count
                    guard !flag.cancelled, refreshing != nil || urls.count <= 100 || self.confirmImport(urls.count), !flag.cancelled else {
                        if scoped { url.stopAccessingSecurityScopedResource() }
                        self.busy = false; self.status = "已取消导入"; return
                    }
                    do {
                        let existing = refreshing ?? self.state.folders.first(where: { $0.path == url.path })?.id
                        let id = existing ?? UUID()
                        let folder = LibraryFolder(id: id, path: url.path, bookmark: try self.bookmark(url))
                        if let index = self.state.folders.firstIndex(where: { $0.id == id }) { self.state.folders[index] = folder }
                        else { self.state.folders.append(folder) }
                        if let old = self.grants[id], old.1 { old.0.stopAccessingSecurityScopedResource() }
                        self.grants[id] = (url, scoped)
                        self.unavailable.remove(id)
                        let oldInfo = Dictionary(self.files.filter { $0.folderID == id }.map { ($0.signature.key, $0.information) }, uniquingKeysWith: { a, _ in a })
                        self.state.files.removeAll { $0.folderID == id }
                        self.state.files += signatures.map { file, signature in
                            LibraryFile(folderID: id, path: file.path, signature: signature,
                                information: oldInfo[signature.key] ?? self.artifacts?.information(signature))
                        }
                        self.showing3D = false; self.folderID = id; self.favoritesOnly = false
                        self.selectedID = self.visibleFiles.first?.id
                        self.progress = urls.count; self.busy = false
                        self.status = "已导入 \(urls.count) 个文件 · 未批量解析模型"
                        self.persist(); self.refreshStatistics()
                        if openInViewer, let file = self.selected { self.open3D(file) }
                    } catch {
                        if scoped { url.stopAccessingSecurityScopedResource() }
                        self.busy = false; self.error = error.localizedDescription
                    }
                }
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                DispatchQueue.main.async { self?.busy = false; self?.error = error.localizedDescription }
            }
        }
    }
    func refreshFolder() {
        guard let id = folderID ?? selected?.folderID ?? state.folders.first?.id,
              let url = grants[id]?.0 else { error = "目录权限已失效，请重新导入原文件夹以授权。"; return }
        importFolder(url, refreshing: id)
    }
    func removeFolder(_ id: UUID) {
        guard !busy else { return }
        showing3D = false; selectedID = nil
        state.files.removeAll { $0.folderID == id }; state.folders.removeAll { $0.id == id }
        if let grant = grants.removeValue(forKey: id), grant.1 { grant.0.stopAccessingSecurityScopedResource() }
        if folderID == id { folderID = nil }
        persist()
    }
    func select(_ file: LibraryFile) { if selectedID != file.id { showing3D = false; measuredFPS = nil }; selectedID = file.id }
    func open3D(_ file: LibraryFile) {
        guard !unavailable.contains(file.folderID), (try? FileSignature.read(file.url)) == file.signature else {
            error = "源文件已变化、离线或权限失效，请刷新目录或重新导入。"; return
        }
        select(file); showing3D = true; renderStatus = "加载中…"
    }
    func favorite(_ file: LibraryFile) {
        let identity = file.signature.identity
        if state.favorites.contains(identity) { state.favorites.remove(identity); persist(); return }
        state.favorites.insert(identity); persist()
        let settings = settings, store = store
        queue.async { [weak self] in
            do {
                var value = settings; value.cacheEnabled = true
                _ = try store?.prepare(file.url, settings: value)
                DispatchQueue.main.async {
                    if self?.state.favorites.contains(file.signature.identity) == true { self?.status = "已收藏并缓存：" + file.name }
                    self?.refreshStatistics()
                }
            } catch { DispatchQueue.main.async { self?.error = "已收藏，但磁盘缓存失败：" + error.localizedDescription } }
        }
    }
    func receiveInformation(_ information: ModelInformation, file: LibraryFile) {
        guard (try? FileSignature.read(file.url)) == file.signature else { return }
        for index in state.files.indices where state.files[index].signature == file.signature { state.files[index].information = information }
        do { try artifacts?.save(information, signature: file.signature); persist() }
        catch { self.error = error.localizedDescription }
    }
    func cancel() {
        cancellation.cancel()
        if let id = batchThumbnail { thumbnails?.cancel(id) }
        status = "正在取消…"
    }
    func preload(thumbnail: Bool) {
        guard !busy else { return }
        let files = visibleFiles
        guard !files.isEmpty, files.count <= 100 || confirmPreload(files.count) else { return }
        showing3D = false; busy = true; progress = 0; total = files.count
        cancellation = CancellationFlag(); let flag = cancellation
        status = thumbnail ? "正在逐个生成缩略图…" : "正在写入预览数据缓存（FBX 仍需解析）…"
        if thumbnail { nextThumbnail(files, index: 0, failed: 0, flag: flag) }
        else {
            let settings = settings, store = store
            queue.async { [weak self] in
                var failures = 0
                for (index, file) in files.enumerated() {
                    if flag.cancelled { break }
                    autoreleasepool {
                        do { var value = settings; value.cacheEnabled = true; _ = try store?.prepare(file.url, settings: value, cancelled: { flag.cancelled }) }
                        catch { failures += 1 }
                    }
                    DispatchQueue.main.async { self?.progress = index + 1 }
                }
                let count = failures
                DispatchQueue.main.async { self?.endBatch(failed: count, cancelled: flag.cancelled) }
            }
        }
    }
    private func nextThumbnail(_ files: [LibraryFile], index: Int, failed: Int, flag: CancellationFlag) {
        guard !flag.cancelled, index < files.count, let thumbnails = thumbnails else { endBatch(failed: failed, cancelled: flag.cancelled); return }
        batchThumbnail = thumbnails.load(files[index]) { [weak self] _, information, error in
            guard let self = self else { return }
            self.batchThumbnail = nil
            if let information = information { self.receiveInformation(information, file: files[index]) }
            self.progress = index + 1
            self.nextThumbnail(files, index: index + 1, failed: failed + (error == nil ? 0 : 1), flag: flag)
        }
    }
    private func endBatch(failed: Int, cancelled: Bool) {
        busy = false; batchThumbnail = nil
        status = "\(cancelled ? "已取消" : "处理完成") · \(progress)/\(total) · \(failed) 个失败"
        refreshStatistics()
    }
    func refreshStatistics() {
        let store = store, artifacts = artifacts
        queue.async { [weak self] in
            let previews = (try? store?.statistics()) ?? CacheStatistics()
            let thumbs = artifacts?.statistics() ?? CacheStatistics()
            DispatchQueue.main.async { self?.cacheStatistics = previews; self?.thumbnailStatistics = thumbs }
        }
    }
    func clearCaches(includingFavorites: Bool) {
        guard !busy else { return }
        busy = true
        let store = store, artifacts = artifacts, protected = includingFavorites ? Set<String>() : favoriteKeys
        thumbnails?.clearMemory()
        queue.async { [weak self] in
            do {
                try store?.clear(includingPinned: includingFavorites); try artifacts?.clear(protectedKeys: protected)
                DispatchQueue.main.async { self?.busy = false; self?.status = "缓存已清理；系统 Finder 缩略图由 macOS 管理"; self?.refreshStatistics() }
            } catch { DispatchQueue.main.async { self?.busy = false; self?.error = error.localizedDescription } }
        }
    }
}
