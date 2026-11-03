import Cocoa
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        DispatchQueue.main.async {
            let maxSize = request.maximumSize
            let side = min(512, max(64, max(maxSize.width, maxSize.height)))
            let size = CGSize(width: side, height: side)
            let settings = (try? PreviewStore())?.settings() ?? PreviewSettings()
            ThumbnailRenderer.shared.render(request.fileURL, size: size, settings: settings) { result in
                switch result {
                case .failure(let error): handler(nil, error)
                case .success(let output):
                    let image = output.0
                    let reply = QLThumbnailReply(contextSize: size) { context in
                        NSGraphicsContext.saveGraphicsState()
                        defer { NSGraphicsContext.restoreGraphicsState() }
                        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
                        return true
                    }
                    handler(reply, nil)
                }
            }
        }
    }
}
