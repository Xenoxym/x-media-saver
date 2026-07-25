import Foundation

enum AppError: LocalizedError, Equatable {
    case invalidURL
    case unsupportedOrUnavailablePost
    case noVideo
    case metadataServiceChanged
    case httpError(Int)
    case downloadFailed
    case photoPermissionDenied
    case photoLibraryUnavailable
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Paste a valid public x.com or twitter.com post URL."
        case .unsupportedOrUnavailablePost:
            return "This post is unavailable to X’s public embed service. It may be private, deleted, age-restricted, region-restricted, login-gated, or unsupported."
        case .noVideo:
            return "No downloadable MP4 video or GIF variant was found in this post."
        case .metadataServiceChanged:
            return "X’s public embed response changed or is temporarily unavailable. This app does not bypass login or use a third-party server."
        case .httpError(let code):
            return "The server returned HTTP \(code). Please try again later."
        case .downloadFailed:
            return "The video download did not complete."
        case .photoPermissionDenied:
            return "Photos access is off. Allow “Add Photos Only” access in Settings, then try again."
        case .photoLibraryUnavailable:
            return "The Photos library is unavailable on this device."
        case .saveFailed(let message):
            return "Photos could not save the video: \(message)"
        }
    }
}
