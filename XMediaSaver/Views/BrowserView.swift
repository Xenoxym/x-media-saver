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
            .navigationTitle("X 浏览器")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                session.browserDidAppear()
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
        VStack(spacing: 7) {
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

            HStack(spacing: 10) {
                Label(
                    "\(session.capturedPosts.count)",
                    systemImage: "tray.full"
                )
                .font(.caption.weight(.semibold).monospacedDigit())

                if session.sizeAnalysisRemaining > 0 {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("大小 \(session.sizeAnalysisRemaining)")
                            .font(.caption2.monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                }

                if let status = session.syncStatusText {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer()
                }

                Button {
                    if session.isAutoCapturing {
                        session.stopAutoCapture()
                    } else {
                        session.startAutoCapture()
                    }
                } label: {
                    Label(
                        session.isAutoCapturing ? "停止" : "同步书签",
                        systemImage: session.isAutoCapturing
                            ? "stop.fill"
                            : "arrow.down.to.line"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

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
        .padding(.horizontal)
        .padding(.vertical, 8)
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
