import Cocoa
import WebKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let quality = CommandLine.arguments[2]
let source = URL(fileURLWithPath: CommandLine.arguments[3])
let cold = CommandLine.arguments[4] == "cold"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
func spin(_ duration: Double, until done: () -> Bool = { false }) { let end = Date().addingTimeInterval(duration); while !done() && Date() < end { if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }; RunLoop.main.run(until: Date().addingTimeInterval(0.005)) } }
let store = try PreviewStore(root: root.appendingPathComponent("build/memory-store"))
var settings = PreviewSettings(); settings.quality = quality; settings.animate = false
try store.save(settings)
if cold { try store.clear() }
let entriesBefore = try store.statistics().count
let controller = PreviewViewController(); controller.previewStore = store
let window = NSWindow(contentRect: NSRect(x: 100,y: 100,width: 640,height: 480), styleMask: [.titled], backing: .buffered,defer: false)
window.isReleasedWhenClosed = false
controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
controller.view.autoresizingMask = [.width, .height]
window.contentViewController = controller
window.setContentSize(NSSize(width: 640, height: 480))
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
print("PHASE ready"); fflush(stdout)
spin(0.5)
var durations = [Double]()
for index in 0..<6 {
 var done = false; var failure: Error?
 let start = Date()
 print("PHASE load-\(index)"); fflush(stdout)
 controller.preparePreviewOfFile(at: source) { error in failure = error; done = true }
 spin(60, until: { done })
 guard done && failure == nil else { print("FAIL: \(String(describing: failure))"); exit(1) }
 durations.append(Date().timeIntervalSince(start)*1000)
 print("PHASE idle-\(index)"); fflush(stdout)
 spin(index == 0 ? 1.5 : 0.3)
}
let web = controller.view as! WKWebView
var diagnostics: Any?; var diagnosed = false
web.evaluateJavaScript("previewDiagnostics()") { value, error in diagnostics = value; diagnosed = true }
spin(10, until: { diagnosed })
var snapshotDone = false
web.takeSnapshot(with: nil) { image,error in
 guard error == nil, image != nil else { print("FAIL: native preview snapshot: \(String(describing:error))"); exit(1) }
 if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff), let png = rep.representation(using:.png,properties:[:]) { try? png.write(to: root.appendingPathComponent("build/preview-\(quality).png")) }
 snapshotDone = true
}
spin(10, until: { snapshotDone })
let report: [String:Any] = ["quality":quality,"source":source.lastPathComponent,"cacheMode":cold ? "cold" : "warm","entriesBefore":entriesBefore,"loadMilliseconds":durations,"diagnostics":diagnostics ?? [:]]
let bytes = try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys])
print("RESULT "+String(data:bytes,encoding:.utf8)!); fflush(stdout)
window.close()
