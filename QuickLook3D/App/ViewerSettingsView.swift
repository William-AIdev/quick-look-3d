import SwiftUI

struct ViewerSettingsView: View {
    @EnvironmentObject var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    private func setting<T>(_ key: WritableKeyPath<PreviewSettings, T>) -> Binding<T> {
        Binding(get: { library.settings[keyPath: key] }, set: { value in var settings = library.settings; settings[keyPath: key] = value; library.updateSettings(settings) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("查看器设置").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
            Form {
                Section {
                    Picker("预览质量", selection: setting(\.quality)) {
                        Text("节能 · 1024 纹理").tag("economy")
                        Text("均衡 · 2048 纹理").tag("balanced")
                        Text("原始").tag("original")
                    }
                    Picker("动画绘制上限", selection: setting(\.framesPerSecond)) {
                        Text("15 FPS").tag(15); Text("30 FPS").tag(30); Text("60 FPS").tag(60)
                    }
                    Toggle("播放动画", isOn: setting(\.animate))
                    Text("静止时停止绘制；降低上限可以减轻动画负载。纹理降采样仅适用于可处理的 GLB/VRM，FBX 保留原解析方式。").font(.caption).foregroundColor(.secondary)
                } header: { Text("三维查看") }
                Section {
                    Toggle("按需保存预览数据缓存", isOn: setting(\.cacheEnabled))
                    Picker("数据缓存预算", selection: setting(\.cacheMegabytes)) {
                        ForEach([1024, 4096, 8192, 16384, 32768, 65536, 131072, 262144], id: \.self) { value in Text("\(value / 1024) GiB").tag(value) }
                    }
                    Picker("缩略图和信息预算", selection: Binding(get: { library.state.thumbnailMegabytes }, set: { library.state.thumbnailMegabytes = $0; library.persist() })) {
                        ForEach([256, 512, 1024, 2048, 4096, 8192], id: \.self) { value in Text("\(value) MiB").tag(value) }
                    }
                    Text("数据：\(ByteCountFormatter.string(fromByteCount: library.cacheStatistics.bytes, countStyle: .file)) · \(library.cacheStatistics.count) 项\n浏览缓存：\(ByteCountFormatter.string(fromByteCount: library.thumbnailStatistics.bytes, countStyle: .file)) · \(library.thumbnailStatistics.count) 张图").font(.caption).foregroundColor(.secondary)
                    Text("收藏的数据和浏览缓存不自动淘汰；若收藏总量超过预算，请增大预算或取消部分收藏。FBX 数据缓存保存原文件副本，不能省略三维解析。Finder 系统缓存由 macOS 管理。").font(.caption).foregroundColor(.secondary)
                    HStack {
                        Button("清理非收藏缓存") { library.clearCaches(includingFavorites: false) }.disabled(library.busy)
                        Button("清理全部软件缓存") { library.clearCaches(includingFavorites: true) }.disabled(library.busy)
                    }
                } header: { Text("磁盘空间") }
                Section {
                    Toggle("导入时包含子文件夹", isOn: setting(\.recursive))
                    Picker("单文件读取上限", selection: setting(\.maximumFileMegabytes)) {
                        Text("64 MiB").tag(64); Text("256 MiB").tag(256); Text("1 GiB").tag(1024); Text("2 GiB").tag(2048)
                    }
                    Text("读取上限不是进程内存上限。更改质量后，当前模型会重新载入；目录和缓存设置自动保存。").font(.caption).foregroundColor(.secondary)
                } header: { Text("导入和读取") }
            }
        }.padding(24).frame(width: 570, height: 620)
        .onAppear { library.refreshStatistics() }
    }
}
