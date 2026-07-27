import Foundation

struct BatchSaveProgress: Equatable {
    let completed: Int
    let total: Int
    let currentFraction: Double
    let currentType: BookmarkMediaType?
}

final class BatchMediaSaver: @unchecked Sendable {
    private let downloadClient: DownloadClient
    private let photoSaver: PhotoLibrarySaver

    init(
        downloadClient: DownloadClient = DownloadClient(),
        photoSaver: PhotoLibrarySaver = PhotoLibrarySaver()
    ) {
        self.downloadClient = downloadClient
        self.photoSaver = photoSaver
    }

    func save(
        _ mediaItems: [BookmarkedMedia],
        didSave: @escaping @Sendable (BookmarkedMedia, Int64) async -> Void,
        progress: @escaping @Sendable (BatchSaveProgress) -> Void
    ) async throws -> BatchSaveResult {
        guard !mediaItems.isEmpty else {
            throw AppError.noMediaSelected
        }

        try await photoSaver.requestAddPermission()
        var saved = 0
        var skipped = 0
        var failed = 0
        var issues: [String] = []

        for (index, media) in mediaItems.enumerated() {
            try Task.checkCancellation()
            let existingLocalURL = await LocalMediaLibrary.shared.localURL(
                for: media.mediaKey
            )
            guard existingLocalURL != nil || media.downloadURL != nil else {
                skipped += 1
                issues.append(
                    "\(media.type.title) \(media.mediaKey)：没有可下载的直接地址"
                )
                progress(
                    BatchSaveProgress(
                        completed: index + 1,
                        total: mediaItems.count,
                        currentFraction: 1,
                        currentType: media.type
                    )
                )
                continue
            }

            progress(
                BatchSaveProgress(
                    completed: index,
                    total: mediaItems.count,
                    currentFraction: 0,
                    currentType: media.type
                )
            )

            var localURL = existingLocalURL
            var removesLocalFileWhenFinished = false
            do {
                if localURL == nil {
                    guard let remoteURL = media.downloadURL else {
                        throw AppError.downloadFailed
                    }
                    localURL = try await downloadClient.download(
                        from: remoteURL,
                        fileExtension: Self.fileExtension(
                            for: media,
                            url: remoteURL
                        )
                    ) { fraction in
                        progress(
                            BatchSaveProgress(
                                completed: index,
                                total: mediaItems.count,
                                currentFraction: fraction,
                                currentType: media.type
                            )
                        )
                    }
                    removesLocalFileWhenFinished = true
                }
                guard let localURL else {
                    throw AppError.downloadFailed
                }

                switch media.type {
                case .photo:
                    try await photoSaver.saveImage(at: localURL)
                case .animatedGIF, .video:
                    try await photoSaver.saveVideo(at: localURL)
                }
                saved += 1
                let values = try? localURL.resourceValues(
                    forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]
                )
                let byteSize = Int64(
                    values?.fileSize ?? values?.totalFileAllocatedSize ?? 0
                )
                await didSave(media, byteSize)
                if removesLocalFileWhenFinished {
                    try? FileManager.default.removeItem(at: localURL)
                }
            } catch is CancellationError {
                if removesLocalFileWhenFinished, let localURL {
                    try? FileManager.default.removeItem(at: localURL)
                }
                throw CancellationError()
            } catch {
                if removesLocalFileWhenFinished, let localURL {
                    try? FileManager.default.removeItem(at: localURL)
                }
                failed += 1
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                issues.append(
                    "\(media.type.title) \(media.mediaKey)：\(message)"
                )
            }

            progress(
                BatchSaveProgress(
                    completed: index + 1,
                    total: mediaItems.count,
                    currentFraction: 1,
                    currentType: media.type
                )
            )
        }

        return BatchSaveResult(
            saved: saved,
            skipped: skipped,
            failed: failed,
            issues: issues
        )
    }

    func cancel() {
        downloadClient.cancel()
    }

    private static func fileExtension(
        for media: BookmarkedMedia,
        url: URL
    ) -> String {
        guard media.type == .photo else { return "mp4" }
        let value = url.pathExtension.lowercased()
        let supported = ["jpg", "jpeg", "png", "heic", "webp"]
        return supported.contains(value) ? value : "jpg"
    }
}
