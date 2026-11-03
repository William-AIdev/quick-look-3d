import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var settingsVisible = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "cube.transparent.fill").font(.title2).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("模型文件").font(.headline)
                    Text("Quick Look 3D").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if !library.state.folders.isEmpty {
                    TextField("搜索文件名", text: $library.search).textFieldStyle(.roundedBorder).frame(width: 200)
                    Button { library.refreshFolder() } label: { Image(systemName: "arrow.clockwise") }.help("刷新当前目录").disabled(library.busy)
                }
                Button { library.chooseFolder() } label: { Label("导入文件夹", systemImage: "folder.badge.plus") }.disabled(library.busy)
                Button { settingsVisible = true } label: { Image(systemName: "slider.horizontal.3") }
                    .help("查看器设置").disabled(library.files.isEmpty || library.busy)
            }.padding(18)
            Divider()
            if library.state.folders.isEmpty { welcome }
            else {
                HStack(spacing: 0) {
                    sidebar.frame(width: 184)
                    Divider()
                    browser.frame(minWidth: 410, maxWidth: .infinity)
                    Divider()
                    inspector.frame(width: 274)
                }
            }
            Divider()
            HStack(spacing: 12) {
                if library.busy {
                    ProgressView(value: Double(library.progress), total: Double(max(1, library.total))).frame(width: 130)
                    Text("\(library.progress)/\(library.total)").monospacedDigit()
                    Button("取消") { library.cancel() }
                }
                Text(library.status).lineLimit(1)
                Spacer()
                if !library.files.isEmpty { Text("\(library.visibleFiles.count) 个文件").monospacedDigit() }
            }.font(.caption).foregroundColor(.secondary).padding(.horizontal, 18).frame(height: 40)
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(Color(NSColor.windowBackgroundColor))
        .onDrop(of: [UTType.fileURL], isTargeted: $library.targeted) { providers in
            guard !library.busy, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSURL.self) { url, _ in
                if let url = url as? URL { DispatchQueue.main.async { library.importFolder(url) } }
            }
            return true
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: library.targeted ? 3 : 0).allowsHitTesting(false))
        .sheet(isPresented: $settingsVisible) { ViewerSettingsView().environmentObject(library) }
        .alert("无法完成操作", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("好") { library.error = nil }
        } message: { Text(library.error ?? "") }
    }
    private var welcome: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 54, weight: .ultraLight)).foregroundColor(.accentColor)
            Text("让模型文件，有处可看").font(.system(size: 28, weight: .semibold))
            Text("拖入文件夹，建立可以搜索、收藏的模型列表。\n浏览静态缩略图，需要时再打开三维。").multilineTextAlignment(.center).foregroundColor(.secondary).lineSpacing(6)
            Button("选择文件夹…") { library.chooseFolder() }.controlSize(.large).keyboardShortcut("o", modifiers: .command).disabled(library.busy)
            Text("FBX  ·  GLB  ·  VRM  ·  VRMA").font(.caption).foregroundColor(.secondary).padding(.top, 10)
            Text("Finder 文件缩略图独立工作，无需先导入。").font(.caption).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("资料库").font(.caption).foregroundColor(.secondary).padding(.bottom, 5)
            navigation("所有文件", icon: "square.grid.2x2", selected: library.folderID == nil && !library.favoritesOnly) {
                library.folderID = nil; library.favoritesOnly = false
            }
            navigation("收藏", icon: "star", selected: library.favoritesOnly) { library.folderID = nil; library.favoritesOnly = true }
            Text("导入的文件夹").font(.caption).foregroundColor(.secondary).padding(.top, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(library.state.folders) { folder in
                        navigation(folder.name, icon: library.unavailable.contains(folder.id) ? "exclamationmark.folder" : "folder", selected: library.folderID == folder.id && !library.favoritesOnly) {
                            library.folderID = folder.id; library.favoritesOnly = false
                        }
                        .help(folder.path)
                        .contextMenu { Button("移出列表（保留原文件）") { library.removeFolder(folder.id) }.disabled(library.busy) }
                    }
                }
            }
            Spacer()
            Label("原文件保留原位", systemImage: "externaldrive").font(.caption2).foregroundColor(.secondary)
        }.padding(14).background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
    private func navigation(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(selected ? Color.accentColor.opacity(0.12) : Color.clear).cornerRadius(6)
        }.buttonStyle(.plain)
    }
    private var browser: some View {
        VStack(spacing: 0) {
            HStack {
                Text(library.favoritesOnly ? "收藏" : library.state.folders.first(where: { $0.id == library.folderID })?.name ?? "所有文件").font(.headline).lineLimit(1)
                Spacer()
                Picker("排序", selection: $library.state.sort) {
                    Text("名称").tag("name"); Text("大小").tag("size"); Text("最近修改").tag("modified")
                }.labelsHidden().frame(width: 100).onChange(of: library.state.sort) { _ in library.persist() }
                Menu {
                    Button("为当前列表生成缩略图") { library.preload(thumbnail: true) }
                    Button("预加载当前列表的数据缓存") { library.preload(thumbnail: false) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 28).disabled(library.busy || library.visibleFiles.isEmpty)
            }.padding(16)
            if library.showing3D, let file = library.selected {
                ModelViewer(file: file).frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Button("返回缩略图列表") { library.showing3D = false; library.measuredFPS = nil }
                    Spacer()
                    Toggle("播放动画", isOn: Binding(get: { library.settings.animate }, set: { var value = library.settings; value.animate = $0; library.updateSettings(value) })).toggleStyle(.checkbox)
                }.padding(14)
            } else if library.visibleFiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.largeTitle)
                    Text("没有符合条件的文件")
                }.foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 14)], spacing: 14) {
                        ForEach(library.visibleFiles) { file in
                            VStack(alignment: .leading, spacing: 7) {
                                LibraryThumbnail(file: file).frame(height: 130).frame(maxWidth: .infinity)
                                    .background(Color(NSColor.textBackgroundColor)).cornerRadius(7)
                                HStack(alignment: .top, spacing: 4) {
                                    Text(file.name).font(.system(size: 12, weight: .medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Button { library.favorite(file) } label: {
                                        Image(systemName: library.state.favorites.contains(file.signature.identity) ? "star.fill" : "star").foregroundColor(library.state.favorites.contains(file.signature.identity) ? .orange : .secondary)
                                    }.buttonStyle(.plain).help("收藏并保护磁盘缓存")
                                }
                                Text("\(file.url.pathExtension.uppercased())  ·  \(ByteCountFormatter.string(fromByteCount: file.signature.size, countStyle: .file))").font(.caption2).foregroundColor(.secondary)
                            }.padding(9)
                                .background(library.selectedID == file.id ? Color.accentColor.opacity(0.08) : Color(NSColor.controlBackgroundColor))
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(library.selectedID == file.id ? Color.accentColor : Color.primary.opacity(0.07), lineWidth: library.selectedID == file.id ? 2 : 1))
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { library.open3D(file) }
                                .onTapGesture { library.select(file) }
                                .contextMenu {
                                    Button("打开三维") { library.open3D(file) }
                                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                                    Button(library.state.favorites.contains(file.signature.identity) ? "取消收藏" : "收藏并缓存") { library.favorite(file) }
                                }
                        }
                    }.padding(16).padding(.top, -8)
                }
            }
        }
    }
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("查看").font(.headline)
                Spacer()
                Menu {
                    ForEach(InformationField.allCases) { field in
                        Toggle(field.title, isOn: Binding(get: { library.state.fields.contains(field) }, set: { value in
                            if value { library.state.fields.insert(field) } else { library.state.fields.remove(field) }; library.persist()
                        }))
                    }
                } label: { Label("信息", systemImage: "list.bullet") }.menuStyle(.borderlessButton).frame(width: 65)
            }.padding(16)
            if let file = library.selected {
                if library.showing3D {
                    LibraryThumbnail(file: file).frame(height: 150).frame(maxWidth: .infinity).background(Color(NSColor.textBackgroundColor))
                    HStack {
                        Button("返回静态图") { library.showing3D = false; library.measuredFPS = nil }
                        Spacer()
                        Toggle("动画", isOn: Binding(get: { library.settings.animate }, set: { var settings = library.settings; settings.animate = $0; library.updateSettings(settings) })).toggleStyle(.checkbox)
                    }.font(.caption).padding(12)
                } else {
                    LibraryThumbnail(file: file).frame(height: 200).frame(maxWidth: .infinity).background(Color(NSColor.textBackgroundColor))
                    Button { library.open3D(file) } label: { Label("打开三维", systemImage: "cube") }.frame(maxWidth: .infinity).padding(12)
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(file.name).font(.headline).textSelection(.enabled)
                        Text(file.path).font(.caption2).foregroundColor(.secondary).textSelection(.enabled)
                        information(file)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
            } else {
                Text("选择文件查看缩略图和信息").font(.callout).foregroundColor(.secondary).padding(16)
                Spacer()
            }
        }
    }
    @ViewBuilder private func information(_ file: LibraryFile) -> some View {
        if library.state.fields.contains(.fps) {
            infoRow("实时 FPS", library.showing3D ? library.measuredFPS.map { String(format: "%.1f", $0) } ?? library.renderStatus : "未打开三维")
        }
        if let info = file.information {
            if library.state.fields.contains(.vertices) { infoRow("顶点", info.vertices.formatted()) }
            if library.state.fields.contains(.triangles) { infoRow("三角形", info.triangles.formatted()) }
            if library.state.fields.contains(.materials) { infoRow("材质", info.materials.formatted()) }
            if library.state.fields.contains(.textures) {
                Text("纹理 · \(info.textures.count)").font(.caption).foregroundColor(.secondary)
                if info.textures.isEmpty { Text("无纹理").font(.caption) }
                ForEach(Array(info.textures.enumerated()), id: \.offset) { _, texture in
                    infoRow(texture.name, texture.width.flatMap { w in texture.height.map { "\(w) × \($0)" } } ?? "未知")
                }
            }
            if library.state.fields.contains(.animations) {
                Text("动画 · \(info.animations.count)").font(.caption).foregroundColor(.secondary)
                if info.animations.isEmpty { Text("无动画").font(.caption) }
                ForEach(Array(info.animations.enumerated()), id: \.offset) { _, clip in infoRow(clip.name, String(format: "%.2f 秒", clip.duration)) }
            }
            Text("顶点和三角形按网格实例累加。信息来自上次成功解析，纹理尺寸对应当次预览质量。").font(.caption2).foregroundColor(.secondary)
        } else {
            Text("模型信息尚未读取。打开三维，或生成缩略图后读取；未知值不会记作 0。").font(.caption).foregroundColor(.secondary)
        }
    }
    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(title).foregroundColor(.secondary).lineLimit(2); Spacer(); Text(value).monospacedDigit().textSelection(.enabled) }.font(.caption)
    }
}

struct LibraryThumbnail: View {
    @EnvironmentObject var library: LibraryModel
    let file: LibraryFile
    @State private var image: NSImage?
    @State private var requestID: UUID?
    @State private var failed = false
    var body: some View {
        Group {
            if let image = image { Image(nsImage: image).resizable().scaledToFit() }
            else {
                VStack(spacing: 8) {
                    Image(systemName: failed ? "cube" : "cube.transparent").font(.system(size: 30, weight: .light))
                    Text(failed ? "缩略图暂不可用" : "正在获取缩略图").font(.caption2)
                }.foregroundColor(.secondary)
            }
        }
        .onAppear { load() }
        .onChange(of: file.signature.key) { _ in load() }
        .onDisappear { if let id = requestID { library.thumbnails?.cancel(id) }; requestID = nil }
    }
    private func load() {
        if let id = requestID { library.thumbnails?.cancel(id) }
        image = nil; failed = false
        requestID = library.thumbnails?.load(file) { image, information, error in
            self.image = image; failed = image == nil && error != nil
            if let information = information { library.receiveInformation(information, file: file) }
        }
    }
}

struct ModelViewer: NSViewControllerRepresentable {
    @EnvironmentObject var library: LibraryModel
    let file: LibraryFile
    final class Coordinator {
        var key = ""
        var settings: PreviewSettings?
        var timer: Timer?
        deinit { timer?.invalidate() }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSViewController(context: Context) -> PreviewViewController {
        let controller = PreviewViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 274, height: 240)
        return controller
    }
    func updateNSViewController(_ controller: PreviewViewController, context: Context) {
        let coordinator = context.coordinator
        let key = file.signature.key + "|" + library.settings.quality
        if coordinator.key != key {
            coordinator.timer?.invalidate(); coordinator.timer = nil
            coordinator.key = key; coordinator.settings = library.settings
            controller.settingsOverride = library.settings
            controller.onModelInformation = { [weak library] information in library?.receiveInformation(information, file: file) }
            controller.preparePreviewOfFile(at: file.url) { [weak library] error in
                guard library?.selectedID == file.id, library?.showing3D == true, coordinator.key == key else { return }
                if (error as NSError?)?.code == NSUserCancelledError { return }
                library?.renderStatus = error == nil ? "静止" : "加载失败"
                if let error = error { library?.error = error.localizedDescription }
            }
        } else if coordinator.settings != library.settings {
            coordinator.settings = library.settings; controller.updatePlayback(library.settings)
        }
        if library.state.fields.contains(.fps), coordinator.timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak controller, weak library] _ in
                guard let controller = controller, controller.view.window?.isVisible == true else { return }
                controller.diagnostics { value in
                    guard library?.selectedID == file.id else { return }
                    library?.measuredFPS = value?["fps"] as? Double
                    library?.renderStatus = value?["idle"] as? Bool == true ? "静止" : "测量中…"
                }
            }
            coordinator.timer = timer; RunLoop.main.add(timer, forMode: .common)
        } else if !library.state.fields.contains(.fps) { coordinator.timer?.invalidate(); coordinator.timer = nil }
    }
    static func dismantleNSViewController(_ controller: PreviewViewController, coordinator: Coordinator) {
        coordinator.timer?.invalidate(); coordinator.timer = nil
        controller.onModelInformation = nil; controller.stopViewing()
    }
}
