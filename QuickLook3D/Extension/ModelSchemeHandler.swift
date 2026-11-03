import Foundation
import WebKit

final class ModelSchemeHandler: NSObject, WKURLSchemeHandler {
    private var payloads = [String: Data]()
    func register(_ data: Data, id: String) { payloads = [id: data] }
    func clear() { payloads.removeAll() }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "preview", let data = payloads[url.lastPathComponent] else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/octet-stream", "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
