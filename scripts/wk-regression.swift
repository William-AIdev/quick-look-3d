import Cocoa
import WebKit

final class Receiver: NSObject, WKScriptMessageHandler {
    var events: [[String: Any]] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let event = message.body as? [String: Any] { events.append(event) }
    }
}
func spin(_ duration: Double, until: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(duration)
    while !until() && Date() < end {
        if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
}
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
    print("PASS: \(message)")
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let receiver = Receiver()
let config = WKWebViewConfiguration()
config.userContentController.add(receiver, name: "preview")
var rulesReady = false
WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "offline-regression", encodedContentRuleList: """
[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
""") { rules, error in
    check(error == nil && rules != nil, "offline content blocking installed")
    config.userContentController.add(rules!)
    rulesReady = true
}
spin(10, until: { rulesReady })
check(rulesReady, "content rules ready")
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
let web = WKWebView(frame: window.contentView!.bounds, configuration: config)
window.contentView = web
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
let html = root.appendingPathComponent("renderer/dist/index.html")
web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
spin(20, until: { receiver.events.contains { $0["type"] as? String == "pageReady" } })
check(receiver.events.contains { $0["type"] as? String == "pageReady" }, "renderer page ready")
func evaluate(_ script: String) -> Any? {
    var done = false
    var value: Any?
    web.evaluateJavaScript(script) { result, error in
        check(error == nil, "JavaScript evaluation")
        value = result; done = true
    }
    spin(10, until: { done })
    check(done, "JavaScript callback completed")
    return value
}
func send(_ message: [String: Any]) {
    let bytes = try! JSONSerialization.data(withJSONObject: message)
    _ = evaluate("window.postMessage(\(String(data: bytes, encoding: .utf8)!), '*')")
}
func load(_ name: String, _ id: String) {
    let file = root.appendingPathComponent("renderer/tests/fixtures/\(name).glb")
    let bytes = try! Data(contentsOf: file)
    send(["type":"loadVRM", "requestID":id, "base64":bytes.base64EncodedString()])
}
func event(_ type: String, _ id: String) -> Bool {
    receiver.events.contains { $0["type"] as? String == type && $0["requestID"] as? String == id }
}
var samples: [String: [Double]] = [:]
for name in ["plain", "draco", "meshopt"] {
    for index in 0..<5 {
        let id = "\(name)-\(index)"
        let start = Date()
        load(name,id)
        spin(20, until: { event("firstFrame",id) || event("error",id) })
        check(event("firstFrame",id), "offline \(id) first frame")
        check(evaluate("getComputedStyle(document.getElementById('overlay')).display === 'none'") as? Bool == true, "first frame has no loading overlay")
        samples[name, default: []].append(Date().timeIntervalSince(start)*1000)
    }
}
spin(1)
let before = (evaluate("previewDiagnostics()") as! [String: Any])["frameCount"] as! Int
spin(0.5)
let after = (evaluate("previewDiagnostics()") as! [String: Any])["frameCount"] as! Int
check(before > 0 && before == after, "static idle submits no frames after scheduler ran")
let staticStats = evaluate("previewDiagnostics()") as! [String: Any]
check(staticStats["idle"] as? Bool == true && staticStats["fps"] is NSNull, "static FPS reports idle rather than a fake zero")
let info = staticStats["modelInfo"] as! [String: Any]
check(info["vertices"] as? Int == 3 && info["triangles"] as? Int == 1 && info["materials"] as? Int == 1, "actual geometry and material metadata")
func frames() -> Int { (evaluate("previewDiagnostics()") as! [String: Any])["frameCount"] as! Int }
load("animated", "animated")
spin(10, until: { event("firstFrame","animated") })
check(event("firstFrame","animated"), "animated glTF first frame")
let animationBefore = frames()
spin(0.4)
check(frames() > animationBefore, "animation keeps rendering")
send(["type":"visibility", "visible":false])
spin(0.1)
let hiddenBefore = frames()
spin(0.4)
check(frames() == hiddenBefore, "hidden animation submits no frames")
send(["type":"visibility", "visible":true])
spin(0.4)
check(frames() > hiddenBefore, "animation resumes when visible")
send(["type":"settings", "fps":15, "animate":true, "pixelRatio":1])
spin(0.2)
let cappedBefore = frames()
spin(1)
let cappedFrames = frames() - cappedBefore
check(cappedFrames > 3 && cappedFrames <= 18, "15 FPS animation cap")
let measured = (evaluate("previewDiagnostics()") as! [String: Any])["fps"] as? Double
check(measured != nil && measured! > 3 && measured! <= 18, "live FPS measures actual capped draws")
send(["type":"settings", "fps":30, "animate":false, "pixelRatio":1])
spin(0.2)
let pausedBefore = frames()
spin(0.4)
check(frames() == pausedBefore, "animation preference disables continuous frames")
check((evaluate("previewDiagnostics()") as! [String: Any])["idle"] as? Bool == true, "paused animation reports idle")
send(["type":"settings", "fps":30, "animate":true, "pixelRatio":1])
for name in ["textured", "textured-draco", "textured-meshopt"] {
    let file = root.appendingPathComponent("build/\(name)-optimized.glb")
    let bytes = try! Data(contentsOf: file)
    send(["type":"loadVRM", "requestID":name, "base64":bytes.base64EncodedString()])
    spin(20, until: { event("firstFrame",name) || event("error",name) })
    check(event("firstFrame",name), "optimized offline \(name) first frame")
}
for (key, label) in [("QL_TEST_FBX", "real-fbx"), ("QL_TEST_VRM", "real-vrm"), ("QL_TEST_VRMA", "real-vrma")] {
    if let path = ProcessInfo.processInfo.environment[key] {
        let bytes = try! Data(contentsOf: URL(fileURLWithPath:path))
        send(["type":"loadVRM", "requestID":label, "base64":bytes.base64EncodedString()])
        spin(45, until: { event("firstFrame",label) || event("error",label) })
        check(event("firstFrame",label), "optional \(label) first frame")
    }
}
load("broken","broken")
spin(10, until: { event("error","broken") })
check(event("error","broken"), "broken input reports failure")
load("plain","recovered")
spin(10, until: { event("firstFrame","recovered") })
check(event("firstFrame","recovered"), "recovers after malformed input")
// Queue two loads in a single JS task so an async parse cannot commit over its successor.
let a = try! Data(contentsOf: root.appendingPathComponent("renderer/tests/fixtures/draco.glb")).base64EncodedString()
let b = try! Data(contentsOf: root.appendingPathComponent("renderer/tests/fixtures/plain.glb")).base64EncodedString()
_ = evaluate("window.postMessage({type:'loadVRM',requestID:'stale-A',base64:'\(a)'},'*');window.postMessage({type:'loadVRM',requestID:'latest-B',base64:'\(b)'},'*')")
spin(10, until: { event("firstFrame","latest-B") })
spin(0.5)
check(event("firstFrame","latest-B") && !event("firstFrame","stale-A"), "rapid switch rejects stale result")
for index in 0..<100 {
    let id = "cycle-\(index)"
    load(index % 2 == 0 ? "draco" : "meshopt",id)
    spin(10, until: { event("firstFrame",id) || event("error",id) })
    check(event("firstFrame",id), "cycle \(index)")
}
let diagnostics = evaluate("previewDiagnostics()") as! [String: Any]
check((diagnostics["geometries"] as! Int) <= 2, "geometry count bounded after 100 loads")
spin(0.6)
var snapshotDone = false
web.takeSnapshot(with: nil) { image, error in
    check(image != nil && error == nil, "native WebGL snapshot")
    if let image = image, let tiff = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
        try! png.write(to: root.appendingPathComponent("build/wk-regression.png"))
    }
    snapshotDone = true
}
spin(10, until: { snapshotDone })
let result: [String: Any] = ["samplesMS":samples, "diagnostics":diagnostics, "events":receiver.events]
let output = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
try! output.write(to: root.appendingPathComponent("build/wk-regression.json"))
window.close()
print("PASS: WK regression complete")
