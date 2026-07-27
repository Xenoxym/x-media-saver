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
    case browserUnavailable
    case browserCaptureFailed(String)
    case notLoggedIn
    case noMediaSelected

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "请粘贴有效的 x.com 或 twitter.com 帖子地址。"
        case .unsupportedOrUnavailablePost:
            return "当前 X 会话和快捷解析都无法读取这条帖子。请确认登录仍有效，并且该账号有权访问。"
        case .noVideo:
            return "没有找到可下载的图片、MP4 视频或动图。"
        case .metadataServiceChanged:
            return "X 的快捷解析格式已经变化或暂时不可用。你可以改用内置浏览器打开帖子。"
        case .httpError(let code):
            return "The server returned HTTP \(code). Please try again later."
        case .downloadFailed:
            return "媒体下载没有完成。"
        case .photoPermissionDenied:
            return "Photos access is off. Allow “Add Photos Only” access in Settings, then try again."
        case .photoLibraryUnavailable:
            return "The Photos library is unavailable on this device."
        case .saveFailed(let message):
            return "照片图库无法保存媒体：\(message)"
        case .browserUnavailable:
            return "内置 X 浏览器当前不可用。"
        case .browserCaptureFailed(let message):
            return "无法解析 X 浏览器会话已经加载的数据：\(message)"
        case .notLoggedIn:
            return "请先在“X 浏览器”标签登录账号，然后返回重试。"
        case .noMediaSelected:
            return "请至少选择一种媒体类型。"
        }
    }
}
