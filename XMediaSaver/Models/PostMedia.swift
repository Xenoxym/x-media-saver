import Foundation

struct PostMedia: Equatable {
    let postID: String
    let authorName: String?
    let authorHandle: String?
    let text: String?
    let items: [VideoMediaItem]
    let cameFromQuotedPost: Bool
}

struct VideoMediaItem: Identifiable, Equatable {
    let id: String
    let kind: MediaKind
    let durationMilliseconds: Int?
    let variants: [VideoVariant]

    var bestVariant: VideoVariant? {
        variants.sorted(by: VideoVariant.isHigherQuality).first
    }
}

enum MediaKind: String, Equatable {
    case video
    case animatedGIF = "animated_gif"
    case unknown

    var displayName: String {
        switch self {
        case .video: return "Video"
        case .animatedGIF: return "GIF (MP4)"
        case .unknown: return "Video"
        }
    }
}

struct VideoVariant: Identifiable, Hashable {
    let url: URL
    let bitrate: Int?

    var id: String { url.absoluteString }

    var resolution: String? {
        let path = url.path
        guard let regex = try? NSRegularExpression(pattern: #"/(\d{2,5})x(\d{2,5})/"#),
              let match = regex.firstMatch(
                in: path,
                range: NSRange(path.startIndex..., in: path)
              ),
              let widthRange = Range(match.range(at: 1), in: path),
              let heightRange = Range(match.range(at: 2), in: path)
        else {
            return nil
        }
        return "\(path[widthRange])×\(path[heightRange])"
    }

    var qualityLabel: String {
        var components: [String] = []
        if let resolution {
            components.append(resolution)
        }
        if let bitrate {
            let mbps = Double(bitrate) / 1_000_000
            components.append(String(format: "%.1f Mbps", mbps))
        }
        return components.isEmpty ? "MP4" : components.joined(separator: " · ")
    }

    static func isHigherQuality(_ lhs: VideoVariant, _ rhs: VideoVariant) -> Bool {
        (lhs.bitrate ?? -1) > (rhs.bitrate ?? -1)
    }
}
