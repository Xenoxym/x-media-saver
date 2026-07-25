import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = SaverViewModel()
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    urlCard
                    if viewModel.isResolving {
                        ProgressView("Checking public post…")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    if let post = viewModel.post {
                        resultCard(post)
                    }
                    privacyNote
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("X Media Saver")
            .toolbar {
                if viewModel.post != nil || !viewModel.postURL.isEmpty {
                    Button("Clear") {
                        viewModel.clear()
                    }
                    .disabled(viewModel.isDownloading)
                }
            }
        }
        .alert(item: $viewModel.presentedError) { error in
            if error.offersSettings {
                return Alert(
                    title: Text("Photos access needed"),
                    message: Text(error.message),
                    primaryButton: .default(Text("Open Settings")) {
                        guard let url = URL(
                            string: UIApplication.openSettingsURLString
                        ) else { return }
                        openURL(url)
                    },
                    secondaryButton: .cancel()
                )
            }
            return Alert(
                title: Text("Couldn’t complete that"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(.cyan, .purple)
                .symbolRenderingMode(.palette)
            Text("Save public X videos and GIFs")
                .font(.title2.bold())
            Text("The app contacts X directly. No account, cookies, or third-party download server.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }

    private var urlCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Public post URL")
                .font(.headline)

            TextField(
                "https://x.com/account/status/…",
                text: $viewModel.postURL,
                axis: .vertical
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .lineLimit(2...4)
            .textFieldStyle(.roundedBorder)

            HStack {
                Button {
                    if let value = UIPasteboard.general.string {
                        viewModel.postURL = value
                    }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    Task { await viewModel.resolve() }
                } label: {
                    if viewModel.isResolving {
                        ProgressView()
                    } else {
                        Label("Find Video", systemImage: "magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canResolve)
            }
        }
        .cardStyle()
    }

    private func resultCard(_ post: PostMedia) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Video found", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            if let name = post.authorName {
                Text(
                    post.authorHandle.map { "\(name)  @\($0)" } ?? name
                )
                .font(.subheadline.weight(.semibold))
            }
            if let text = post.text, !text.isEmpty {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if post.cameFromQuotedPost {
                Label(
                    "Using media attached to the quoted public post",
                    systemImage: "quote.bubble"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if post.items.count > 1 {
                Picker(
                    "Clip",
                    selection: Binding(
                        get: { viewModel.selectedItemID },
                        set: { viewModel.selectItem($0) }
                    )
                ) {
                    ForEach(Array(post.items.enumerated()), id: \.element.id) {
                        index, item in
                        Text("\(item.kind.displayName) \(index + 1)")
                            .tag(Optional(item.id))
                    }
                }
                .pickerStyle(.segmented)
            }

            if let item = viewModel.selectedItem {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("MP4 quality")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("Highest selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Quality", selection: $viewModel.selectedVariantID) {
                        ForEach(item.variants) { variant in
                            Text(variant.qualityLabel)
                                .tag(Optional(variant.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if viewModel.isDownloading {
                VStack(spacing: 10) {
                    ProgressView(value: viewModel.downloadProgress)
                    HStack {
                        Text(
                            viewModel.downloadProgress > 0
                                ? "\(Int(viewModel.downloadProgress * 100))%"
                                : "Starting download…"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel", role: .cancel) {
                            viewModel.cancelDownload()
                        }
                    }
                }
            } else {
                Button {
                    Task { await viewModel.downloadAndSave() }
                } label: {
                    Label("Download & Save to Photos", systemImage: "photo.badge.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if let success = viewModel.successMessage {
                Label(success, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .cardStyle()
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Public posts only", systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
            Text(
                "Private, deleted, age-gated, region-restricted, login-only, and otherwise access-restricted posts are intentionally unsupported. Only save media you have permission to keep."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding()
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

#Preview {
    ContentView()
}
