import Foundation
let token = CommandLine.arguments[2]
let base = try PreviewStore().root.appendingPathComponent("probe-" + token)
let store = try PreviewStore(root: base)
let file = store.root.appendingPathComponent("triangle.glb")
if CommandLine.arguments[1] == "write" {
    var settings = PreviewSettings(); settings.framesPerSecond = 15; settings.quality = "balanced"
    try store.save(settings)
    let fixture = Bundle.main.url(forResource: "plain", withExtension: "glb")!
    try Data(contentsOf: fixture).write(to: file, options: .atomic)
    _ = try store.prepare(file, settings: settings)
    print("PASS: sandbox app identity persists settings and model cache")
} else {
    let settings = store.settings()
    guard settings.framesPerSecond == 15 && settings.quality == "balanced", try store.prepare(file, settings: settings).cacheHit else { fatalError("sandbox cache sharing failed") }
    try store.clear()
    try FileManager.default.removeItem(at: file)
    try FileManager.default.removeItem(at: store.root.appendingPathComponent("settings.json"))
    print("PASS: independent extension identity reads settings and hits prepared cache")
}
