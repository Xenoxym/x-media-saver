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
    @Published private(set) var syncNewPostCount = 0
    @Published private(set) var syncStatusText: String?
    @Published private(set) var sizeAnalysisRemaining = 0
    @Published private(set) var lastCaptureAt: Date?
    @Published private(set) var captureError: String?

    private(set) var webView: WKWebView!
    private var postsByID: [String: BookmarkedPost] = [:]
    private var allPostsByID: [String: BookmarkedPost] = [:]
    private var postOrder: [String] = []
    private var syncBookmarkPageOrders: [Int: [String]] = [:]
    private var autoCaptureTask: Task<Void, Never>?
    private var navigationTimeoutTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var messageHandlerProxy: WeakScriptMessageHandler?
    private let persistenceStore = BookmarkPersistenceStore()
    private let sizeResolver = MediaSizeResolver()
    private let storageManager = StorageManager()
    private var bookmarkResponseSequence = 0
    private var sizeProbeTask: Task<Void, Never>?
    private var pendingSizeProbes: [SizeProbeRequest] = []
    private var sizeProbeKeys: Set<String> = []

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
                self.captureError = L10n.format(
                    "无法读取本地书签索引：%@",
                    error.localizedDescription
                )
            }
        }
        Task {
            await self.storageManager.clearTemporaryAndURLCache()
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
            captureError = L10n.string("只允许在内置浏览器中打开 x.com。")
            return
        }
        captureError = nil
        webView.load(URLRequest(url: url))
    }

    func prepareBrowser() {
        guard webView.url == nil, !isLoading else { return }
        load(URL(string: "https://x.com/home")!)
    }

    func browserDidAppear() {
        prepareBrowser()
    }

    func browserDidDisappear() {
        if isAutoCapturing {
            stopAutoCapture()
        }
    }

    func retryBrowserLogin() {
        navigationTimeoutTask?.cancel()
        webView.stopLoading()
        isLoading = false
        currentURL = nil
        captureError = nil
        load(URL(string: "https://x.com/home")!)
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
        sizeProbeTask?.cancel()
        sizeProbeTask = nil
        pendingSizeProbes = []
        sizeProbeKeys = []
        capturedPosts = []
        postsByID = [:]
        allPostsByID = [:]
        postOrder = []
        syncBookmarkPageOrders = [:]
        syncPageCount = 0
        syncNewPostCount = 0
        syncStatusText = nil
        sizeAnalysisRemaining = 0
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
        webView.load(URLRequest(url: URL(string: "https://x.com/home")!))
    }

    func startAutoCapture() {
        guard !isAutoCapturing else { return }

        captureError = nil
        isAutoCapturing = true
        syncPageCount = 0
        syncNewPostCount = 0
        syncBookmarkPageOrders = [:]
        syncStatusText = L10n.string("正在打开书签页面…")
        autoCaptureTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isAutoCapturing = false
                autoCaptureTask = nil
                if Task.isCancelled {
                    syncStatusText = L10n.string("同步已停止")
                } else if captureError == nil {
                    syncStatusText = L10n.string("本轮同步完成")
                }
            }

            openBookmarks()
            for _ in 0..<80 {
                guard !Task.isCancelled else { return }
                if isOnBookmarksPage && !isLoading {
                    break
                }
                if currentURL?.path.lowercased().contains("/login") == true
                    || currentURL?.path.lowercased().contains("/i/flow/login") == true {
                    captureError = L10n.string(
                        "登录会话已失效，请先到“X 浏览器”重新登录。"
                    )
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            guard isOnBookmarksPage else {
                captureError = L10n.string(
                    "无法打开书签页面，请先到“X 浏览器”确认登录状态。"
                )
                return
            }

            syncStatusText = L10n.string("正在快速增量同步…")
            var idleRounds = 0
            var observedSequence = bookmarkResponseSequence

            for _ in 0..<800 {
                guard !Task.isCancelled else { break }

                do {
                    _ = try await webView.evaluateJavaScript(
                        "window.scrollTo(0, Math.max(document.body.scrollHeight, document.documentElement.scrollHeight));"
                    )
                } catch {
                    captureError = error.localizedDescription
                    break
                }

                try? await Task.sleep(nanoseconds: 950_000_000)
                let currentSequence = bookmarkResponseSequence
                if currentSequence > observedSequence {
                    let received = currentSequence - observedSequence
                    observedSequence = currentSequence
                    idleRounds = 0
                    syncPageCount += received
                    syncStatusText = L10n.format(
                        "已读取 %lld 页，新增 %lld 条，总计 %lld 条",
                        syncPageCount,
                        syncNewPostCount,
                        capturedPosts.count
                    )
                } else {
                    idleRounds += 1
                    if idleRounds >= 2 {
                        syncStatusText = L10n.format(
                            "等待下一页（%lld/6），新增 %lld 条…",
                            idleRounds,
                            syncNewPostCount
                        )
                    }
                }

                if idleRounds >= 6 {
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

    func analyzeMissingMediaSizes(retryUnavailable: Bool = false) {
        enqueueSizeProbes(
            for: capturedPosts,
            retryUnavailable: retryUnavailable
        )
    }

    func clearCachesKeepingLogin() async {
        await storageManager.clearTemporaryAndURLCache()
        let cacheTypes: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
            WKWebsiteDataTypeFetchCache
        ]
        let dataStore = WKWebsiteDataStore.default()
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            dataStore.fetchDataRecords(ofTypes: cacheTypes) { records in
                let xRecords = records.filter {
                    let name = $0.displayName.lowercased()
                    return name.contains("x.com")
                        || name.contains("twitter.com")
                        || name.contains("twimg.com")
                }
                dataStore.removeData(
                    ofTypes: cacheTypes,
                    for: xRecords
                ) {
                    continuation.resume()
                }
            }
        }
        syncStatusText = L10n.string("缓存已清理，X 登录会话已保留")
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
            captureError = L10n.string("单个浏览器响应过大，已跳过。")
            return
        }

        let isBookmarkCapture = url.contains("Bookmarks")
            || url.contains("BookmarkFolderTimeline")
        let bookmarkSequence: Int?
        if isBookmarkCapture {
            bookmarkResponseSequence += 1
            bookmarkSequence = bookmarkResponseSequence
        } else {
            bookmarkSequence = nil
        }

        Task {
            do {
                let capture = try await Task.detached(priority: .utility) {
                    try BrowserCaptureParser.parse(
                        data: Data(body.utf8),
                        sourceURL: url
                    )
                }.value
                let newCount = merge(
                    capture.posts,
                    isBookmarkCapture: isBookmarkCapture,
                    bookmarkSequence: bookmarkSequence
                )
                if isBookmarkCapture {
                    syncNewPostCount += newCount
                    let mergedPosts = Self.sizeProbePosts(
                        received: capture.posts,
                        indexed: allPostsByID
                    )
                    enqueueSizeProbes(
                        for: mergedPosts,
                        retryUnavailable: false
                    )
                }
                lastCaptureAt = Date()
                captureError = nil
            } catch {
                captureError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    nonisolated static func sizeProbePosts(
        received: [BookmarkedPost],
        indexed: [String: BookmarkedPost]
    ) -> [BookmarkedPost] {
        received.compactMap { indexed[$0.id] }
    }

    @discardableResult
    private func merge(
        _ posts: [BookmarkedPost],
        isBookmarkCapture: Bool,
        bookmarkSequence: Int?
    ) -> Int {
        let pageIDs = posts.map(\.id)
        var seenNewIDs: Set<String> = []
        let newIDs = isBookmarkCapture
            ? pageIDs.filter {
                postsByID[$0] == nil && seenNewIDs.insert($0).inserted
            }
            : []
        for post in posts {
            let mergedPost = preservingLocalMetadata(
                incoming: post,
                existing: allPostsByID[post.id]
            )
            allPostsByID[post.id] = mergedPost
            if isBookmarkCapture {
                postsByID[post.id] = mergedPost
            }
        }
        if isBookmarkCapture {
            mergeBookmarkOrder(
                pageIDs: pageIDs,
                newIDs: newIDs,
                bookmarkSequence: bookmarkSequence
            )
        }
        capturedPosts = postOrder.compactMap { postsByID[$0] }
        if isBookmarkCapture {
            schedulePersistence()
        }
        return newIDs.count
    }

    private func mergeBookmarkOrder(
        pageIDs: [String],
        newIDs: [String],
        bookmarkSequence: Int?
    ) {
        let uniqueNewIDs = newIDs.reduce(into: [String]()) {
            if !$0.contains($1) && !postOrder.contains($1) {
                $0.append($1)
            }
        }

        if isAutoCapturing, let bookmarkSequence {
            syncBookmarkPageOrders[bookmarkSequence] = pageIDs
            var observed: [String] = []
            var observedSet: Set<String> = []
            for sequence in syncBookmarkPageOrders.keys.sorted() {
                for id in syncBookmarkPageOrders[sequence] ?? []
                    where observedSet.insert(id).inserted {
                    observed.append(id)
                }
            }
            postOrder = observed + postOrder.filter {
                !observedSet.contains($0)
            }
            return
        }

        guard !uniqueNewIDs.isEmpty else { return }
        if isAutoCapturing || postOrder.isEmpty {
            postOrder.append(contentsOf: uniqueNewIDs)
            return
        }

        let newIDSet = Set(uniqueNewIDs)
        if let anchorID = pageIDs.first(where: {
            !newIDSet.contains($0) && postOrder.contains($0)
        }),
           let anchorIndex = postOrder.firstIndex(of: anchorID) {
            postOrder.insert(contentsOf: uniqueNewIDs, at: anchorIndex)
        } else {
            postOrder.insert(contentsOf: uniqueNewIDs, at: 0)
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
                self.captureError = L10n.format(
                    "无法保存本地书签索引：%@",
                    error.localizedDescription
                )
            }
        }
    }

    private func preservingLocalMetadata(
        incoming: BookmarkedPost,
        existing: BookmarkedPost?
    ) -> BookmarkedPost {
        guard let existing else { return incoming }
        let oldMedia = Dictionary(
            uniqueKeysWithValues: existing.media.map { ($0.mediaKey, $0) }
        )
        let media = incoming.media.map { item in
            guard let old = oldMedia[item.mediaKey],
                  item.byteSize == nil
            else {
                return item
            }
            return BookmarkedMedia(
                mediaKey: item.mediaKey,
                type: item.type,
                url: item.url,
                previewImageURL: item.previewImageURL,
                variants: item.variants,
                width: item.width,
                height: item.height,
                durationMilliseconds: item.durationMilliseconds,
                byteSize: old.byteSize,
                sizeProbeCompleted: old.sizeProbeCompleted
            )
        }
        return BookmarkedPost(
            id: incoming.id,
            text: incoming.text,
            createdAt: incoming.createdAt,
            authorID: incoming.authorID,
            authorName: incoming.authorName,
            authorUsername: incoming.authorUsername,
            media: media
        )
    }

    private func enqueueSizeProbes(
        for posts: [BookmarkedPost],
        retryUnavailable: Bool
    ) {
        for post in posts {
            for media in post.media {
                let needsProbe = media.byteSize == nil
                    && (retryUnavailable
                        || media.sizeProbeCompleted != true)
                guard needsProbe,
                      let url = media.downloadURL,
                      sizeProbeKeys.insert(media.mediaKey).inserted
                else {
                    continue
                }
                pendingSizeProbes.append(
                    SizeProbeRequest(
                        postID: post.id,
                        mediaKey: media.mediaKey,
                        url: url
                    )
                )
            }
        }
        sizeAnalysisRemaining = pendingSizeProbes.count
        startSizeProbeWorkerIfNeeded()
    }

    private func startSizeProbeWorkerIfNeeded() {
        guard sizeProbeTask == nil, !pendingSizeProbes.isEmpty else { return }
        sizeProbeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                sizeProbeTask = nil
                sizeAnalysisRemaining = pendingSizeProbes.count
                if !pendingSizeProbes.isEmpty {
                    startSizeProbeWorkerIfNeeded()
                }
            }
            while !pendingSizeProbes.isEmpty {
                guard !Task.isCancelled else { return }
                let request = pendingSizeProbes.removeFirst()
                sizeAnalysisRemaining = pendingSizeProbes.count + 1
                let size = await sizeResolver.resolve(request.url)
                applyResolvedSize(
                    size,
                    postID: request.postID,
                    mediaKey: request.mediaKey
                )
                sizeProbeKeys.remove(request.mediaKey)
                sizeAnalysisRemaining = pendingSizeProbes.count
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    private func applyResolvedSize(
        _ byteSize: Int64?,
        postID: String,
        mediaKey: String
    ) {
        guard let post = postsByID[postID] else { return }
        let media = post.media.map { item in
            guard item.mediaKey == mediaKey else { return item }
            return BookmarkedMedia(
                mediaKey: item.mediaKey,
                type: item.type,
                url: item.url,
                previewImageURL: item.previewImageURL,
                variants: item.variants,
                width: item.width,
                height: item.height,
                durationMilliseconds: item.durationMilliseconds,
                byteSize: byteSize,
                sizeProbeCompleted: true
            )
        }
        let updated = BookmarkedPost(
            id: post.id,
            text: post.text,
            createdAt: post.createdAt,
            authorID: post.authorID,
            authorName: post.authorName,
            authorUsername: post.authorUsername,
            media: media
        )
        postsByID[postID] = updated
        allPostsByID[postID] = updated
        capturedPosts = postOrder.compactMap { postsByID[$0] }
        schedulePersistence()
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
            captureError = L10n.string(
                "X 页面加载超过 30 秒。请检查网络后点击“重新加载登录页”。"
            )
        }
    }

    private func navigationFinished(url: URL?) {
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        isLoading = false
        currentURL = url
        captureError = nil
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
        captureError = L10n.format(
            "X 页面加载失败：%@（%lld）",
            error.localizedDescription,
            nsError.code
        )
    }
}

private struct SizeProbeRequest {
    let postID: String
    let mediaKey: String
    let url: URL
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
                self?.captureError = L10n.string(
                    "内置浏览器阻止了不安全的非 HTTPS 跳转。"
                )
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
            captureError = L10n.string(
                "X 浏览器进程已被 iOS 终止，请点击“重新加载登录页”。"
            )
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
