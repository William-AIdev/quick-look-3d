import Cocoa

final class ThumbnailRenderer {
    static let shared = ThumbnailRenderer()
    private struct Job {
        let id: UUID
        let url: URL
        let size: CGSize
        let settings: PreviewSettings
        let completion: (Result<(NSImage, ModelInformation?), Error>) -> Void
    }
    private final class RetiredController {
        weak var value: PreviewViewController?
        init(_ value: PreviewViewController) { self.value = value }
    }
    private var retired = [RetiredController]()
    var residentControllerCount: Int {
        autoreleasepool {
            retired.removeAll { $0.value == nil }
            return retired.count + (controller == nil ? 0 : 1)
        }
    }
    private var pending = [Job]()
    private var active: Job?
    private var controller: PreviewViewController?
    private var window: NSWindow?
    private var information: ModelInformation?
    private var cleanup: DispatchWorkItem?
    private var completedSinceReset = 0
    private var bytesSinceReset: Int64 = 0

    @discardableResult
    func render(_ url: URL, size: CGSize, settings: PreviewSettings,
                completion: @escaping (Result<(NSImage, ModelInformation?), Error>) -> Void) -> UUID {
        precondition(Thread.isMainThread)
        let id = UUID()
        pending.append(Job(id: id, url: url, size: size, settings: settings, completion: completion))
        autoreleasepool { startNext() }
        return id
    }
    func cancel(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: index).completion(.failure(CocoaError(.userCancelled)))
        } else if active?.id == id {
            controller?.stopViewing()
            finish(id, .failure(CocoaError(.userCancelled)))
        }
    }
    private func startNext() {
        guard active == nil, !pending.isEmpty else { return }
        cleanup?.cancel()
        let job = pending.removeFirst()
        active = job; information = nil
        bytesSinceReset += (try? FileSignature.read(job.url).size) ?? 0
        if controller == nil {
            let controller = PreviewViewController()
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: job.size), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            controller.view.frame = NSRect(origin: .zero, size: job.size)
            controller.view.autoresizingMask = [.width, .height]
            window.contentViewController = controller
            window.setContentSize(job.size)
            window.orderBack(nil)
            self.controller = controller; self.window = window
        }
        guard let controller = controller else { return }
        window?.setContentSize(job.size)
        var settings = job.settings
        settings.animate = false; settings.cacheEnabled = false; settings.quality = "economy"
        controller.settingsOverride = settings
        controller.onModelInformation = { [weak self] in self?.information = $0 }
        controller.preparePreviewOfFile(at: job.url) { [weak self, weak controller] error in
            guard let self = self, self.active?.id == job.id else { return }
            if let error = error { self.finish(job.id, .failure(error)); return }
            DispatchQueue.main.async { [self] in
                guard self.active?.id == job.id else { return }
                controller?.snapshot { [weak self] image, error in
                    guard let self = self, self.active?.id == job.id else { return }
                    if let image = image { self.finish(job.id, .success((image, self.information))) }
                    else { self.finish(job.id, .failure(error ?? CocoaError(.fileReadUnknown))) }
                }
            }
        }
    }
    private func reset() {
        if let controller = controller { retired.append(RetiredController(controller)) }
        controller?.stopViewing()
        window?.contentViewController = nil
        window?.contentView = NSView()
        window?.orderOut(nil); window?.close()
        window = nil; controller = nil
        completedSinceReset = 0; bytesSinceReset = 0
    }
    private func finish(_ id: UUID, _ result: Result<(NSImage, ModelInformation?), Error>) {
        guard let job = active, job.id == id else { return }
        active = nil
        controller?.releaseModel()
        completedSinceReset += 1
        if completedSinceReset >= 8 || bytesSinceReset >= 256 * 1024 * 1024 {
            reset()
        }
        job.completion(result)
        if pending.isEmpty {
            let cleanup = DispatchWorkItem { [weak self] in
                guard let self = self, self.active == nil else { return }
                self.reset()
            }
            self.cleanup = cleanup
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: cleanup)
        } else { startNext() }
    }
}
