import Cocoa
import QuickLookThumbnailing

final class BrowserThumbnailService {
    private final class Job {
        let id = UUID()
        let file: LibraryFile
        let completion: (NSImage?, ModelInformation?, Error?) -> Void
        var request: QLThumbnailGenerator.Request?
        var renderID: UUID?
        var done = false
        init(_ file: LibraryFile, _ completion: @escaping (NSImage?, ModelInformation?, Error?) -> Void) {
            self.file = file; self.completion = completion
        }
    }
    let artifacts: FileArtifacts
    var settings = PreviewSettings()
    var budgetMegabytes = 2048
    var protectedKeys = Set<String>()
    private let queue = DispatchQueue(label: "QuickLook3D.browser-cache", qos: .utility)
    private let images = NSCache<NSString, NSImage>()
    private var pending = [Job]()
    private var active = [UUID: Job]()
    init(artifacts: FileArtifacts) {
        self.artifacts = artifacts
        images.countLimit = 128; images.totalCostLimit = 32 * 1024 * 1024
    }
    @discardableResult
    func load(_ file: LibraryFile, completion: @escaping (NSImage?, ModelInformation?, Error?) -> Void) -> UUID {
        let job = Job(file, completion)
        pending.append(job); pump(); return job.id
    }
    func cancel(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            let job = pending.remove(at: index); job.done = true
            job.completion(nil, nil, CocoaError(.userCancelled))
        } else if let job = active[id] {
            if let request = job.request { QLThumbnailGenerator.shared.cancel(request) }
            if let id = job.renderID { ThumbnailRenderer.shared.cancel(id) }
            finish(job, image: nil, information: nil, error: CocoaError(.userCancelled))
        }
    }
    func clearMemory() { images.removeAllObjects() }
    private func pump() {
        while active.count < 2, !pending.isEmpty {
            let job = pending.removeFirst(); active[job.id] = job
            if let image = images.object(forKey: job.file.signature.key as NSString) {
                finish(job, image: image, information: nil, error: nil); continue
            }
            queue.async {
                let image = self.artifacts.thumbnail(job.file.signature)
                DispatchQueue.main.async {
                    guard !job.done else { return }
                    guard (try? FileSignature.read(job.file.url)) == job.file.signature else {
                        self.finish(job, image: nil, information: nil, error: CocoaError(.fileReadUnknown)); return
                    }
                    if let image = image { self.finish(job, image: image, information: nil, error: nil) }
                    else { self.generate(job) }
                }
            }
        }
    }
    private func generate(_ job: Job) {
        let request = QLThumbnailGenerator.Request(fileAt: job.file.url, size: CGSize(width: 256, height: 256), scale: 1, representationTypes: .thumbnail)
        job.request = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            DispatchQueue.main.async {
                guard !job.done else { return }
                if let representation = representation, representation.type == .thumbnail {
                    self.store(job, image: representation.nsImage, information: nil)
                } else {
                    job.renderID = ThumbnailRenderer.shared.render(job.file.url, size: CGSize(width: 256, height: 256), settings: self.settings) { result in
                        guard !job.done else { return }
                        switch result {
                        case .failure(let error): self.finish(job, image: nil, information: nil, error: error)
                        case .success(let result): self.store(job, image: result.0, information: result.1)
                        }
                    }
                }
            }
        }
    }
    private func store(_ job: Job, image: NSImage, information: ModelInformation?) {
        guard (try? FileSignature.read(job.file.url)) == job.file.signature else {
            finish(job, image: nil, information: nil, error: CocoaError(.fileReadUnknown)); return
        }
        let budget = budgetMegabytes, keys = protectedKeys
        queue.async {
            let result = Result {
                try self.artifacts.save(image, signature: job.file.signature)
                if let info = information { try self.artifacts.save(info, signature: job.file.signature) }
                try self.artifacts.trim(megabytes: budget, protectedKeys: keys)
            }
            DispatchQueue.main.async {
                switch result {
                case .success: self.finish(job, image: image, information: information, error: nil)
                case .failure(let error): self.finish(job, image: image, information: information, error: error)
                }
            }
        }
    }
    private func finish(_ job: Job, image: NSImage?, information: ModelInformation?, error: Error?) {
        guard !job.done else { return }
        job.done = true; active[job.id] = nil
        if let image = image { images.setObject(image, forKey: job.file.signature.key as NSString, cost: image.representations.map { $0.pixelsWide * $0.pixelsHigh * 4 }.max() ?? Int(image.size.width * image.size.height) * 4) }
        job.completion(image, information, error)
        pump()
    }
}
