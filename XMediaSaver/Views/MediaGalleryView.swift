import AVKit
import SwiftUI
import UIKit

struct MediaGalleryView: View {
    let mediaType: BookmarkMediaType?
    @Environment(\.openURL) private var openURL
    @State private var visibleLimit = 90
    @State private var isSelecting = false
    @State private var selectedMediaKeys: Set<String> = []
    @State private var cellFrames: [String: CGRect] = [:]
    @State private var dragAnchorIndex: Int?
    @State private var dragSelects = true
    @State private var selectionBeforeDrag: Set<String> = []
    @State private var viewerSelection: GalleryViewerSelection?
    @State private var sort = BookmarkPostSort.bookmarkNewest
    @State private var galleryItems: [GalleryMediaItem]
    @State private var indexByMediaKey: [String: Int]
    @StateObject private var mediaSaver = GalleryMediaSaveModel()
    private let baseGalleryItems: [GalleryMediaItem]
    private static let gridCoordinateSpace = "MediaGalleryGrid"

    init(posts: [BookmarkedPost], mediaType: BookmarkMediaType?) {
        self.mediaType = mediaType
        var seen: Set<String> = []
        let items: [GalleryMediaItem] = posts.enumerated()
            .flatMap { postOffset, post -> [GalleryMediaItem] in
                post.media.enumerated().compactMap {
                    mediaOffset, media -> GalleryMediaItem? in
                    guard mediaType == nil || media.type == mediaType,
                          seen.insert(media.mediaKey).inserted
                    else {
                        return nil
                    }
                    return GalleryMediaItem(
                        post: post,
                        media: media,
                        postOrder: postOffset,
                        mediaOrder: mediaOffset
                    )
                }
            }
        self.baseGalleryItems = items
        _galleryItems = State(initialValue: items)
        _indexByMediaKey = State(initialValue: Dictionary(
            uniqueKeysWithValues: items.enumerated().map {
                ($0.element.id, $0.offset)
            }
        ))
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 2),
                    count: 3
                ),
                spacing: 2
            ) {
                ForEach(Array(galleryItems.prefix(visibleLimit))) { item in
                    Button {
                        guard !isSelecting,
                              let index = galleryItems.firstIndex(
                                where: { $0.id == item.id }
                              )
                        else {
                            return
                        }
                        viewerSelection = GalleryViewerSelection(index: index)
                    } label: {
                        galleryCell(item)
                    }
                    .buttonStyle(.plain)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: GalleryCellFramePreferenceKey.self,
                                value: [
                                    item.id: geometry.frame(
                                        in: .named(Self.gridCoordinateSpace)
                                    )
                                ]
                            )
                        }
                    }
                    .onAppear {
                        if item.id == galleryItems.prefix(visibleLimit).last?.id,
                           visibleLimit < galleryItems.count {
                            visibleLimit += 90
                        }
                    }
                }
            }
        }
        .coordinateSpace(name: Self.gridCoordinateSpace)
        .onPreferenceChange(GalleryCellFramePreferenceKey.self) {
            cellFrames = $0
        }
        .highPriorityGesture(
            selectionDragGesture,
            including: isSelecting ? .all : .none
        )
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: sort) { value in
            applySort(value)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Menu {
                    Picker("媒体排序", selection: $sort) {
                        ForEach(BookmarkPostSort.allCases) {
                            Text($0.title).tag($0)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                Text("\(galleryItems.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(isSelecting ? "完成" : "多选") {
                    withAnimation {
                        isSelecting.toggle()
                        resetSelectionDrag()
                        if !isSelecting {
                            selectedMediaKeys.removeAll()
                        }
                    }
                }
                .disabled(mediaSaver.isSaving)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBar
            }
        }
        .fullScreenCover(item: $viewerSelection) { selection in
            GalleryFullScreenViewer(
                items: galleryItems,
                initialIndex: selection.index
            )
        }
        .alert(item: $mediaSaver.presentedError) { error in
            if error.offersSettings {
                return Alert(
                    title: Text("需要照片权限"),
                    message: Text(error.message),
                    primaryButton: .default(Text("打开设置")) {
                        guard let url = URL(
                            string: UIApplication.openSettingsURLString
                        ) else { return }
                        openURL(url)
                    },
                    secondaryButton: .cancel()
                )
            }
            return Alert(
                title: Text("保存未完成"),
                message: Text(error.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private var selectionDragGesture: some Gesture {
        DragGesture(
            minimumDistance: 0,
            coordinateSpace: .named(Self.gridCoordinateSpace)
        )
        .onChanged { value in
            updateDragSelection(at: value.location)
        }
        .onEnded { _ in
            resetSelectionDrag()
        }
    }

    private func updateDragSelection(at location: CGPoint) {
        guard isSelecting,
              let key = cellFrames.first(where: {
                $0.value.insetBy(dx: -1, dy: -1).contains(location)
              })?.key,
              let index = indexByMediaKey[key]
        else {
            return
        }

        if dragAnchorIndex == nil {
            dragAnchorIndex = index
            dragSelects = !selectedMediaKeys.contains(key)
            selectionBeforeDrag = selectedMediaKeys
        }
        guard let anchor = dragAnchorIndex else { return }
        let selectedRange = min(anchor, index)...max(anchor, index)
        let keys = Set(selectedRange.map { galleryItems[$0].id })
        selectedMediaKeys = dragSelects
            ? selectionBeforeDrag.union(keys)
            : selectionBeforeDrag.subtracting(keys)
        mediaSaver.clearResult()
    }

    private func resetSelectionDrag() {
        dragAnchorIndex = nil
        selectionBeforeDrag.removeAll()
    }

    private func applySort(_ value: BookmarkPostSort) {
        galleryItems = baseGalleryItems.sorted {
            Self.isOrderedBefore($0, $1, sort: value)
        }
        indexByMediaKey = Dictionary(
            uniqueKeysWithValues: galleryItems.enumerated().map {
                ($0.element.id, $0.offset)
            }
        )
        visibleLimit = 90
        cellFrames = [:]
        selectedMediaKeys.removeAll()
        resetSelectionDrag()
    }

    private static func isOrderedBefore(
        _ lhs: GalleryMediaItem,
        _ rhs: GalleryMediaItem,
        sort: BookmarkPostSort
    ) -> Bool {
        if lhs.post.id == rhs.post.id {
            return lhs.mediaOrder < rhs.mediaOrder
        }
        switch sort {
        case .bookmarkNewest:
            return lhs.postOrder < rhs.postOrder
        case .bookmarkOldest:
            return lhs.postOrder > rhs.postOrder
        case .newest:
            return postIsNewer(lhs.post, rhs.post)
        case .oldest:
            return postIsNewer(rhs.post, lhs.post)
        }
    }

    private static func postIsNewer(
        _ lhs: BookmarkedPost,
        _ rhs: BookmarkedPost
    ) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.id > rhs.id
        }
    }

    private func galleryCell(_ item: GalleryMediaItem) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                Color(uiColor: .secondarySystemBackground)

                LocalMediaThumbnailView(
                    media: item.media,
                    maximumPixelSize: 420
                )
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height
                )

                HStack(spacing: 4) {
                    Image(systemName: item.media.type.systemImage)
                    if let duration = item.media.durationMilliseconds {
                        Text(Self.durationText(duration))
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(5)
                .background(.black.opacity(0.55))

                if isSelecting {
                    selectionIndicator(
                        selected: selectedMediaKeys.contains(item.id)
                    )
                }
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height
            )
            .contentShape(Rectangle())
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func selectionIndicator(selected: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            if selected {
                Color.accentColor.opacity(0.10)
            }
            Image(
                systemName: selected
                    ? "checkmark.circle.fill"
                    : "circle"
            )
            .font(.title3)
            .foregroundStyle(
                selected ? Color.white : Color.white.opacity(0.9),
                Color.accentColor
            )
            .shadow(radius: 2)
            .padding(7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var selectionBar: some View {
        VStack(spacing: 8) {
            if mediaSaver.isSaving {
                ProgressView(value: mediaSaver.progressValue, total: 1)
            }
            HStack {
                Text(
                    mediaSaver.resultMessage
                        ?? "已选择 \(selectedMediaKeys.count) 项"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                Spacer()
                if mediaSaver.isSaving {
                    Button("取消", role: .cancel) {
                        mediaSaver.cancel()
                    }
                } else {
                    Button {
                        mediaSaver.save(
                            galleryItems
                                .filter {
                                    selectedMediaKeys.contains($0.id)
                                }
                                .map(\.media)
                        )
                    } label: {
                        Label(
                            "保存到照片",
                            systemImage: "photo.badge.arrow.down"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedMediaKeys.isEmpty)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var title: String {
        switch mediaType {
        case nil: return "全部媒体"
        case .some(.photo): return "图片"
        case .some(.animatedGIF): return "动图"
        case .some(.video): return "视频"
        }
    }

    private static func durationText(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1_000
        if seconds >= 3_600 {
            return String(
                format: "%d:%02d:%02d",
                seconds / 3_600,
                (seconds % 3_600) / 60,
                seconds % 60
            )
        }
        return String(
            format: "%d:%02d",
            seconds / 60,
            seconds % 60
        )
    }
}

private struct GalleryCellFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct GalleryViewerSelection: Identifiable {
    let index: Int
    var id: Int { index }
}

private struct GalleryMediaItem: Identifiable {
    let post: BookmarkedPost
    let media: BookmarkedMedia
    let postOrder: Int
    let mediaOrder: Int
    var id: String { media.mediaKey }
}

private struct GalleryFullScreenViewer: View {
    let items: [GalleryMediaItem]
    let initialIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var imageIsZoomed = false
    @State private var presentedPost: BookmarkedPost?

    init(items: [GalleryMediaItem], initialIndex: Int) {
        self.items = items
        self.initialIndex = initialIndex
        _currentIndex = State(
            initialValue: min(max(initialIndex, 0), max(items.count - 1, 0))
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black
                    .ignoresSafeArea()

                if let item = currentItem {
                    GalleryViewerMediaPage(
                        item: item,
                        imageIsZoomed: $imageIsZoomed,
                        dismissAction: { dismiss() }
                    )
                    .id(item.id)
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }

                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(11)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel("退出全屏")

                    Spacer()

                    Text("\(currentIndex + 1) / \(items.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                .padding()
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        handleTap(
                            at: value.location,
                            width: geometry.size.width
                        )
                    }
            )
            .simultaneousGesture(navigationDragGesture)
        }
        .statusBarHidden(true)
        .task(id: currentIndex) {
            await preloadNearbyPhotos()
        }
        .sheet(item: $presentedPost) { post in
            NavigationStack {
                BookmarkPostDetailView(post: post)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") {
                                presentedPost = nil
                            }
                        }
                    }
            }
        }
    }

    private var currentItem: GalleryMediaItem? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    private func handleTap(at location: CGPoint, width: CGFloat) {
        guard !imageIsZoomed, width > 0, location.y > 80 else { return }
        if location.x < width / 3 {
            move(by: -1)
        } else if location.x > width * 2 / 3 {
            move(by: 1)
        }
    }

    private var navigationDragGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard !imageIsZoomed else { return }
                let horizontal = value.predictedEndTranslation.width
                let vertical = value.predictedEndTranslation.height
                if abs(horizontal) > abs(vertical), abs(horizontal) > 70 {
                    move(by: horizontal < 0 ? 1 : -1)
                } else if vertical < -80, let currentItem {
                    presentedPost = currentItem.post
                } else if vertical > 80,
                          currentItem?.media.type != .photo {
                    dismiss()
                }
            }
    }

    private func move(by offset: Int) {
        let candidate = currentIndex + offset
        guard items.indices.contains(candidate) else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            imageIsZoomed = false
            currentIndex = candidate
        }
    }

    private func preloadNearbyPhotos() async {
        let candidateIndices =
            (1...12).map { currentIndex + $0 }
            + (1...3).map { currentIndex - $0 }
        let media = candidateIndices.compactMap { index -> BookmarkedMedia? in
            guard items.indices.contains(index),
                  items[index].media.type == .photo
            else {
                return nil
            }
            return items[index].media
        }

        for start in stride(from: 0, to: media.count, by: 4) {
            guard !Task.isCancelled else { return }
            let end = min(start + 4, media.count)
            await withTaskGroup(of: Void.self) { group in
                for item in media[start..<end] {
                    group.addTask {
                        await LocalMediaThumbnailLoader.preload(
                            media: item,
                            maximumPixelSize: 1_280,
                            remoteImageName: "orig"
                        )
                    }
                }
            }
        }
    }
}

private struct GalleryViewerMediaPage: View {
    let item: GalleryMediaItem
    @Binding var imageIsZoomed: Bool
    let dismissAction: () -> Void

    var body: some View {
        switch item.media.type {
        case .photo:
            ZoomableGalleryPhoto(
                media: item.media,
                isZoomed: $imageIsZoomed,
                dismissAction: dismissAction
            )
        case .animatedGIF, .video:
            GalleryVideoPlayer(media: item.media)
                .onAppear { imageIsZoomed = false }
        }
    }
}

private struct ZoomableGalleryPhoto: View {
    let media: BookmarkedMedia
    @Binding var isZoomed: Bool
    let dismissAction: () -> Void
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero
    @State private var dismissOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black
                .opacity(backgroundOpacity)

            ZStack {
                LocalMediaThumbnailView(
                    media: media,
                    maximumPixelSize: 1_280,
                    contentMode: .fit,
                    remoteImageName: "orig",
                    showsPlaceholder: false
                )

                LocalMediaThumbnailView(
                    media: media,
                    maximumPixelSize: 4_096,
                    contentMode: .fit,
                    remoteImageName: "orig",
                    showsPlaceholder: false
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(scale)
            .offset(combinedOffset)
        }
        .ignoresSafeArea()
        .simultaneousGesture(magnificationGesture)
        .simultaneousGesture(dragGesture)
        .onDisappear {
            isZoomed = false
        }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(settledScale * value, 1), 6)
                updateZoomState()
            }
            .onEnded { _ in
                settledScale = scale
                if scale <= 1.01 {
                    resetZoom()
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if scale > 1.01 {
                    offset = CGSize(
                        width: settledOffset.width + value.translation.width,
                        height: settledOffset.height + value.translation.height
                    )
                } else if value.translation.height > 0,
                          abs(value.translation.height)
                            > abs(value.translation.width) {
                    dismissOffset = CGSize(
                        width: value.translation.width * 0.2,
                        height: value.translation.height
                    )
                }
            }
            .onEnded { value in
                if scale > 1.01 {
                    settledOffset = offset
                    return
                }
                let predicted = value.predictedEndTranslation.height
                if dismissOffset.height > 90 || predicted > 180 {
                    dismissAction()
                } else {
                    withAnimation(.spring(response: 0.3)) {
                        dismissOffset = .zero
                    }
                }
            }
    }

    private var combinedOffset: CGSize {
        CGSize(
            width: offset.width + dismissOffset.width,
            height: offset.height + dismissOffset.height
        )
    }

    private var backgroundOpacity: Double {
        let progress = min(
            max(Double(dismissOffset.height / 360), 0),
            0.45
        )
        return 1 - progress
    }

    private func updateZoomState() {
        isZoomed = scale > 1.01
        if !isZoomed {
            offset = .zero
            settledOffset = .zero
        }
    }

    private func resetZoom() {
        scale = 1
        settledScale = 1
        offset = .zero
        settledOffset = .zero
        dismissOffset = .zero
        isZoomed = false
    }
}

private struct GalleryVideoPlayer: View {
    let media: BookmarkedMedia
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .task(id: media.mediaKey) {
                player?.pause()
                let localURL = await LocalMediaLibrary.shared.localURL(
                    for: media.mediaKey
                )
                if let url = localURL ?? media.bestMP4Variant?.url {
                    let item = AVPlayerItem(url: url)
                    let newPlayer = AVQueuePlayer()
                    looper = AVPlayerLooper(
                        player: newPlayer,
                        templateItem: item
                    )
                    player = newPlayer
                    newPlayer.play()
                }
            }
            .onDisappear {
                player?.pause()
            }
    }
}

@MainActor
private final class GalleryMediaSaveModel: ObservableObject {
    @Published private(set) var isSaving = false
    @Published private(set) var progress = BatchSaveProgress(
        completed: 0,
        total: 0,
        currentFraction: 0,
        currentType: nil
    )
    @Published private(set) var resultMessage: String?
    @Published var presentedError: PresentedError?

    private let saver = BatchMediaSaver()
    private var task: Task<Void, Never>?

    var progressValue: Double {
        guard progress.total > 0 else { return 0 }
        return min(
            (Double(progress.completed) + progress.currentFraction)
                / Double(progress.total),
            1
        )
    }

    func save(_ media: [BookmarkedMedia]) {
        guard !isSaving, !media.isEmpty else { return }
        resultMessage = nil
        isSaving = true
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                isSaving = false
                task = nil
            }
            do {
                progress = BatchSaveProgress(
                    completed: 0,
                    total: media.count,
                    currentFraction: 0,
                    currentType: nil
                )
                let result = try await saver.save(
                    media,
                    didSave: { _, _ in },
                    progress: { update in
                        Task { @MainActor [weak self] in
                            self?.progress = update
                        }
                    }
                )
                resultMessage =
                    "保存 \(result.saved) 项，跳过 \(result.skipped) 项，失败 \(result.failed) 项。"
                if result.failed > 0, let issue = result.issues.first {
                    presentedError = PresentedError(
                        message: issue,
                        offersSettings: false
                    )
                }
            } catch is CancellationError {
                resultMessage = "保存已取消。"
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                presentedError = PresentedError(
                    message: message,
                    offersSettings:
                        (error as? AppError) == .photoPermissionDenied
                )
            }
        }
    }

    func cancel() {
        saver.cancel()
        task?.cancel()
    }

    func clearResult() {
        if !isSaving {
            resultMessage = nil
        }
    }
}
