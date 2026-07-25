import Combine
import Foundation

@MainActor
final class SaverViewModel: ObservableObject {
    @Published var postURL = ""
    @Published private(set) var post: PostMedia?
    @Published var selectedItemID: String?
    @Published var selectedVariantID: String?
    @Published private(set) var isResolving = false
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var successMessage: String?
    @Published var presentedError: PresentedError?

    private let metadataService: SyndicationService
    private let downloadClient: DownloadClient
    private let photoSaver: PhotoLibrarySaver

    init(
        metadataService: SyndicationService = SyndicationService(),
        downloadClient: DownloadClient = DownloadClient(),
        photoSaver: PhotoLibrarySaver = PhotoLibrarySaver()
    ) {
        self.metadataService = metadataService
        self.downloadClient = downloadClient
        self.photoSaver = photoSaver
    }

    var selectedItem: VideoMediaItem? {
        guard let post else { return nil }
        return post.items.first(where: { $0.id == selectedItemID })
            ?? post.items.first
    }

    var selectedVariant: VideoVariant? {
        guard let selectedItem else { return nil }
        return selectedItem.variants.first(where: { $0.id == selectedVariantID })
            ?? selectedItem.bestVariant
    }

    var canResolve: Bool {
        !postURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isResolving
            && !isDownloading
    }

    func resolve(browserPost: BookmarkedPost? = nil) async {
        successMessage = nil
        post = nil
        isResolving = true
        defer { isResolving = false }

        do {
            let id = try PostURLParser.postID(from: postURL)
            let resolved: PostMedia
            if let browserPost,
               browserPost.id == id,
               let captured = Self.postMedia(from: browserPost) {
                resolved = captured
            } else {
                resolved = try await metadataService.resolve(postID: id)
            }
            post = resolved
            selectedItemID = resolved.items.first?.id
            selectedVariantID = resolved.items.first?.bestVariant?.id
        } catch {
            show(error)
        }
    }

    func selectItem(_ id: String?) {
        selectedItemID = id
        selectedVariantID = selectedItem?.bestVariant?.id
    }

    func downloadAndSave() async {
        guard let variant = selectedVariant else { return }
        successMessage = nil
        isDownloading = true
        downloadProgress = 0
        defer {
            isDownloading = false
            downloadProgress = 0
        }

        var localURL: URL?
        do {
            try await photoSaver.requestAddPermission()
            localURL = try await downloadClient.download(from: variant.url) {
                [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                }
            }
            guard let localURL else {
                throw AppError.downloadFailed
            }
            try await photoSaver.saveVideo(at: localURL)
            try? FileManager.default.removeItem(at: localURL)
            successMessage = "已保存到照片。"
        } catch is CancellationError {
            if let localURL {
                try? FileManager.default.removeItem(at: localURL)
            }
        } catch {
            if let localURL {
                try? FileManager.default.removeItem(at: localURL)
            }
            show(error)
        }
    }

    func cancelDownload() {
        downloadClient.cancel()
    }

    func clear() {
        postURL = ""
        post = nil
        selectedItemID = nil
        selectedVariantID = nil
        successMessage = nil
    }

    private func show(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        presentedError = PresentedError(
            message: message,
            offersSettings: (error as? AppError) == .photoPermissionDenied
        )
    }

    private static func postMedia(
        from post: BookmarkedPost
    ) -> PostMedia? {
        let items = post.media.compactMap { media -> VideoMediaItem? in
            guard media.type != .photo else { return nil }
            let variants = media.variants
                .filter { $0.contentType.lowercased() == "video/mp4" }
                .map {
                    VideoVariant(url: $0.url, bitrate: $0.bitRate)
                }
            guard !variants.isEmpty else { return nil }
            return VideoMediaItem(
                id: media.id,
                kind: media.type == .animatedGIF ? .animatedGIF : .video,
                durationMilliseconds: media.durationMilliseconds,
                variants: variants
            )
        }
        guard !items.isEmpty else { return nil }
        return PostMedia(
            postID: post.id,
            authorName: post.authorName,
            authorHandle: post.authorUsername,
            text: post.text,
            items: items,
            cameFromQuotedPost: false
        )
    }
}

struct PresentedError: Identifiable {
    let id = UUID()
    let message: String
    let offersSettings: Bool
}
