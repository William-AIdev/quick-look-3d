import Cocoa
import os
import Quartz
import WebKit

private let qlLog = Logger(subsystem: "com.sawazen.QuickLook3D", category: "preview")

private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

final class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    private var recoveryAttempts = 0
    private var pageReady = false
    private var pageLoading = false
    private var requestID: String?
    private var completion: ((Error?) -> Void)?
    lazy var previewStore: PreviewStore? = try? PreviewStore()
    private let modelScheme = ModelSchemeHandler()
    private var previewSettings = PreviewSettings()
    private let preparationQueue = DispatchQueue(label: "QuickLook3D.preview-prepare", qos: .userInitiated)
    private var preparationCancellation = CancellationFlag()
    private var payload: Data?
    private var modelURL: URL?
    private var timeout: DispatchWorkItem?

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(modelScheme, forURLScheme: "qlmodel")
        let receiver = WeakHandler(self)
        config.userContentController.add(receiver, name: "log")
        config.userContentController.add(receiver, name: "preview")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        view = webView
    }

    deinit {
        preparationCancellation.cancel()
        timeout?.cancel()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "log")
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "preview")
        completion?(NSError(domain: "QuickLook3D", code: -999))
    }

    private func finish(_ error: Error?) {
        preparationCancellation.cancel()
        timeout?.cancel()
        timeout = nil
        payload = nil
        modelScheme.clear()
        let callback = completion
        completion = nil
        callback?(error)
    }

    private func failure(_ text: String) -> NSError {
        NSError(domain: "QuickLook3D", code: -1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        _ = view
        recoveryAttempts = 0
        finish(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        let id = UUID().uuidString
        requestID = id
        completion = handler
        modelURL = url
        qlLog.log("request \(id, privacy: .public)")
        if pageReady { send(["type": "cancel", "requestID": id]) }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self = self, self.requestID == id else { return }
            self.send(["type": "cancel", "requestID": id])
            self.finish(self.failure("Preview timed out"))
        }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: deadline)
        ensurePage()
        let store = previewStore
        preparationCancellation = CancellationFlag()
        let flag = preparationCancellation
        preparationQueue.async { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let settings = store?.settings() ?? PreviewSettings()
            let result = Result { () throws -> Data in
                if let store = store {
                    return try store.prepare(url, settings: settings, cancelled: { flag.cancelled }).data
                }
                if flag.cancelled { throw CocoaError(.userCancelled) }
                let limit = settings.maximumFileMegabytes * 1024 * 1024
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= limit else { throw CocoaError(.fileReadTooLarge) }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
                return try GLBPreviewOptimizer.optimize(data, limit: settings.textureLimit, cancelled: { flag.cancelled }).data
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.requestID == id, self.completion != nil else { return }
                switch result {
                case .success(let data):
                    self.previewSettings = settings
                    self.payload = data
                    qlLog.log("read \(id, privacy: .public)")
                    self.deliver()
                case .failure(let error): self.finish(error)
                }
            }
        }
    }

    private func ensurePage() {
        guard !pageReady, !pageLoading else { return }
        guard let html = Bundle(for: PreviewViewController.self).url(forResource: "index", withExtension: "html", subdirectory: "renderer") else {
            finish(failure("renderer/index.html missing")); return
        }
        pageLoading = true
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        let id = requestID
        webView.evaluateJavaScript("window.postMessage(\(json), '*')") { [weak self] _, error in
            guard let self = self, self.requestID == id else { return }
            if let error = error { self.finish(error) }
        }
    }

    private func deliver() {
        guard pageReady, let data = payload, let id = requestID, completion != nil else { return }
        payload = nil
        modelScheme.register(data, id: id)
        send(["type": "settings", "pixelRatio": previewSettings.pixelRatio, "fps": previewSettings.framesPerSecond, "animate": previewSettings.animate])
        send(["type": "loadModel", "requestID": id, "url": "qlmodel://preview/" + id])
        qlLog.log("transfer \(id, privacy: .public)")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "log" {
            qlLog.log("JS \(String(describing: message.body), privacy: .public)")
            return
        }
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "pageReady" {
            pageReady = true
            pageLoading = false
            qlLog.log("page-ready")
            deliver()
            return
        }
        guard body["requestID"] as? String == requestID else { return }
        if type == "firstFrame" { finish(nil) }
        if type == "error" { finish(failure(body["message"] as? String ?? "Model load failed")) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageLoading = false; pageReady = false; finish(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageReady = false; pageLoading = false
        guard recoveryAttempts < 1 else {
            modelURL = nil
            finish(failure("Web content process repeatedly terminated"))
            return
        }
        let url = modelURL
        let callback = completion
        completion = nil
        timeout?.cancel()
        if let url = url {
            preparePreviewOfFile(at: url, completionHandler: callback ?? { _ in })
            recoveryAttempts = 1
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        send(["type": "visibility", "visible": true])
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        send(["type": "visibility", "visible": false])
    }
}
