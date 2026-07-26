import AVFoundation
import ImageIO
import SwiftUI
import UIKit

struct LocalMediaThumbnailView: View {
    let media: BookmarkedMedia
    var maximumPixelSize: Int = 600
    var contentMode: ContentMode = .fill
    var remoteImageName = "small"
    @StateObject private var loader = LocalMediaThumbnailLoader()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = loader.image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else if loader.failed {
                    Color(uiColor: .tertiarySystemGroupedBackground)
                        .overlay {
                            Image(systemName: "photo.badge.exclamationmark")
                                .foregroundStyle(.secondary)
                        }
                } else {
                    Color(uiColor: .tertiarySystemGroupedBackground)
                        .overlay { ProgressView() }
                }
            }

            if loader.isLocal {
                Image(systemName: "iphone")
                    .font(.caption2.weight(.bold))
                    .padding(5)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(5)
            }

            if media.type != .photo {
                Image(systemName: "play.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.55), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipped()
        .task(id: "\(media.mediaKey)-\(maximumPixelSize)-\(remoteImageName)") {
            await loader.load(
                media: media,
                maximumPixelSize: maximumPixelSize,
                remoteImageName: remoteImageName
            )
        }
    }
}

@MainActor
private final class LocalMediaThumbnailLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLocal = false
    @Published private(set) var failed = false

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 240
        cache.totalCostLimit = 80 * 1_048_576
        return cache
    }()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    func load(
        media: BookmarkedMedia,
        maximumPixelSize: Int,
        remoteImageName: String
    ) async {
        let key = "\(media.mediaKey)-\(maximumPixelSize)-\(remoteImageName)"
            as NSString
        if let cached = Self.cache.object(forKey: key) {
            image = cached
            isLocal = await LocalMediaLibrary.shared.localURL(
                for: media.mediaKey
            ) != nil
            return
        }

        failed = false
        let localURL = await LocalMediaLibrary.shared.localURL(
            for: media.mediaKey
        )
        let result: UIImage?
        if let localURL {
            isLocal = true
            result = await Task.detached(priority: .utility) {
                if media.type == .photo {
                    return Self.downsample(
                        fileURL: localURL,
                        maximumPixelSize: maximumPixelSize
                    )
                }
                return Self.videoFrame(
                    url: localURL,
                    maximumPixelSize: maximumPixelSize
                )
            }.value
        } else if let previewURL = Self.previewURL(
            media.previewImageURL ?? media.url,
            name: remoteImageName
        ) {
            isLocal = false
            do {
                let (data, response) = try await Self.session.data(
                    from: previewURL
                )
                guard let response = response as? HTTPURLResponse,
                      (200...299).contains(response.statusCode)
                else {
                    result = nil
                    failed = true
                    return
                }
                result = await Task.detached(priority: .utility) {
                    Self.downsample(
                        data: data,
                        maximumPixelSize: maximumPixelSize
                    )
                }.value
            } catch {
                result = nil
            }
        } else {
            result = nil
        }

        guard !Task.isCancelled else { return }
        if let result {
            let cost = max(
                1,
                Int(result.size.width * result.size.height * 4)
            )
            Self.cache.setObject(result, forKey: key, cost: cost)
            image = result
        } else {
            failed = true
        }
    }

    nonisolated private static func previewURL(
        _ url: URL?,
        name: String
    ) -> URL? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == "pbs.twimg.com"
        else {
            return url
        }
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    nonisolated private static func downsample(
        fileURL: URL,
        maximumPixelSize: Int
    ) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(
            fileURL as CFURL,
            nil
        ) else {
            return nil
        }
        return thumbnail(
            source: source,
            maximumPixelSize: maximumPixelSize
        )
    }

    nonisolated private static func downsample(
        data: Data,
        maximumPixelSize: Int
    ) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            nil
        ) else {
            return nil
        }
        return thumbnail(
            source: source,
            maximumPixelSize: maximumPixelSize
        )
    }

    nonisolated private static func thumbnail(
        source: CGImageSource,
        maximumPixelSize: Int
    ) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    nonisolated private static func videoFrame(
        url: URL,
        maximumPixelSize: Int
    ) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: maximumPixelSize,
            height: maximumPixelSize
        )
        guard let image = try? generator.copyCGImage(
            at: CMTime(seconds: 0.2, preferredTimescale: 600),
            actualTime: nil
        ) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}
