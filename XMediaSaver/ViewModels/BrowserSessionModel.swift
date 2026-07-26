import Combine
import Foundation
import UIKit
import WebKit

@MainActor
final class BrowserSessionModel: NSObject, ObservableObject {
    @Published private(set) var capturedPosts: [BookmarkedPost] = []
    @Published private(set) var currentURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var isAutoCapturing = false
    @Published private(set) var syncPageCount = 0
    @Published private(set) var syncStatusText: String?
    @Published private(set) var lastCaptureAt: Date?
    @Published private(set) var captureError: String?

    private(set) var webView: WKWebView!
    private var postsByID: [String: BookmarkedPost] = [:]
    private var allPostsByID: [String: BookmarkedPost] = [:]
    private var postOrder: [String] = []
    private var autoCaptureTask: Task<Void, Never>?
    private var navigationTimeoutTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var messageHandlerProxy: WeakScriptMessageHandler?
    private let persistenceStore = BookmarkPersistenceStore()
    private var bookmarkResponseSequence = 0
    private var autoSyncWhenAuthenticated = false

    override init() {
        super.init()

        let controller = WKUserContentController()
        controller.addUserScript(
            WKUserScript(
                source: BrowserCaptureScript.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        let proxy = WeakScriptMessageHandler(delegate: self)
        messageHandlerProxy = proxy
        controller.add(proxy, name: "xMediaCapture")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.allowsInlineMediaPlayback = true
        configuration.applicationNameForUserAgent =
            "Version/17.0 Mobile/15E148 Safari/604.1"

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground

        Task { [weak self] in
            guard let self else { return }
            do {
                let storedPosts = try await self.persistenceStore.load()
                self.restore(storedPosts)
            } catch {
                self.captureError =
                    "无法读取本地书签索引：\(error.localizedDescription)"
            }
        }
    }

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
        captureError = nil
        webView.load(URLRequest(url: url))
    }

    func prepareBrowser() {
        guard webView.url == nil, !isLoading else { return }
        load(URL(string: "https://x.com/i/flow/login")!)
    }

    func browserDidAppear() {
        autoSyncWhenAuthenticated = true
        prepareBrowser()
        if appearsLoggedIn && currentURL != nil {
            autoSyncWhenAuthenticated = false
            startAutoCapture()
        }
    }

    func retryBrowserLogin() {
        navigationTimeoutTask?.cancel()
        webView.stopLoading()
        isLoading = false
        currentURL = nil
        captureError = nil
        load(URL(string: "https://x.com/i/flow/login")!)
    }

    func openBookmarks() {
        load(URL(string: "https://x.com/i/bookmarks")!)
    }

    func reload() {
        webView.reload()
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    func clearCapturedData() {
        persistenceTask?.cancel()
        capturedPosts = []
        postsByID = [:]
        allPostsByID = [:]
        postOrder = []
        syncPageCount = 0
        syncStatusText = nil
        lastCaptureAt = nil
        captureError = nil
        Task {
            try? await self.persistenceStore.clear()
        }
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
        webView.load(URLRequest(url: URL(string: "https://x.com/i/flow/login")!))
    }

    func startAutoCapture() {
        guard !isAutoCapturing else { return }

        captureError = nil
        isAutoCapturing = true
        syncPageCount = 0
        syncStatusText = "正在打开书签页面…"
        autoCaptureTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isAutoCapturing = false
                autoCaptureTask = nil
                if Task.isCancelled {
                    syncStatusText = "同步已停止"
                } else if captureError == nil {
                    syncStatusText = "本轮同步完成"
                }
            }

            if !isOnBookmarksPage {
                openBookmarks()
                for _ in 0..<80 {
                    guard !Task.isCancelled else { return }
                    if isOnBookmarksPage && !isLoading {
                        break
                    }
                    if currentURL?.path.lowercased().contains("/login") == true
                        || currentURL?.path.lowercased().contains("/i/flow/login") == true {
                        captureError = "登录会话已失效，请先到“X 浏览器”重新登录。"
                        return
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }

            guard isOnBookmarksPage else {
                captureError = "无法打开书签页面，请先到“X 浏览器”确认登录状态。"
                return
            }

            syncStatusText = "正在等待 X 返回书签分页…"
            var responseTimeouts = 0

            for _ in 0..<200 {
                guard !Task.isCancelled else { break }
                let responseBeforeScroll = bookmarkResponseSequence

                do {
                    _ = try await webView.evaluateJavaScript(
                        "window.scrollTo({top: document.body.scrollHeight, behavior: 'smooth'});"
                    )
                } catch {
                    captureError = error.localizedDescription
                    break
                }

                var receivedNextResponse = false
                for _ in 0..<25 {
                    guard !Task.isCancelled else { return }
                    if bookmarkResponseSequence > responseBeforeScroll {
                        receivedNextResponse = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }

                if receivedNextResponse {
                    responseTimeouts = 0
                    syncPageCount += 1
                    syncStatusText =
                        "已确认 \(syncPageCount) 个分页响应，累计 \(capturedPosts.count) 条"
                    try? await Task.sleep(nanoseconds: 650_000_000)
                } else {
                    responseTimeouts += 1
                    syncStatusText =
                        "等待下一页响应（\(responseTimeouts)/4）…"
                }

                if responseTimeouts >= 4 {
                    break
                }
            }
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

    func capturePost(
        withID id: String,
        from url: URL
    ) async throws -> BookmarkedPost {
        if let cached = allPostsByID[id] {
            return cached
        }

        stopAutoCapture()
        captureError = nil
        load(url)

        for _ in 0..<100 {
            try Task.checkCancellation()
            if let captured = allPostsByID[id] {
                return captured
            }
            if currentURL?.path.lowercased().contains("/login") == true
                || currentURL?.path.lowercased().contains("/i/flow/login") == true {
                throw AppError.notLoggedIn
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw AppError.browserCaptureFailed(
            "X 页面没有在等待时间内返回这条帖子的媒体数据。"
        )
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
                let isBookmarkCapture = url.contains("Bookmarks")
                    || url.contains("BookmarkFolderTimeline")
                if isBookmarkCapture {
                    bookmarkResponseSequence += 1
                }
                merge(
                    capture.posts,
                    isBookmarkCapture: isBookmarkCapture
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
        if isBookmarkCapture {
            schedulePersistence()
        }
    }

    private func restore(_ posts: [BookmarkedPost]) {
        guard !posts.isEmpty else { return }
        for post in posts where postsByID[post.id] == nil {
            postsByID[post.id] = post
            allPostsByID[post.id] = post
            postOrder.append(post.id)
        }
        capturedPosts = postOrder.compactMap { postsByID[$0] }
        schedulePersistence()
    }

    private func schedulePersistence() {
        persistenceTask?.cancel()
        let snapshot = capturedPosts
        persistenceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            do {
                try await self.persistenceStore.save(snapshot)
            } catch {
                self.captureError =
                    "无法保存本地书签索引：\(error.localizedDescription)"
            }
        }
    }

    private func navigationStarted(url: URL?) {
        navigationTimeoutTask?.cancel()
        isLoading = true
        currentURL = url
        navigationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self, isLoading else { return }
            webView.stopLoading()
            isLoading = false
            captureError = "X 页面加载超过 30 秒。请检查网络后点击“重新加载登录页”。"
        }
    }

    private func navigationFinished(url: URL?) {
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        isLoading = false
        currentURL = url
        captureError = nil
        if autoSyncWhenAuthenticated && appearsLoggedIn {
            autoSyncWhenAuthenticated = false
            startAutoCapture()
        }
    }

    private func navigationFailed(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorCancelled {
            return
        }
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        isLoading = false
        captureError = "X 页面加载失败：\(error.localizedDescription)（\(nsError.code)）"
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
              let url = navigationAction.request.url
        else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased()
        let isAllowed = scheme == "https"
            || scheme == "about"
            || scheme == "data"
        decisionHandler(isAllowed ? .allow : .cancel)
        if !isAllowed {
            Task { @MainActor [weak self] in
                self?.captureError = "内置浏览器阻止了不安全的非 HTTPS 跳转。"
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation?
    ) {
        Task { @MainActor [weak self] in
            self?.navigationStarted(url: webView.url)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didCommit navigation: WKNavigation?
    ) {
        Task { @MainActor [weak self] in
            self?.currentURL = webView.url
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation?
    ) {
        Task { @MainActor [weak self] in
            self?.navigationFinished(url: webView.url)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.navigationFailed(error)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.navigationFailed(error)
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(
        _ webView: WKWebView
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            navigationTimeoutTask?.cancel()
            isLoading = false
            captureError = "X 浏览器进程已被 iOS 终止，请点击“重新加载登录页”。"
        }
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(
            userContentController,
            didReceive: message
        )
    }
}
