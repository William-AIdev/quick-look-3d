import Cocoa
import WebKit

func spin(_ duration: Double, until: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(duration)
    while !until() && Date() < end {
        if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
}
func check(_ condition: Bool, _ message: String) {
    guard condition else { print("FAIL: \(message)"); exit(1) }
    print("PASS: \(message)")
}
weak var releasedController: PreviewViewController?
autoreleasepool {
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x:100,y:100,width:640,height:480), styleMask:[.titled], backing:.buffered, defer:false)
window.isReleasedWhenClosed = false
var controller: PreviewViewController? = PreviewViewController()
releasedController = controller
window.contentViewController = controller
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps:true)
let web = controller!.view as! WKWebView
let plain = root.appendingPathComponent("renderer/tests/fixtures/plain.glb")
let compressed = root.appendingPathComponent("renderer/tests/fixtures/draco.glb")
var calls = [String:Int]()
var errors = [String:Bool]()
func prepare(_ url: URL, _ id: String) {
    controller!.preparePreviewOfFile(at:url) { error in
        calls[id,default:0] += 1
        errors[id] = error != nil
    }
}
prepare(plain,"initial")
spin(20,until:{calls["initial"] != nil})
check(calls["initial"] == 1 && errors["initial"] == false,"native completes after initial model")
prepare(compressed,"cancelled")
prepare(plain,"latest")
spin(20,until:{calls["latest"] != nil})
spin(0.3)
check(calls["cancelled"] == 1 && errors["cancelled"] == true,"superseded native callback once")
check(calls["latest"] == 1 && errors["latest"] == false,"latest native callback once")
check(controller!.view === web,"same WebView reused")
prepare(root.appendingPathComponent("不存在 missing.glb"),"missing")
spin(10,until:{calls["missing"] != nil})
check(calls["missing"] == 1 && errors["missing"] == true,"native file read failure")
prepare(plain,"recovery")
controller!.webViewWebContentProcessDidTerminate(web)
spin(20,until:{calls["recovery"] != nil})
check(calls["recovery"] == 1 && errors["recovery"] == false,"termination delegate reloads pending request")
prepare(plain,"bounded")
controller!.webViewWebContentProcessDidTerminate(web)
controller!.webViewWebContentProcessDidTerminate(web)
spin(0.3)
check(calls["bounded"] == 1 && errors["bounded"] == true,"repeated termination fails once")
prepare(plain,"next")
spin(20,until:{calls["next"] != nil})
check(calls["next"] == 1 && errors["next"] == false,"new request recovers after termination limit")
window.contentViewController = nil
window.contentView = NSView()
window.close()
controller = nil
spin(1)

window.close()
}
spin(0.2)
check(releasedController == nil,"script bridge does not retain controller")
print("PASS: native controller regression complete")
