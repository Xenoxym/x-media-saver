import Foundation
import Photos

struct PhotoLibrarySaver {
    func requestAddPermission() async throws {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let status: PHAuthorizationStatus
        if currentStatus == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        } else {
            status = currentStatus
        }

        switch status {
        case .authorized, .limited:
            return
        case .denied, .restricted:
            throw AppError.photoPermissionDenied
        case .notDetermined:
            throw AppError.photoLibraryUnavailable
        @unknown default:
            throw AppError.photoLibraryUnavailable
        }
    }

    func saveVideo(at fileURL: URL) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(
                    atFileURL: fileURL
                )
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: AppError.saveFailed(
                            error?.localizedDescription ?? "Unknown error"
                        )
                    )
                }
            }
        }
    }
}
