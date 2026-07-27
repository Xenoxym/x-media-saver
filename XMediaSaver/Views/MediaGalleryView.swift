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
            await preloadNearbyMedia()
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

    private func preloadNearbyMedia() async {
        let candidateIndices =
            (1...12).map { currentIndex + $0 }
            + (1...3).map { currentIndex - $0 }
        let media = candidateIndices.compactMap { index in
            items.indices.contains(index) ? items[index].media : nil
        }
        await preloadCovers(
            media.filter { $0.type == .photo },
            maximumPixelSize: 1_280,
            batchSize: 4
        )
        await preloadCovers(
            media.filter { $0.type != .photo },
            maximumPixelSize: 640,
            batchSize: 2
        )

        let nearbyIndices = [
            currentIndex + 1,
            currentIndex - 1,
            currentIndex + 2,
            currentIndex + 3
        ]
        let nearbyVideoMedia = nearbyIndices.compactMap {
            index -> BookmarkedMedia? in
            guard items.indices.contains(index),
                  items[index].media.type != .photo
            else {
                return nil
            }
            return items[index].media
        }
        let retainedIndices = [
            currentIndex,
            currentIndex - 1,
            currentIndex + 1,
            currentIndex + 2,
            currentIndex + 3
        ]
        let retainedMedia = retainedIndices.compactMap {
            index -> BookmarkedMedia? in
            guard items.indices.contains(index),
                  items[index].media.type != .photo
            else {
                return nil
            }
            return items[index].media
        }
        await GalleryMediaFilePreloadCache.shared.updateWindow(
            candidates: nearbyVideoMedia,
            retained: retainedMedia
        )

        let largeFileLimit: Int64 = 5 * 1_048_576
        var nextLargeMedia: BookmarkedMedia?
        for index in (1...3).map({ currentIndex + $0 }) {
            guard items.indices.contains(index) else { continue }
            let candidate = items[index].media
            guard candidate.type != .photo,
                  candidate.byteSize == nil
                    || candidate.byteSize! > largeFileLimit,
                  await LocalMediaLibrary.shared.localURL(
                    for: candidate.mediaKey
                  ) == nil
            else {
                continue
            }
            nextLargeMedia = candidate
            break
        }
        await GalleryVideoPrewarmStore.shared.update(media: nextLargeMedia)
    }

    private func preloadCovers(
        _ media: [BookmarkedMedia],
        maximumPixelSize: Int,
        batchSize: Int
    ) async {
        for start in stride(from: 0, to: media.count, by: batchSize) {
            guard !Task.isCancelled else { return }
            let end = min(start + batchSize, media.count)
            await withTaskGroup(of: Void.self) { group in
                for item in media[start..<end] {
                    group.addTask {
                        await LocalMediaThumbnailLoader.preload(
                            media: item,
                            maximumPixelSize: maximumPixelSize,
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
    @State private var player: AVPlayer?
    @State private var audioSessionActive = false

    var body: some View {
        ZStack {
            Color.black

            LocalMediaThumbnailView(
                media: media,
                maximumPixelSize: 640,
                contentMode: .fit,
                remoteImageName: "orig",
                showsPlaceholder: false
            )

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }
        }
        .ignoresSafeArea()
            .task(id: media.mediaKey) {
                player?.pause()
                let localURL = await LocalMediaLibrary.shared.localURL(
                    for: media.mediaKey
                )
                let cachedURL = await GalleryMediaFilePreloadCache.shared
                    .cachedURL(for: media.mediaKey)
                guard let url = localURL
                    ?? cachedURL
                    ?? media.bestMP4Variant?.url
                else {
                    return
                }

                let preparedPlayer: AVPlayer?
                if localURL == nil, cachedURL == nil {
                    preparedPlayer = await GalleryVideoPrewarmStore.shared
                        .claim(mediaKey: media.mediaKey)
                } else {
                    preparedPlayer = nil
                }
                let newPlayer = preparedPlayer ?? AVPlayer(url: url)
                let silent = await MediaPlaybackAudioSession.isSilent(
                    media: media,
                    url: url
                )
                newPlayer.isMuted = silent
                audioSessionActive = MediaPlaybackAudioSession.activate(
                    silent: silent
                )
                await Self.preroll(newPlayer)
                guard !Task.isCancelled else {
                    newPlayer.pause()
                    return
                }
                player = newPlayer
                newPlayer.play()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .AVPlayerItemDidPlayToEndTime
                )
            ) { notification in
                guard let endedItem = notification.object as? AVPlayerItem,
                      let currentItem = player?.currentItem,
                      endedItem === currentItem
                else {
                    return
                }
                player?.seek(to: .zero)
                player?.play()
            }
            .onDisappear {
                player?.pause()
                if audioSessionActive {
                    MediaPlaybackAudioSession.deactivate()
                    audioSessionActive = false
                }
            }
    }

    private static func preroll(_ player: AVPlayer) async {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            player.preroll(atRate: 1) { _ in
                continuation.resume()
            }
        }
    }
}

private actor GalleryMediaFilePreloadCache {
    static let shared = GalleryMediaFilePreloadCache()

    private struct CachedFile {
        let url: URL
        let byteSize: Int64
    }

    private static let individualLimit: Int64 = 5 * 1_048_576
    private static let totalLimit: Int64 = 20 * 1_048_576
    private let directory: URL
    private let session: URLSession
    private var files: [String: CachedFile] = [:]
    private var downloads: [String: Task<CachedFile?, Never>] = [:]
    private var downloadSizes: [String: Int64] = [:]
    private var retainedKeys: Set<String> = []

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "XMediaSaver-GalleryPreload",
                isDirectory: true
            )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration)

        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    func updateWindow(
        candidates: [BookmarkedMedia],
        retained: [BookmarkedMedia]
    ) {
        retainedKeys = Set(retained.map(\.mediaKey))

        let expiredFileKeys = files.keys.filter {
            !retainedKeys.contains($0)
        }
        for key in expiredFileKeys {
            if let file = files[key] {
                try? FileManager.default.removeItem(at: file.url)
            }
            files[key] = nil
        }
        let expiredDownloadKeys = downloads.keys.filter {
            !retainedKeys.contains($0)
        }
        for key in expiredDownloadKeys {
            downloads[key]?.cancel()
            downloads[key] = nil
            downloadSizes[key] = nil
        }

        var reservedBytes = files.values.reduce(Int64(0)) {
            $0 + $1.byteSize
        }
        reservedBytes += downloadSizes.values.reduce(0, +)

        for media in candidates {
            guard retainedKeys.contains(media.mediaKey),
                  files[media.mediaKey] == nil,
                  downloads[media.mediaKey] == nil,
                  let byteSize = media.byteSize,
                  byteSize > 0,
                  byteSize <= Self.individualLimit,
                  reservedBytes + byteSize <= Self.totalLimit,
                  let url = media.bestMP4Variant?.url
            else {
                continue
            }
            reservedBytes += byteSize
            startDownload(
                mediaKey: media.mediaKey,
                expectedByteSize: byteSize,
                url: url
            )
        }
    }

    func cachedURL(for mediaKey: String) async -> URL? {
        if let file = files[mediaKey],
           FileManager.default.fileExists(atPath: file.url.path) {
            return file.url
        }
        guard let task = downloads[mediaKey] else { return nil }
        return await task.value?.url
    }

    private func startDownload(
        mediaKey: String,
        expectedByteSize: Int64,
        url: URL
    ) {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "video.twimg.com" || host.hasSuffix(".twimg.com")
        else {
            return
        }

        let session = session
        let directory = directory
        let task = Task.detached(priority: .utility) {
            () -> CachedFile? in
            do {
                let (temporaryURL, response) = try await session.download(
                    from: url
                )
                guard !Task.isCancelled,
                      let response = response as? HTTPURLResponse,
                      (200...299).contains(response.statusCode)
                else {
                    return nil
                }
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: temporaryURL.path
                )
                let actualSize =
                    (attributes[.size] as? NSNumber)?.int64Value
                    ?? expectedByteSize
                guard actualSize > 0,
                      actualSize <= GalleryMediaFilePreloadCache
                        .individualLimit
                else {
                    return nil
                }
                try? FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let destination = directory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mp4")
                try FileManager.default.moveItem(
                    at: temporaryURL,
                    to: destination
                )
                return CachedFile(url: destination, byteSize: actualSize)
            } catch {
                return nil
            }
        }
        downloads[mediaKey] = task
        downloadSizes[mediaKey] = expectedByteSize

        Task { [weak self] in
            let result = await task.value
            await self?.finishDownload(
                mediaKey: mediaKey,
                result: result
            )
        }
    }

    private func finishDownload(
        mediaKey: String,
        result: CachedFile?
    ) {
        downloads[mediaKey] = nil
        downloadSizes[mediaKey] = nil
        guard let result else { return }
        guard retainedKeys.contains(mediaKey) else {
            try? FileManager.default.removeItem(at: result.url)
            return
        }
        files[mediaKey] = result
    }
}

@MainActor
private final class GalleryVideoPrewarmStore {
    static let shared = GalleryVideoPrewarmStore()

    private var players: [String: AVPlayer] = [:]

    func update(media: BookmarkedMedia?) {
        let retainedKey = media?.mediaKey
        let expiredKeys = players.keys.filter { $0 != retainedKey }
        for key in expiredKeys {
            players[key]?.cancelPendingPrerolls()
            players[key]?.pause()
            players[key] = nil
        }

        guard let media,
              players[media.mediaKey] == nil,
              let url = media.bestMP4Variant?.url
        else {
            return
        }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 2
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        players[media.mediaKey] = player
        player.preroll(atRate: 1) { _ in }
    }

    func claim(mediaKey: String) -> AVPlayer? {
        let player = players.removeValue(forKey: mediaKey)
        player?.cancelPendingPrerolls()
        return player
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
