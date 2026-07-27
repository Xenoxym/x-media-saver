import SwiftUI

struct ContentView: View {
    @StateObject private var browserSession = BrowserSessionModel()
    @StateObject private var bookmarksViewModel = BookmarksViewModel()

    var body: some View {
        TabView {
            SingleDownloadView(session: browserSession)
                .tabItem {
                    Label("单个", systemImage: "link")
                }

            BookmarksView(
                session: browserSession,
                viewModel: bookmarksViewModel
            )
            .tabItem {
                Label("书签", systemImage: "bookmark")
            }

            BrowserView(session: browserSession)
                .tabItem {
                    Label("X 浏览器", systemImage: "globe")
                }
        }
    }
}

#Preview {
    ContentView()
}
