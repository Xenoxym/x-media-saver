import SwiftUI

struct SettingsView: View {
    @ObservedObject var session: BrowserSessionModel
    @AppStorage(AppLanguage.storageKey)
    private var languageRawValue = AppLanguage.system.rawValue
    @AppStorage("postVideoBackgroundPlaybackEnabled")
    private var backgroundPlaybackEnabled = false
    @AppStorage("bookmarkPostPreviewMode")
    private var previewModeRaw = BookmarkPostPreviewMode.media.rawValue
    @State private var showsStorageManagement = false

    private var selectedLanguage: Binding<AppLanguage> {
        Binding(
            get: {
                AppLanguage(rawValue: languageRawValue) ?? .system
            },
            set: { languageRawValue = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("App Language", selection: selectedLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(LocalizedStringKey(language.titleKey))
                                .tag(language)
                        }
                    }
                } header: {
                    Label("Language", systemImage: "character.bubble")
                } footer: {
                    Text(
                        "Follow System uses Chinese for Chinese system languages and English for every other language."
                    )
                }

                Section {
                    Button {
                        showsStorageManagement = true
                    } label: {
                        Label(
                            "Storage Management",
                            systemImage: "internaldrive"
                        )
                    }
                } header: {
                    Label(
                        "Storage & Cache",
                        systemImage: "externaldrive"
                    )
                } footer: {
                    Text(
                        "Clear temporary and WebKit caches while keeping the X login, or separately manage the local bookmark index and Files library."
                    )
                }

                Section {
                    Toggle(
                        "Background Audio",
                        isOn: $backgroundPlaybackEnabled
                    )
                } header: {
                    Label("Playback", systemImage: "play.circle")
                } footer: {
                    Text(
                        "When enabled, audible video may continue as audio after the app leaves the foreground. Picture in Picture still starts only when you choose it."
                    )
                }

                Section {
                    Picker(
                        "Default Post Preview",
                        selection: $previewModeRaw
                    ) {
                        Text("Media").tag(
                            BookmarkPostPreviewMode.media.rawValue
                        )
                        Text("Text Only").tag(
                            BookmarkPostPreviewMode.text.rawValue
                        )
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Label("Browsing", systemImage: "rectangle.grid.1x2")
                } footer: {
                    Text(
                        "This controls the initial style used by indexed Post lists. You can still change it from the list toolbar."
                    )
                }

                Section {
                    LabeledContent("Version") {
                        Text(versionText)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Link(
                        destination: URL(
                            string: "https://github.com/Xenoxym/x-media-saver"
                        )!
                    ) {
                        Label("Project on GitHub", systemImage: "link")
                    }

                    Text(
                        "X login and captured bookmark data stay on this device. The app has no custom backend and does not export browser cookies."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } header: {
                    Label("About", systemImage: "info.circle")
                }
            }
            .navigationTitle("Settings")
        }
        .sheet(isPresented: $showsStorageManagement) {
            StorageManagementView(session: session)
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "—"
        return "\(version) (\(build))"
    }
}
