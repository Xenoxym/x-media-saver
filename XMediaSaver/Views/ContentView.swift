import SwiftUI

struct ContentView: View {
    private enum Tab: Hashable {
        case save
        case bookmarks
        case browser
        case settings
    }

    @StateObject private var browserSession = BrowserSessionModel()
    @StateObject private var bookmarksViewModel = BookmarksViewModel()
    @State private var selectedTab = Tab.save
    @State private var startsSyncWhenBrowserAppears = false
    @AppStorage(AppLanguage.storageKey)
    private var languageRawValue = AppLanguage.system.rawValue

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: languageRawValue) ?? .system
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            SingleDownloadView(session: browserSession)
                .tabItem {
                    Label("单个", systemImage: "link")
                }
                .tag(Tab.save)

            BookmarksView(
                session: browserSession,
                viewModel: bookmarksViewModel,
                onRequestVisibleSync: {
                    startsSyncWhenBrowserAppears = true
                    selectedTab = .browser
                }
            )
            .tabItem {
                Label("书签", systemImage: "bookmark")
            }
            .tag(Tab.bookmarks)

            BrowserView(
                session: browserSession,
                startsSyncOnAppear: $startsSyncWhenBrowserAppears
            )
                .tabItem {
                    Label("X 浏览器", systemImage: "globe")
                }
                .tag(Tab.browser)

            SettingsView(session: browserSession)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(Tab.settings)
        }
        .environment(\.locale, selectedLanguage.locale)
        .id(selectedLanguage.resolvedLanguageCode)
    }
}

#Preview {
    ContentView()
}
