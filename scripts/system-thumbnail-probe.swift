import Cocoa
import QuickLookThumbnailing
let file = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 256, height: 256), scale: 1, representationTypes: .thumbnail)
var done = false
var success = false
QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
    if let representation = representation, representation.type == .thumbnail,
       let tiff = representation.nsImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
       let png = bitmap.representation(using: .png, properties: [:]) {
        var levels = [Double]()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    levels.append(Double(color.redComponent + color.greenComponent + color.blueComponent))
                }
            }
        }
        let hasContent = (levels.max() ?? 0) - (levels.min() ?? 0) > 0.15
        do { try png.write(to: output); success = hasContent; print("\(hasContent ? "PASS" : "FAIL"): system thumbnail API produced visible thumbnail content") }
        catch { print("FAIL: \(error)") }
    } else { print("FAIL: system thumbnail API: \(String(describing: error))") }
    done = true
}
let end = Date().addingTimeInterval(70)
while !done && Date() < end {
    autoreleasepool {
        if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005), inMode: .default, dequeue: true) { app.sendEvent(event) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
}
exit(success ? 0 : 1)
