import Combine
import Foundation

@MainActor
final class BookmarksViewModel: ObservableObject {
    @Published var filter = BookmarkFilter()
    @Published private(set) var isSaving = false
    @Published private(set) var progress = BatchSaveProgress(
        completed: 0,
        total: 0,
        currentFraction: 0,
        currentType: nil
    )
    @Published private(set) var result: BatchSaveResult?
    @Published var presentedError: PresentedError?

    private let saver: BatchMediaSaver
    private var saveTask: Task<Void, Never>?

    init(saver: BatchMediaSaver = BatchMediaSaver()) {
        self.saver = saver
    }

    func filteredPosts(from posts: [BookmarkedPost]) -> [BookmarkedPost] {
        posts.filter { filter.contains($0) }
    }

    func selectedMedia(from posts: [BookmarkedPost]) -> [BookmarkedMedia] {
        var seen: Set<String> = []
        return filteredPosts(from: posts)
            .flatMap { filter.media(in: $0) }
            .filter { seen.insert($0.mediaKey).inserted }
    }

    func startSaving(posts: [BookmarkedPost]) {
        guard !isSaving else { return }
        let media = selectedMedia(from: posts)
        guard !media.isEmpty else {
            show(AppError.noMediaSelected)
            return
        }

        result = nil
        progress = BatchSaveProgress(
            completed: 0,
            total: media.count,
            currentFraction: 0,
            currentType: nil
        )
        isSaving = true
        saveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await saver.save(media) { update in
                    Task { @MainActor [weak self] in
                        self?.progress = update
                    }
                }
                self.result = result
            } catch is CancellationError {
                // A user cancellation is not shown as an error.
            } catch {
                show(error)
            }
            isSaving = false
            saveTask = nil
        }
    }

    func cancelSaving() {
        saver.cancel()
        saveTask?.cancel()
    }

    private func show(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        presentedError = PresentedError(
            message: message,
            offersSettings: (error as? AppError) == .photoPermissionDenied
        )
    }
}
