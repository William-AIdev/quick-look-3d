import Cocoa
import SwiftUI
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let store = try PreviewStore(root: root.appendingPathComponent("build/ui-store"))
let model = LibraryModel(store: store)
let window = NSWindow(contentRect:NSRect(x:100,y:100,width:980,height:690),styleMask:[.titled,.closable],backing:.buffered,defer:false)
window.isReleasedWhenClosed = false
window.title = "QuickLook3D"
let view = NSHostingView(rootView: ContentView().environmentObject(model))
window.contentView = view
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps:true)
let end = Date().addingTimeInterval(1)
while Date() < end { if let event = app.nextEvent(matching:.any,until:Date().addingTimeInterval(0.005),inMode:.default,dequeue:true) { app.sendEvent(event) }; RunLoop.main.run(until:Date().addingTimeInterval(0.005)) }
view.layoutSubtreeIfNeeded()
let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
view.cacheDisplay(in:view.bounds,to:rep)
try rep.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("build/workspace.png"))
print("PASS: workspace snapshot")
window.close()
