import Foundation

final class DownloadClient: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: (@Sendable (Double) -> Void)?
    private var activeTask: URLSessionDownloadTask?
    private var downloadedFileURL: URL?
    private var destinationExtension = "mp4"
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
    }()

    func download(
        from url: URL,
        fileExtension: String = "mp4",
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard continuation == nil else {
            throw AppError.downloadFailed
        }
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "video.twimg.com"
                || host == "pbs.twimg.com"
                || host.hasSuffix(".twimg.com")
        else {
            throw AppError.downloadFailed
        }
        destinationExtension = Self.safeExtension(fileExtension)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.progressHandler = progress
                var request = URLRequest(url: url)
                request.timeoutInterval = 60
                let task = session.downloadTask(with: request)
                activeTask = task
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        activeTask?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "video.twimg.com" || host.hasSuffix(".twimg.com")
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler?(
            min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200...299).contains(response.statusCode)
        else {
            return
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("XMediaSaver-\(UUID().uuidString)")
            .appendingPathExtension(destinationExtension)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            downloadedFileURL = destination
        } catch {
            finish(with: .failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                finish(with: .failure(CancellationError()))
            } else {
                finish(with: .failure(error))
            }
        } else if let downloadedFileURL {
            finish(with: .success(downloadedFileURL))
        } else if let response = task.response as? HTTPURLResponse {
            finish(with: .failure(AppError.httpError(response.statusCode)))
        } else {
            finish(with: .failure(AppError.downloadFailed))
        }
    }

    private func finish(with result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        progressHandler = nil
        activeTask = nil
        downloadedFileURL = nil
        destinationExtension = "mp4"

        switch result {
        case .success(let url):
            continuation.resume(returning: url)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private static func safeExtension(_ value: String) -> String {
        let normalized = value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return normalized.isEmpty ? "dat" : String(normalized.prefix(8))
    }
}
