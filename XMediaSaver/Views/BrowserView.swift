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
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                session.browserDidAppear()
            }
            .onDisappear {
                session.browserDidDisappear()
            }
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
        VStack(spacing: 4) {
            HStack(spacing: 8) {
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
                    Image(systemName: "bookmark")
                }

                Label(
                    "\(session.capturedPosts.count)",
                    systemImage: "tray.full"
                )
                .font(.caption.weight(.semibold).monospacedDigit())

                Spacer(minLength: 0)

                if session.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    if session.isAutoCapturing {
                        session.stopAutoCapture()
                    } else {
                        session.startAutoCapture()
                    }
                } label: {
                    Label(
                        session.isAutoCapturing ? "停止" : "同步",
                        systemImage: session.isAutoCapturing
                            ? "stop.fill"
                            : "arrow.down.to.line"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel(
                    session.isAutoCapturing ? "停止滚动" : "同步书签"
                )

                Menu {
                    if let status = session.syncStatusText {
                        Text(status)
                    }
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

            if let error = session.captureError {
                HStack {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer()
                    Button("重试") {
                        session.retryBrowserLogin()
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

private struct BrowserWebView: UIViewRepresentable {
    @ObservedObject var session: BrowserSessionModel

    func makeUIView(context: Context) -> WKWebView {
        return session.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
    }

    static func dismantleUIView(
        _ webView: WKWebView,
        coordinator: ()
    ) {}
}
