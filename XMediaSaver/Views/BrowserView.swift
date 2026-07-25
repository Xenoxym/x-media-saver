import SwiftUI
import WebKit

struct BrowserView: View {
    @ObservedObject var session: BrowserSessionModel
    @State private var confirmLogout = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                BrowserWebView(session: session)
                Divider()
                captureStatus
            }
            .navigationTitle("X 浏览器")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "退出并清除 X 浏览器数据？",
                isPresented: $confirmLogout,
                titleVisibility: .visible
            ) {
                Button("退出并清除", role: .destructive) {
                    Task { await session.clearBrowserSession() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会删除内置浏览器中的 X Cookie 和网站存储，不影响 Safari。")
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button {
                session.goBack()
            } label: {
                Image(systemName: "chevron.backward")
            }

            Button {
                session.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }

            Button {
                session.openBookmarks()
            } label: {
                Label("书签", systemImage: "bookmark")
            }

            Spacer()

            if session.isLoading {
                ProgressView()
            }

            Menu {
                Button("清空已抓取列表") {
                    session.clearCapturedData()
                }
                Button("退出 X", role: .destructive) {
                    confirmLogout = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var captureStatus: some View {
        VStack(spacing: 6) {
            HStack {
                Label(
                    "已捕获 \(session.capturedPosts.count) 条",
                    systemImage: "tray.full"
                )
                .font(.caption.weight(.semibold))

                Spacer()

                if session.isAutoCapturing {
                    Button("停止滚动") {
                        session.stopAutoCapture()
                    }
                    .font(.caption)
                } else {
                    Button("自动滚动抓取") {
                        session.startAutoCapture()
                    }
                    .font(.caption)
                    .disabled(!session.isOnBookmarksPage)
                }
            }

            if let error = session.captureError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(
                    "账号密码只输入到 X 网页。APP 不读取密码或导出 Cookie，只解析此页面已加载的书签响应。"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct BrowserWebView: UIViewRepresentable {
    @ObservedObject var session: BrowserSessionModel

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.addUserScript(
            WKUserScript(
                source: BrowserCaptureScript.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        controller.add(session, name: "xMediaCapture")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = session
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive
        session.attach(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(
        _ webView: WKWebView,
        coordinator: ()
    ) {
        if let session = webView.navigationDelegate as? BrowserSessionModel {
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: "xMediaCapture"
            )
            session.detach(webView)
        }
        webView.navigationDelegate = nil
    }
}
