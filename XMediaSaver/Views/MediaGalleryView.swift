import AVKit
import QuartzCore
import SwiftUI
import UIKit

private enum GallerySelectionDragIntent: Equatable {
    case undecided
    case scrolling
    case selecting
}

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
    @State private var selectionDragIntent =
        GallerySelectionDragIntent.undecided
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
                        if isSelecting {
                            toggleSelection(for: item.id)
                        } else if let index = galleryItems.firstIndex(
                                where: { $0.id == item.id }
                              ) {
                            viewerSelection = GalleryViewerSelection(
                                index: index
                            )
                        }
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
        .scrollDisabled(
            isSelecting && selectionDragIntent == .selecting
        )
        .coordinateSpace(name: Self.gridCoordinateSpace)
        .onPreferenceChange(GalleryCellFramePreferenceKey.self) {
            cellFrames = $0
        }
        .simultaneousGesture(
            selectionDragGesture,
            including: isSelecting ? .all : .none
        )
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .compactBackButton()
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
            minimumDistance: 8,
            coordinateSpace: .named(Self.gridCoordinateSpace)
        )
        .onChanged { value in
            guard isSelecting else { return }
            let horizontal = abs(value.translation.width)
            let vertical = abs(value.translation.height)

            if selectionDragIntent == .undecided {
                if horizontal >= 14,
                   horizontal > vertical * 1.15 {
                    selectionDragIntent = .selecting
                    updateDragSelection(at: value.startLocation)
                } else if vertical >= 10,
                          vertical >= horizontal {
                    selectionDragIntent = .scrolling
                }
            }

            if selectionDragIntent == .selecting {
                updateDragSelection(at: value.location)
            }
        }
        .onEnded { _ in
            resetSelectionDrag()
        }
    }

    private func toggleSelection(for key: String) {
        if selectedMediaKeys.contains(key) {
            selectedMediaKeys.remove(key)
        } else {
            selectedMediaKeys.insert(key)
        }
        mediaSaver.clearResult()
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
        selectionDragIntent = .undecided
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
                        ?? L10n.format(
                            "已选择 %lld 项",
                            selectedMediaKeys.count
                        )
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
        case nil: return L10n.string("全部媒体")
        case .some(.photo): return L10n.string("图片")
        case .some(.animatedGIF): return L10n.string("动图")
        case .some(.video): return L10n.string("视频")
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

private enum GalleryPagingDirection {
    case previous
    case next
}

private enum GalleryNavigationDragAxis {
    case undecided
    case horizontal
    case vertical
}

private struct GalleryNavigationGestureState {
    var axis = GalleryNavigationDragAxis.undecided
    var horizontalTranslation: CGFloat = 0
}

private struct GalleryFullScreenViewer: View {
    let items: [GalleryMediaItem]
    let initialIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var imageIsZoomed = false
    @State private var presentedPost: BookmarkedPost?
    @State private var pageDragOffset: CGFloat = 0
    @GestureState private var navigationGestureState =
        GalleryNavigationGestureState()
    @State private var completesPageTransition = false
    @StateObject private var playbackController =
        GalleryPlaybackController()

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

                interactivePages(width: geometry.size.width)

                if let scrubState = playbackController.scrubState {
                    GalleryScrubOverlay(state: scrubState)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 42)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .transition(.opacity)
                }

                if let feedback = playbackController.seekFeedback {
                    GallerySeekFeedbackOverlay(feedback: feedback)
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

                edgePagingControls(
                    width: geometry.size.width,
                    topInset: max(78, geometry.safeAreaInsets.top + 54)
                )
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                SpatialTapGesture(count: 2)
                    .onEnded {
                        handleDoubleTap(
                            at: $0.location,
                            width: geometry.size.width
                        )
                    },
                including: currentItem?.media.type == .video
                    ? .gesture
                    : .none
            )
            .simultaneousGesture(
                scrubGesture(width: geometry.size.width),
                including: currentItem?.media.type == .video
                    ? .gesture
                    : .none
            )
            .simultaneousGesture(
                navigationDragGesture(width: geometry.size.width)
            )
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
        .task(id: currentIndex) {
            await preloadNearbyPhotos()
        }
        .sheet(item: $presentedPost) { post in
            NavigationStack {
                BookmarkPostDetailView(
                    post: post,
                    preservesAudioSessionOnDismiss: true
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") {
                            presentedPost = nil
                        }
                    }
                }
            }
        }
        .onDisappear {
            playbackController.galleryDidDisappear()
            if !playbackController.isPictureInPictureActive {
                Task {
                    await MediaPlaybackAudioSession.deactivate()
                }
            }
        }
    }

    private var currentItem: GalleryMediaItem? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    private var visiblePageOffset: CGFloat {
        completesPageTransition
            ? pageDragOffset
            : navigationGestureState.horizontalTranslation
    }

    @ViewBuilder
    private func interactivePages(width: CGFloat) -> some View {
        ZStack {
            if visiblePageOffset > 0,
               items.indices.contains(currentIndex - 1) {
                GalleryAdjacentMediaPreview(
                    item: items[currentIndex - 1]
                )
                .frame(width: width)
                .offset(x: -width + visiblePageOffset)
            }

            if visiblePageOffset < 0,
               items.indices.contains(currentIndex + 1) {
                GalleryAdjacentMediaPreview(
                    item: items[currentIndex + 1]
                )
                .frame(width: width)
                .offset(x: width + visiblePageOffset)
            }

            if let item = currentItem {
                ZStack {
                    GalleryViewerMediaPage(
                        item: item,
                        imageIsZoomed: $imageIsZoomed,
                        playbackSuspended: presentedPost != nil,
                        playbackController: playbackController,
                        dismissAction: { dismiss() }
                    )
                    .id(item.id)
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
                .frame(width: width)
                .offset(x: visiblePageOffset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func edgePagingControls(
        width: CGFloat,
        topInset: CGFloat
    ) -> some View {
        let edgeWidth = min(max(width * 0.20, 56), 84)
        return HStack(spacing: 0) {
            GalleryEdgePagingButton(direction: .previous) {
                moveImmediately(by: -1)
            }
            .frame(width: edgeWidth)
            .disabled(!items.indices.contains(currentIndex - 1))

            Spacer(minLength: 0)

            GalleryEdgePagingButton(direction: .next) {
                moveImmediately(by: 1)
            }
            .frame(width: edgeWidth)
            .disabled(!items.indices.contains(currentIndex + 1))
        }
        .padding(.top, topInset)
        .allowsHitTesting(
            !imageIsZoomed
                && !playbackController.isScrubbing
                && !playbackController.isPictureInPictureActive
                && !completesPageTransition
        )
    }

    private func handleDoubleTap(
        at location: CGPoint,
        width: CGFloat
    ) {
        guard currentItem?.media.type == .video,
              !imageIsZoomed,
              !playbackController.isScrubbing,
              !playbackController.isPictureInPictureActive,
              width > 0,
              location.y > 80
        else {
            return
        }
        let edgeWidth = min(max(width * 0.20, 56), 84)
        guard location.x >= edgeWidth,
              location.x <= width - edgeWidth
        else {
            return
        }
        playbackController.seek(
            by: location.x < width / 2 ? -5 : 5
        )
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        LongPressGesture(
            minimumDuration: 0.5,
            maximumDistance: 10
        )
        .sequenced(
            before: DragGesture(
                minimumDistance: 0,
                coordinateSpace: .local
            )
        )
        .onChanged { value in
            guard currentItem?.media.type == .video,
                  !imageIsZoomed,
                  !playbackController.isPictureInPictureActive,
                  !completesPageTransition
            else {
                return
            }

            switch value {
            case .second(true, let drag):
                playbackController.beginScrubbing(width: width)
                if let drag {
                    playbackController.updateScrubbing(
                        horizontalTranslation: drag.translation.width,
                        width: width
                    )
                }
            default:
                break
            }
        }
        .onEnded { _ in
            playbackController.endScrubbing()
        }
    }

    private func navigationDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($navigationGestureState) { value, state, _ in
                guard !imageIsZoomed,
                      !playbackController.isScrubbing,
                      !playbackController.isPictureInPictureActive,
                      !completesPageTransition
                else {
                    return
                }

                let horizontal = abs(value.translation.width)
                let vertical = abs(value.translation.height)
                if state.axis == .undecided {
                    guard max(horizontal, vertical) >= 12 else { return }
                    state.axis = horizontal >= vertical
                        ? .horizontal
                        : .vertical
                }

                guard state.axis == .horizontal else { return }
                let proposed = value.translation.width
                let hasDestination = proposed < 0
                    ? items.indices.contains(currentIndex + 1)
                    : items.indices.contains(currentIndex - 1)
                state.horizontalTranslation = hasDestination
                    ? proposed
                    : proposed * 0.22
            }
            .onEnded { value in
                guard !imageIsZoomed,
                      !playbackController.isScrubbing,
                      !playbackController.isPictureInPictureActive,
                      !completesPageTransition
                else {
                    return
                }

                if navigationGestureState.axis == .horizontal {
                    finishHorizontalDrag(value, width: width)
                    return
                }

                guard navigationGestureState.axis == .vertical else {
                    return
                }
                let predictedVertical =
                    value.predictedEndTranslation.height
                if predictedVertical < -80, let currentItem {
                    presentedPost = currentItem.post
                } else if predictedVertical > 80,
                          currentItem?.media.type != .photo {
                    dismiss()
                }
            }
    }

    private func finishHorizontalDrag(
        _ value: DragGesture.Value,
        width: CGFloat
    ) {
        guard width > 0 else { return }
        let translation = value.translation.width
        let predicted = value.predictedEndTranslation.width
        let direction = translation < 0 ? 1 : -1
        let candidate = currentIndex + direction
        let passesDistance = abs(translation) >= width * 0.23
        let passesPrediction = abs(predicted) >= width * 0.38
        guard items.indices.contains(candidate),
              passesDistance || passesPrediction
        else {
            settlePageBack(from: translation)
            return
        }

        completesPageTransition = true
        pageDragOffset = translation
        let target = direction > 0 ? -width : width
        withAnimation(.easeOut(duration: 0.22)) {
            pageDragOffset = target
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard completesPageTransition else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                imageIsZoomed = false
                currentIndex = candidate
                pageDragOffset = 0
            }
            completesPageTransition = false
        }
    }

    private func settlePageBack(from translation: CGFloat) {
        completesPageTransition = true
        pageDragOffset = translation
        withAnimation(.interactiveSpring(
            response: 0.25,
            dampingFraction: 0.88
        )) {
            pageDragOffset = 0
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard completesPageTransition else { return }
            pageDragOffset = 0
            completesPageTransition = false
        }
    }

    private func moveImmediately(by offset: Int) {
        guard !playbackController.isScrubbing,
              !playbackController.isPictureInPictureActive,
              !completesPageTransition
        else {
            return
        }
        let candidate = currentIndex + offset
        guard items.indices.contains(candidate) else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            imageIsZoomed = false
            pageDragOffset = 0
            currentIndex = candidate
        }
    }

    private func preloadNearbyPhotos() async {
        let candidateIndices =
            (1...12).map { currentIndex + $0 }
            + (1...3).map { currentIndex - $0 }
        let photos = candidateIndices.compactMap {
            index -> BookmarkedMedia? in
            guard items.indices.contains(index),
                  items[index].media.type == .photo
            else {
                return nil
            }
            return items[index].media
        }
        await preloadCovers(
            photos,
            maximumPixelSize: 1_280
        )
    }

    private func preloadCovers(
        _ media: [BookmarkedMedia],
        maximumPixelSize: Int
    ) async {
        for item in media {
            guard !Task.isCancelled else { return }
            await LocalMediaThumbnailLoader.preload(
                media: item,
                maximumPixelSize: maximumPixelSize,
                remoteImageName: "orig"
            )
        }
    }
}

private struct GalleryAdjacentMediaPreview: View {
    let item: GalleryMediaItem

    var body: some View {
        GalleryMediaCover(media: item.media)
    }
}

private struct GalleryMediaCover: View {
    let media: BookmarkedMedia

    var body: some View {
        ZStack {
            Color.black

            LocalMediaThumbnailView(
                media: media,
                maximumPixelSize: 1_280,
                contentMode: .fit,
                remoteImageName:
                    media.type == .photo ? "orig" : "small",
                showsPlaceholder: false,
                alignment: .center
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipped()
    }
}

private struct GalleryEdgePagingButton: View {
    let direction: GalleryPagingDirection
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Color.clear
                .contentShape(Rectangle())
        }
        .buttonStyle(
            GalleryEdgePagingButtonStyle(direction: direction)
        )
        .accessibilityLabel(
            direction == .previous ? "上一个媒体" : "下一个媒体"
        )
    }
}

private struct GalleryEdgePagingButtonStyle: ButtonStyle {
    let direction: GalleryPagingDirection

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                LinearGradient(
                    colors: [
                        Color.white.opacity(
                            configuration.isPressed ? 0.14 : 0
                        ),
                        Color.black.opacity(
                            configuration.isPressed ? 0.08 : 0
                        ),
                        .clear
                    ],
                    startPoint: direction == .previous
                        ? .leading
                        : .trailing,
                    endPoint: direction == .previous
                        ? .trailing
                        : .leading
                )
            }
            .animation(
                .easeOut(duration: configuration.isPressed ? 0.08 : 0.15),
                value: configuration.isPressed
            )
    }
}

private struct GalleryScrubState {
    let targetSeconds: Double
    let durationSeconds: Double

    var progress: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(max(targetSeconds / durationSeconds, 0), 1)
    }
}

private struct GallerySeekFeedback: Identifiable {
    let id = UUID()
    let seconds: Int
}

private struct GalleryScrubOverlay: View {
    let state: GalleryScrubState

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.28))
                        .frame(height: 4)
                    Capsule()
                        .fill(.white)
                        .frame(
                            width: geometry.size.width * state.progress,
                            height: 4
                        )
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .offset(
                            x: max(
                                0,
                                min(
                                    geometry.size.width - 14,
                                    geometry.size.width * state.progress - 7
                                )
                            )
                        )
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 16)

            HStack {
                Text(Self.timeText(state.targetSeconds))
                Spacer()
                Text(Self.timeText(state.durationSeconds))
            }
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.black.opacity(0.68), in: RoundedRectangle(
            cornerRadius: 14
        ))
        .allowsHitTesting(false)
    }

    private static func timeText(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded(.down)), 0)
        if total >= 3_600 {
            return String(
                format: "%d:%02d:%02d",
                total / 3_600,
                (total % 3_600) / 60,
                total % 60
            )
        }
        return String(
            format: "%d:%02d",
            total / 60,
            total % 60
        )
    }
}

private struct GallerySeekFeedbackOverlay: View {
    let feedback: GallerySeekFeedback

    var body: some View {
        VStack(spacing: 6) {
            Image(
                systemName: feedback.seconds < 0
                    ? "gobackward.5"
                    : "goforward.5"
            )
            .font(.system(size: 34, weight: .semibold))
            Text(feedback.seconds < 0 ? "−5" : "+5")
                .font(.headline.monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(.black.opacity(0.58), in: RoundedRectangle(
            cornerRadius: 16
        ))
        .allowsHitTesting(false)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

@MainActor
private final class GalleryPlaybackController: ObservableObject {
    @Published private(set) var scrubState: GalleryScrubState?
    @Published private(set) var seekFeedback: GallerySeekFeedback?
    @Published private(set) var isPictureInPictureActive = false

    private weak var player: AVPlayer?
    private var mediaKey: String?
    private var galleryIsDismissed = false
    private var scrubStartSeconds: Double = 0
    private var scrubDurationSeconds: Double = 0
    private var resumesAfterScrub = false
    private var lastPreviewSeekAt: CFTimeInterval = 0
    private var feedbackTask: Task<Void, Never>?

    var isScrubbing: Bool {
        scrubState != nil
    }

    func attach(player: AVPlayer, mediaKey: String) {
        self.player = player
        self.mediaKey = mediaKey
        galleryIsDismissed = false
        scrubState = nil
    }

    func detach(player: AVPlayer, mediaKey: String) {
        guard self.player === player, self.mediaKey == mediaKey else {
            return
        }
        detachAll()
    }

    func detachAll() {
        feedbackTask?.cancel()
        feedbackTask = nil
        scrubState = nil
        seekFeedback = nil
        player = nil
        mediaKey = nil
    }

    func setPictureInPictureActive(_ active: Bool) {
        isPictureInPictureActive = active
        guard !active, galleryIsDismissed else { return }
        player?.pause()
        detachAll()
        Task {
            await MediaPlaybackAudioSession.deactivate()
        }
    }

    func galleryDidDisappear() {
        if isPictureInPictureActive {
            galleryIsDismissed = true
            return
        }
        detachAll()
    }

    func seek(by seconds: Double) {
        guard !isScrubbing,
              let player,
              let duration = finiteDuration(of: player),
              duration > 0
        else {
            return
        }
        let current = finiteCurrentTime(of: player)
        let target = min(max(current + seconds, 0), duration)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.05, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600)
        )
        showSeekFeedback(seconds: seconds < 0 ? -5 : 5)
    }

    func beginScrubbing(width: CGFloat) {
        guard scrubState == nil,
              width > 0,
              let player,
              let duration = finiteDuration(of: player),
              duration > 0
        else {
            return
        }
        scrubStartSeconds = finiteCurrentTime(of: player)
        scrubDurationSeconds = duration
        resumesAfterScrub = player.rate > 0
        player.pause()
        scrubState = GalleryScrubState(
            targetSeconds: scrubStartSeconds,
            durationSeconds: duration
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func updateScrubbing(
        horizontalTranslation: CGFloat,
        width: CGFloat
    ) {
        guard let player,
              scrubState != nil,
              width > 0,
              scrubDurationSeconds > 0
        else {
            return
        }
        let progressDelta = Double(horizontalTranslation / width)
        let target = min(
            max(
                scrubStartSeconds
                    + progressDelta * scrubDurationSeconds,
                0
            ),
            scrubDurationSeconds
        )
        scrubState = GalleryScrubState(
            targetSeconds: target,
            durationSeconds: scrubDurationSeconds
        )

        let now = CACurrentMediaTime()
        guard now - lastPreviewSeekAt >= 0.10 else { return }
        lastPreviewSeekAt = now
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.12, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.12, preferredTimescale: 600)
        )
    }

    func endScrubbing() {
        guard let player, let state = scrubState else { return }
        let shouldResume = resumesAfterScrub
        scrubState = nil
        player.seek(
            to: CMTime(
                seconds: state.targetSeconds,
                preferredTimescale: 600
            ),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { finished in
            guard finished, shouldResume else { return }
            DispatchQueue.main.async {
                player.play()
            }
        }
    }

    private func showSeekFeedback(seconds: Int) {
        feedbackTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) {
            seekFeedback = GallerySeekFeedback(seconds: seconds)
        }
        feedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.16)) {
                self?.seekFeedback = nil
            }
        }
    }

    private func finiteDuration(of player: AVPlayer) -> Double? {
        guard let seconds = player.currentItem?.duration.seconds,
              seconds.isFinite,
              seconds > 0
        else {
            return nil
        }
        return seconds
    }

    private func finiteCurrentTime(of player: AVPlayer) -> Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(seconds, 0) : 0
    }
}

private struct GalleryViewerMediaPage: View {
    let item: GalleryMediaItem
    @Binding var imageIsZoomed: Bool
    let playbackSuspended: Bool
    @ObservedObject var playbackController: GalleryPlaybackController
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
            GalleryVideoPlayer(
                media: item.media,
                playbackSuspended: playbackSuspended,
                playbackController: playbackController
            )
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
                    showsPlaceholder: false,
                    alignment: .center
                )

                LocalMediaThumbnailView(
                    media: media,
                    maximumPixelSize: 4_096,
                    contentMode: .fit,
                    remoteImageName: "orig",
                    showsPlaceholder: false,
                    alignment: .center
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
    let playbackSuspended: Bool
    @ObservedObject var playbackController: GalleryPlaybackController
    @State private var player: AVPlayer?
    @State private var looper: AVPlayerLooper?
    @State private var isSilent: Bool?
    @State private var playerReadyForDisplay = false
    @State private var pausedForBackground = false
    @AppStorage("postVideoBackgroundPlaybackEnabled")
    private var backgroundPlaybackEnabled = false

    var body: some View {
        ZStack {
            Color.black

            if let player {
                GallerySystemVideoPlayerView(
                    player: player,
                    isReadyForDisplay: $playerReadyForDisplay,
                    playbackController: playbackController
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }

            if !playerReadyForDisplay {
                GalleryMediaCover(media: media)
                    .allowsHitTesting(false)
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
            }
        }
        .ignoresSafeArea()
            .task(id: media.mediaKey) {
                playerReadyForDisplay = false
                player?.pause()
                player = nil
                looper = nil
                let localURL = await LocalMediaLibrary.shared.localURL(
                    for: media.mediaKey
                )
                guard let url = localURL ?? media.bestMP4Variant?.url else {
                    return
                }

                let asset = AVURLAsset(url: url)
                let item = AVPlayerItem(asset: asset)
                let newPlayer: AVPlayer

                if media.type == .animatedGIF {
                    let gifPlayer = AVPlayer(playerItem: item)
                    gifPlayer.actionAtItemEnd = .none
                    gifPlayer.isMuted = true
                    isSilent = true
                    newPlayer = gifPlayer
                } else {
                    let videoPlayer = AVQueuePlayer()
                    videoPlayer.allowsExternalPlayback = false
                    looper = AVPlayerLooper(
                        player: videoPlayer,
                        templateItem: item
                    )
                    newPlayer = videoPlayer
                }

                newPlayer.allowsExternalPlayback = false
                player = newPlayer
                playbackController.attach(
                    player: newPlayer,
                    mediaKey: media.mediaKey
                )
                if !playbackSuspended {
                    newPlayer.play()
                }

                if media.type == .video {
                    // Audio-track inspection can require a network round trip.
                    // Playback and page replacement must not wait for it.
                    let silent = await MediaPlaybackAudioSession.isSilent(
                        media: media,
                        asset: asset
                    )
                    guard !Task.isCancelled, player === newPlayer else {
                        return
                    }
                    isSilent = silent
                    newPlayer.isMuted = silent
                    await MediaPlaybackAudioSession.activate(silent: silent)
                } else {
                    await MediaPlaybackAudioSession.activate(silent: true)
                }
            }
            .onChange(of: playbackSuspended) { suspended in
                if suspended {
                    player?.pause()
                } else {
                    player?.play()
                    if let isSilent {
                        Task {
                            await MediaPlaybackAudioSession.activate(
                                silent: isSilent
                            )
                        }
                    }
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .AVPlayerItemDidPlayToEndTime
                )
            ) { notification in
                guard media.type == .animatedGIF,
                      let endedItem = notification.object as? AVPlayerItem,
                      let currentItem = player?.currentItem,
                      endedItem === currentItem
                else {
                    return
                }
                player?.seek(to: .zero)
                player?.play()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.didEnterBackgroundNotification
                )
            ) { _ in
                guard !playbackController.isPictureInPictureActive,
                      !backgroundPlaybackEnabled
                        || isSilent != false
                else {
                    return
                }
                pausedForBackground = player?.rate != 0
                player?.pause()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.willEnterForegroundNotification
                )
            ) { _ in
                guard pausedForBackground else { return }
                pausedForBackground = false
                if !playbackSuspended {
                    player?.play()
                }
            }
            .onDisappear {
                guard !playbackController.isPictureInPictureActive else {
                    return
                }
                player?.pause()
                if let player {
                    playbackController.detach(
                        player: player,
                        mediaKey: media.mediaKey
                    )
                }
                player = nil
                looper = nil
            }
    }
}

private struct GallerySystemVideoPlayerView:
    UIViewControllerRepresentable {
    let player: AVPlayer
    @Binding var isReadyForDisplay: Bool
    @ObservedObject var playbackController: GalleryPlaybackController

    func makeUIViewController(
        context: Context
    ) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.delegate = context.coordinator
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        controller.view.backgroundColor = .black
        context.coordinator.attach(to: controller)
        context.coordinator.observeDisplayReadiness(of: controller)
        return controller
    }

    func updateUIViewController(
        _ controller: AVPlayerViewController,
        context: Context
    ) {
        if controller.player !== player {
            isReadyForDisplay = false
            controller.player = player
        }
        context.coordinator.observeDisplayReadiness(of: controller)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isReadyForDisplay: $isReadyForDisplay,
            playbackController: playbackController
        )
    }

    static func dismantleUIViewController(
        _ controller: AVPlayerViewController,
        coordinator: Coordinator
    ) {
        controller.delegate = nil
        coordinator.detach()
        if !coordinator.playbackController
            .isPictureInPictureActive {
            controller.player = nil
        }
    }

    final class Coordinator:
        NSObject,
        AVPlayerViewControllerDelegate {
        let playbackController: GalleryPlaybackController
        private var isReadyForDisplay: Binding<Bool>
        private weak var playerViewController: AVPlayerViewController?
        private var observers: [NSObjectProtocol] = []
        private var readinessObservation: NSKeyValueObservation?
        private var userStartedPictureInPicture = false

        init(
            isReadyForDisplay: Binding<Bool>,
            playbackController: GalleryPlaybackController
        ) {
            self.isReadyForDisplay = isReadyForDisplay
            self.playbackController = playbackController
        }

        func observeDisplayReadiness(
            of controller: AVPlayerViewController
        ) {
            guard readinessObservation == nil else { return }
            readinessObservation = controller.observe(
                \.isReadyForDisplay,
                options: [.initial, .new]
            ) { [weak self] controller, _ in
                DispatchQueue.main.async {
                    self?.isReadyForDisplay.wrappedValue =
                        controller.isReadyForDisplay
                }
            }
        }

        func attach(to controller: AVPlayerViewController) {
            playerViewController = controller
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: UIApplication.willResignActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self,
                              !self.userStartedPictureInPicture
                        else {
                            return
                        }
                        self.playerViewController?
                            .allowsPictureInPicturePlayback = false
                    }
                },
                center.addObserver(
                    forName: UIApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.playerViewController?
                            .allowsPictureInPicturePlayback = true
                    }
                }
            ]
        }

        func detach() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
            readinessObservation?.invalidate()
            readinessObservation = nil
            playerViewController = nil
        }

        @MainActor
        func playerViewControllerWillStartPictureInPicture(
            _ playerViewController: AVPlayerViewController
        ) {
            userStartedPictureInPicture = true
            playbackController.setPictureInPictureActive(true)
        }

        @MainActor
        func playerViewControllerDidStopPictureInPicture(
            _ playerViewController: AVPlayerViewController
        ) {
            userStartedPictureInPicture = false
            playbackController.setPictureInPictureActive(false)
        }

        @MainActor
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            failedToStartPictureInPictureWithError error: Error
        ) {
            userStartedPictureInPicture = false
            playbackController.setPictureInPictureActive(false)
        }

        func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(
            _ playerViewController: AVPlayerViewController
        ) -> Bool {
            false
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
                resultMessage = L10n.format(
                    "保存 %lld 项，跳过 %lld 项，失败 %lld 项。",
                    result.saved,
                    result.skipped,
                    result.failed
                )
                if result.failed > 0, let issue = result.issues.first {
                    presentedError = PresentedError(
                        message: issue,
                        offersSettings: false
                    )
                }
            } catch is CancellationError {
                resultMessage = L10n.string("保存已取消。")
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
