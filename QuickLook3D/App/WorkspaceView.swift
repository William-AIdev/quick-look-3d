import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model: PreloadModel
    init(model: PreloadModel = PreloadModel()) { _model = StateObject(wrappedValue: model) }
    private var settings: Binding<PreviewSettings> { Binding(get: { model.settings }, set: { model.update($0) }) }
    private var cacheSize: String { ByteCountFormatter.string(fromByteCount: model.statistics.bytes, countStyle: .file) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "cube.transparent.fill").font(.system(size: 32)).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("模型预览工作台").font(.system(size: 23, weight: .semibold))
                    Text("为 Finder 空格预览准备轻量模型").foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(cacheSize).font(.system(.title3, design: .rounded).weight(.medium))
                    Text("\(model.statistics.count) 个磁盘缓存").font(.caption).foregroundColor(.secondary)
                }
            }.padding(24)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                workspace.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                preferences.padding(24).frame(width: 290).disabled(model.busy)
            }
            Divider()
            HStack {
                Image(systemName: model.busy ? "clock" : "checkmark.circle").foregroundColor(.secondary)
                Text(model.status).font(.callout).lineLimit(2)
                Spacer()
                if model.busy { Button("取消", action: model.cancel) }
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(minWidth: 880, idealWidth: 980, minHeight: 620, idealHeight: 690)
        .background(Color(NSColor.windowBackgroundColor))
        .alert("无法完成操作", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var workspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 12) {
                Image(systemName: "folder.badge.plus").font(.system(size: 42, weight: .light)).foregroundColor(.accentColor)
                Text("拖入一个模型文件夹").font(.title3.weight(.medium))
                Text("GLB、VRM、VRMA、FBX\n逐个处理，完成后释放内存；超过 100 个文件时先确认。")
                    .font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center)
                Button("选择文件夹…", action: model.chooseFolder).disabled(model.busy || model.store == nil)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 28)
            .background(model.targeted ? Color.accentColor.opacity(0.10) : Color(NSColor.controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(model.targeted ? Color.accentColor : Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .cornerRadius(12)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.targeted, perform: drop)
            if model.busy {
                ProgressView(value: Double(model.completed), total: Double(max(1, model.total)))
                Text(model.total == 0 ? "扫描支持的模型文件…" : "已处理 \(model.completed) / \(model.total)")
                    .font(.caption).foregroundColor(.secondary)
            }
            if model.items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("准备一次，重复使用").font(.headline)
                    Text("GLB / VRM 的大型内嵌纹理会按预览质量缩小；原文件保持不变。其他格式保存原始数据缓存。")
                    Text("缓存按最近使用时间淘汰。更改源文件或质量后，下次预览会重新生成。")
                }.font(.callout).foregroundColor(.secondary).padding(.top, 8)
                Spacer(minLength: 0)
            } else {
                Text("最近处理").font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.items) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: item.failed ? "exclamationmark.circle" : "checkmark.circle.fill")
                                    .foregroundColor(item.failed ? .orange : .accentColor)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).lineLimit(1).truncationMode(.middle)
                                    Text(item.detail).font(.caption).foregroundColor(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }.padding(.vertical, 9)
                            Divider()
                        }
                    }
                }
            }
        }
    }
    private var preferences: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("预览设置").font(.headline)
            Picker("画质", selection: settings.quality) {
                Text("节能 · 1024 纹理").tag("economy")
                Text("均衡 · 2048 纹理").tag("balanced")
                Text("原始精度").tag("original")
            }
            Picker("动画帧率", selection: settings.framesPerSecond) {
                Text("15 FPS").tag(15); Text("30 FPS").tag(30); Text("60 FPS").tag(60)
            }
            Toggle("播放动画", isOn: settings.animate)
            Text("静态模型空闲时停帧。设置自动保存，并在下一次预览时生效。")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 4)
            Text("预加载与缓存").font(.headline)
            Toggle("启用磁盘缓存", isOn: settings.cacheEnabled)
            Toggle("包含子文件夹", isOn: settings.recursive)
            Picker("缓存容量", selection: settings.cacheMegabytes) {
                Text("256 MB").tag(256); Text("1 GB").tag(1024); Text("4 GB").tag(4096)
            }
            Picker("单文件上限", selection: settings.maximumFileMegabytes) {
                Text("64 MB").tag(64); Text("256 MB").tag(256); Text("1 GB").tag(1024)
            }
            Text("逐个预处理，避免整个文件夹常驻内存。符号链接、隐藏文件和应用包会跳过。")
                .font(.caption).foregroundColor(.secondary)
            Button("清空磁盘缓存", action: model.clear).disabled(model.busy || model.statistics.bytes == 0)
            Spacer(minLength: 0)
            Text("在 Finder 选择模型，按空格预览。App 可在预加载完成后关闭。")
                .font(.caption).foregroundColor(.secondary)
        }
    }
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.busy, providers.count == 1, let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSURL.self) { item, error in
            let url = item as? URL
            DispatchQueue.main.async {
                if let url = url { model.importFolder(url) }
                else { model.error = error?.localizedDescription ?? "无法读取文件夹，请使用“选择文件夹”。" }
            }
        }
        return true
    }
}
