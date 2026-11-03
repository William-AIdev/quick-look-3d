import Cocoa
import SwiftUI

func spin(_ seconds: Double, until: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        let done = autoreleasepool { () -> Bool in
            if until() { return true }
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            return false
        }
        if done { break }
    }
}
func check(_ condition: Bool, _ text: String) {
    print("\(condition ? "PASS" : "FAIL"): \(text)")
    fflush(stdout)
    if !condition { exit(1) }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let testRoot = root.appendingPathComponent("build/viewer-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
let source = testRoot.appendingPathComponent("Models")
try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
let original = try Data(contentsOf: root.appendingPathComponent("renderer/tests/fixtures/plain.glb"))
for index in 0..<101 { try original.write(to: source.appendingPathComponent(String(format: "%03d.glb", index))) }
let store = try PreviewStore(root: testRoot.appendingPathComponent("Store"))
let model = LibraryModel(store: store)
var confirms = 0
model.confirmImport = { count in confirms += 1; check(count == 101, "confirmation counts supported files"); return false }
model.importFolder(source)
spin(15, until: { !model.busy })
check(confirms == 1 && model.files.isEmpty && (try! store.statistics()).count == 0, ">100 decline leaves library and model cache untouched")
let hundredSource = testRoot.appendingPathComponent("Hundred")
try FileManager.default.createDirectory(at: hundredSource, withIntermediateDirectories: true)
for index in 0..<100 { try original.write(to: hundredSource.appendingPathComponent("model-\(index).glb")) }
let hundred = LibraryModel(store: try PreviewStore(root: testRoot.appendingPathComponent("HundredStore")))
hundred.confirmImport = { _ in check(false, "100 files must not ask for confirmation"); return false }
hundred.importFolder(hundredSource); spin(15, until: { !hundred.busy })
check(hundred.files.count == 100, "100-file import needs no confirmation")
model.confirmImport = { _ in model.cancel(); return true }
model.importFolder(source); spin(15, until: { !model.busy })
check(model.files.isEmpty, "cancellation during confirmation does not commit files")
model.confirmImport = { _ in true }
model.importFolder(source)
spin(15, until: { !model.busy })
check(model.files.count == 101 && model.error == nil, "confirmed import builds persistent file list")
check((try! store.statistics()).bytes == 0, "import indexes files without reading model payloads")
let file = model.files.first!
model.favorite(file)
spin(15, until: { ((try? store.statistics().count) ?? 0) == 1 })
check(model.state.favorites.contains(file.signature.identity), "favorite persists by filesystem identity")
try store.clear()
check((try! store.statistics()).count == 1, "normal cleanup protects favorite data")
model.state.fields = [.fps, .triangles]
model.state.thumbnailMegabytes = 4096
model.settings.cacheMegabytes = 8192
model.updateSettings(model.settings); model.persist()
let restored = LibraryModel(store: try PreviewStore(root: store.root.deletingLastPathComponent()))
check(restored.files.count == 101 && restored.state.favorites == model.state.favorites && restored.state.fields == [.fps, .triangles] && restored.state.thumbnailMegabytes == 4096 && restored.settings.cacheMegabytes == 8192, "restart restores folders, files, favorites, fields and budgets")
check(restored.unavailable.isEmpty, "security-scoped source bookmark resolves after restart")
let renamed = file.url.deletingLastPathComponent().appendingPathComponent("renamed.glb")
try FileManager.default.moveItem(at: file.url, to: renamed)
restored.refreshFolder(); spin(15, until: { !restored.busy })
check(restored.files.contains { $0.path == renamed.path && restored.state.favorites.contains($0.signature.identity) }, "refresh follows favorite rename on same filesystem")
check(restored.files.count == 101, "refresh replaces snapshot without duplicates")
let artifacts = try FileArtifacts(root: store.root)
var finished = false
var rendered: NSImage?
var metadata: ModelInformation?
let start = Date()
ThumbnailRenderer.shared.render(renamed, size: CGSize(width: 256, height: 256), settings: PreviewSettings()) { result in
    switch result {
    case .success(let result): rendered = result.0; metadata = result.1
    case .failure(let error): print("Thumbnail error: \(error)")
    }
    finished = true
}
spin(60, until: { finished })
check(finished && rendered != nil, "invisible thumbnail renderer produces an image")
check(metadata?.vertices == 3 && metadata?.triangles == 1 && metadata?.materials == 1, "thumbnail uses real parsed geometry and material metadata")
let png = rendered!.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))!.representation(using: .png, properties: [:])!
try png.write(to: root.appendingPathComponent("build/viewer-thumbnail.png"))
let bitmap = NSBitmapImageRep(data: png)!
var luminance = [CGFloat]()
for x in stride(from: 20, to: bitmap.pixelsWide - 20, by: 7) {
    for y in stride(from: 20, to: bitmap.pixelsHigh - 20, by: 7) {
        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) { luminance.append(color.redComponent + color.greenComponent + color.blueComponent) }
    }
}
check((luminance.max() ?? 0) - (luminance.min() ?? 0) > 0.4, "thumbnail contains model pixels rather than a blank canvas")
print(String(format: "METRIC: first thumbnail %.1f ms", Date().timeIntervalSince(start) * 1000))
try artifacts.save(rendered!, signature: file.signature)
try artifacts.save(metadata!, signature: file.signature)
check(artifacts.thumbnail(file.signature) != nil && artifacts.information(file.signature) == metadata, "browser thumbnail and metadata round trip")
let old = try FileSignature.read(renamed)
try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: renamed.path)
let changed = try FileSignature.read(renamed)
check(changed.identity == old.identity && changed.key != old.key && artifacts.thumbnail(changed) == nil, "mtime invalidates browser cache without losing file identity")
try artifacts.trim(megabytes: 0, protectedKeys: [file.signature.key])
check(artifacts.thumbnail(file.signature) != nil, "favorite thumbnails survive automatic eviction")
try artifacts.clear()
check(artifacts.statistics().bytes == 0, "explicit complete browser cleanup works")
try store.clear(includingPinned: true)
check((try! store.statistics()).count == 0, "explicit complete data cleanup includes favorites")
let opened = LibraryModel(store: try PreviewStore(root: testRoot.appendingPathComponent("OpenedFile")))
opened.openFile(hundredSource.appendingPathComponent("model-0.glb"))
spin(15, until: { !opened.busy })
check(opened.files.count == 1 && opened.showing3D && opened.selected?.name == "model-0.glb", "system file-open imports only selected file and enters viewer")
let reopenedFile = LibraryModel(store: try PreviewStore(root: testRoot.appendingPathComponent("OpenedFile")))
check(reopenedFile.files.count == 1 && reopenedFile.unavailable.isEmpty, "single-file security bookmark survives restart")
if let path = ProcessInfo.processInfo.environment["QL_TEST_FBX_FOLDER"] {
    let real = LibraryModel(store: try PreviewStore(root: testRoot.appendingPathComponent("RealStore")))
    var confirmedCount = 0
    real.confirmImport = { confirmedCount = $0; return true }
    let start = Date()
    real.importFolder(URL(fileURLWithPath: path)); spin(30, until: { !real.busy })
    check(!real.files.isEmpty && real.error == nil, "real FBX folder indexes successfully")
    print("METRIC: real files \(real.files.count), confirmation \(confirmedCount), index ms \(Date().timeIntervalSince(start) * 1000)")
    let files = real.visibleFiles
    var results = [[String: Any]]()
    for file in files.prefix(ProcessInfo.processInfo.environment["QL_TEST_ALL_FBX"] == "1" ? files.count : 3) {
        var done = false
        let start = Date()
        ThumbnailRenderer.shared.render(file.url, size: CGSize(width: 256, height: 256), settings: real.settings) { result in
            switch result {
            case .failure(let error): print("FBX error \(file.name): \(error)")
            case .success(let result):
                check(result.1 != nil, "real FBX metadata \(file.name)")
                try? real.artifacts?.save(result.0, signature: file.signature)
                if let info = result.1 { real.receiveInformation(info, file: file) }
                results.append(["file": file.name, "bytes": file.signature.size, "thumbnailMs": Date().timeIntervalSince(start) * 1000,
                    "vertices": result.1!.vertices, "triangles": result.1!.triangles, "materials": result.1!.materials,
                    "textureSizes": result.1!.textures.map { "\($0.width ?? 0)x\($0.height ?? 0)" },
                    "animationSeconds": result.1!.animations.map { $0.duration }])
            }
            done = true
        }
        spin(60, until: { done })
        check(done && results.last?["file"] as? String == file.name, "real FBX thumbnail \(file.name)")
        spin(0.2, until: { ThumbnailRenderer.shared.residentControllerCount <= 1 })
        check(ThumbnailRenderer.shared.residentControllerCount <= 1, "retired thumbnail controllers release")
    }
    try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("build/viewer-fbx-results.json"))
    print("METRIC: real browser cache \(real.artifacts?.statistics().bytes ?? 0) bytes, native pid \(ProcessInfo.processInfo.processIdentifier)")
    let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1120, height: 760), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = NSHostingView(rootView: ContentView().environmentObject(real))
    window.contentView = view; window.makeKeyAndOrderFront(nil)
    spin(3)
    view.layoutSubtreeIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("build/viewer-workspace.png"))
    window.close()
}
print("PASS: viewer regression complete")
