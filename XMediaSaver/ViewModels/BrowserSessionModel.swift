import Combine
import Foundation
import WebKit

@MainActor
final class BrowserSessionModel: NSObject, ObservableObject {
    @Published private(set) var capturedPosts: [BookmarkedPost] = []
    @Published private(set) var currentURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var isAutoCapturing = false
    @Published private(set) var lastCaptureAt: Date?
    @Published private(set) var captureError: String?

    weak var webView: WKWebView?
    private var postsByID: [String: BookmarkedPost] = [:]
    private var allPostsByID: [String: BookmarkedPost] = [:]
    private var postOrder: [String] = []
    private var autoCaptureTask: Task<Void, Never>?

    var appearsLoggedIn: Bool {
        guard let currentURL else { return !capturedPosts.isEmpty }
        let path = currentURL.path.lowercased()
        return !path.contains("/i/flow/login")
            && !path.contains("/login")
            && (currentURL.host?.hasSuffix("x.com") == true)
    }

    var isOnBookmarksPage: Bool {
        currentURL?.path.lowercased().contains("/bookmarks") == true
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        if webView.url == nil {
            load(URL(string: "https://x.com/home")!)
        }
    }

    func detach(_ webView: WKWebView) {
        if self.webView === webView {
            self.webView = nil
        }
    }

    func load(_ url: URL) {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "x.com"
                || host.hasSuffix(".x.com")
                || host == "twitter.com"
                || host.hasSuffix(".twitter.com")
        else {
            captureError = "只允许在内置浏览器中打开 x.com。"
            return
        }
        webView?.load(URLRequest(url: url))
    }

    func openBookmarks() {
        load(URL(string: "https://x.com/i/bookmarks")!)
    }

    func reload() {
        webView?.reload()
    }

    func goBack() {
        guard webView?.canGoBack == true else { return }
        webView?.goBack()
    }

    func clearCapturedData() {
        capturedPosts = []
        postsByID = [:]
        allPostsByID = [:]
        postOrder = []
        lastCaptureAt = nil
        captureError = nil
    }

    func clearBrowserSession() async {
        stopAutoCapture()
        clearCapturedData()
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
                let xRecords = records.filter {
                    let name = $0.displayName.lowercased()
                    return name.contains("x.com") || name.contains("twitter.com")
                }
                dataStore.removeData(
                    ofTypes: dataTypes,
                    for: xRecords
                ) {
                    continuation.resume()
                }
            }
        }
        webView?.load(URLRequest(url: URL(string: "https://x.com/i/flow/login")!))
    }

    func startAutoCapture() {
        guard !isAutoCapturing else { return }
        guard isOnBookmarksPage else {
            captureError = "请先打开 X 的书签页面。"
            return
        }

        captureError = nil
        isAutoCapturing = true
        autoCaptureTask = Task { [weak self] in
            guard let self else { return }
            var unchangedRounds = 0
            var previousCount = capturedPosts.count

            for _ in 0..<200 {
                guard !Task.isCancelled else { break }
                guard let webView else { break }

                do {
                    _ = try await webView.evaluateJavaScript(
                        "window.scrollTo({top: document.body.scrollHeight, behavior: 'smooth'});"
                    )
                } catch {
                    captureError = error.localizedDescription
                    break
                }

                try? await Task.sleep(nanoseconds: 1_200_000_000)
                let currentCount = capturedPosts.count
                if currentCount == previousCount {
                    unchangedRounds += 1
                } else {
                    unchangedRounds = 0
                    previousCount = currentCount
                }

                if unchangedRounds >= 6 {
                    break
                }
            }
            isAutoCapturing = false
            autoCaptureTask = nil
        }
    }

    func stopAutoCapture() {
        autoCaptureTask?.cancel()
        autoCaptureTask = nil
        isAutoCapturing = false
    }

    func post(withID id: String) -> BookmarkedPost? {
        allPostsByID[id]
    }

    private func receiveCapture(url: String, body: String) {
        guard body.utf8.count <= 30_000_000 else {
            captureError = "单个浏览器响应过大，已跳过。"
            return
        }

        Task {
            do {
                let capture = try await Task.detached(priority: .utility) {
                    try BrowserCaptureParser.parse(
                        data: Data(body.utf8),
                        sourceURL: url
                    )
                }.value
                merge(
                    capture.posts,
                    isBookmarkCapture: url.contains("Bookmarks")
                        || url.contains("BookmarkFolderTimeline")
                )
                lastCaptureAt = Date()
                captureError = nil
            } catch {
                captureError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func merge(
        _ posts: [BookmarkedPost],
        isBookmarkCapture: Bool
    ) {
        for post in posts {
            allPostsByID[post.id] = post
            if isBookmarkCapture {
                if postsByID[post.id] == nil {
                    postOrder.append(post.id)
                }
                postsByID[post.id] = post
            }
        }
        capturedPosts = postOrder.compactMap { postsByID[$0] }
    }
}

extension BrowserSessionModel: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "xMediaCapture",
              let payload = message.body as? [String: Any],
              let url = payload["url"] as? String,
              let body = payload["body"] as? String
        else {
            return
        }
        Task { @MainActor [weak self] in
            self?.receiveCapture(url: url, body: body)
        }
    }
}

extension BrowserSessionModel: WKNavigationDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame != false,
              let url = navigationAction.request.url,
              let host = url.host?.lowercased()
        else {
            decisionHandler(.allow)
            return
        }
        let isAllowed = url.scheme?.lowercased() == "https"
            && (
                host == "x.com"
                    || host.hasSuffix(".x.com")
                    || host == "twitter.com"
                    || host.hasSuffix(".twitter.com")
            )
        decisionHandler(isAllowed ? .allow : .cancel)
        if !isAllowed {
            Task { @MainActor [weak self] in
                self?.captureError = "为保护登录会话，内置浏览器阻止了离开 x.com 的顶层跳转。"
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation?
    ) {
        Task { @MainActor [weak self] in
            self?.isLoading = true
            self?.currentURL = webView.url
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation?
    ) {
        Task { @MainActor [weak self] in
            self?.isLoading = false
            self?.currentURL = webView.url
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.isLoading = false
            self?.captureError = error.localizedDescription
        }
    }
}
