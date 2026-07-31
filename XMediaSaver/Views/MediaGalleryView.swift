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

private struct GalleryFullScreenViewer: View {
    let items: [GalleryMediaItem]
    let initialIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var imageIsZoomed = false
    @State private var presentedPost: BookmarkedPost?
    @State private var pageDragOffset: CGFloat = 0
    @State private var navigationDragAxis =
        GalleryNavigationDragAxis.undecided
    @GestureState private var navigationDragIsActive = false
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
                .padding(.horizontal, 16)
                .padding(.top, 28)

                edgePagingControls(
                    width: geometry.size.width,
                    topInset: max(78, geometry.safeAreaInsets.top + 54)
                )
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                navigationDragGesture(width: geometry.size.width)
            )
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
        .onChange(of: navigationDragIsActive) { isActive in
            guard !isActive, !completesPageTransition else { return }
            navigationDragAxis = .undecided
            if pageDragOffset != 0 {
                withAnimation(.interactiveSpring(
                    response: 0.25,
                    dampingFraction: 0.88
                )) {
                    pageDragOffset = 0
                }
            }
        }
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
        }
    }

    private var currentItem: GalleryMediaItem? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    private var visiblePageOffset: CGFloat {
        pageDragOffset
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
                        canMovePrevious:
                            items.indices.contains(currentIndex - 1),
                        canMoveNext:
                            items.indices.contains(currentIndex + 1),
                        movePrevious: { moveImmediately(by: -1) },
                        moveNext: { moveImmediately(by: 1) },
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
        let edgeWidth = width / 10
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
            currentItem?.media.type == .photo
                && !imageIsZoomed
                && !playbackController.isScrubbing
                && !playbackController.isPictureInPictureActive
                && !completesPageTransition
        )
    }

    private func navigationDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($navigationDragIsActive) { _, isActive, _ in
                isActive = true
            }
            .onChanged { value in
                guard !imageIsZoomed,
                      !playbackController.isScrubbing,
                      !playbackController.isPictureInPictureActive,
                      !completesPageTransition
                else {
                    return
                }

                let horizontal = abs(value.translation.width)
                let vertical = abs(value.translation.height)
                if navigationDragAxis == .undecided {
                    guard max(horizontal, vertical) >= 12 else { return }
                    navigationDragAxis = horizontal >= vertical
                        ? .horizontal
                        : .vertical
                }

                guard navigationDragAxis == .horizontal else { return }
                let proposed = value.translation.width
                let hasDestination = proposed < 0
                    ? items.indices.contains(currentIndex + 1)
                    : items.indices.contains(currentIndex - 1)
                pageDragOffset = hasDestination
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

                if navigationDragAxis == .horizontal {
                    finishHorizontalDrag(value, width: width)
                    return
                }

                guard navigationDragAxis == .vertical else {
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
            navigationDragAxis = .undecided
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
            navigationDragAxis = .undecided
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
            navigationDragAxis = .undecided
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
                showsPlayIndicator: false,
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

@MainActor
private final class GalleryPlaybackController: ObservableObject {
    @Published private(set) var scrubState: GalleryScrubState?
    @Published private(set) var isPictureInPictureActive = false
    @Published private(set) var pictureInPictureAvailable = false
    @Published private(set) var pictureInPicturePossible = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isMuted = true
    @Published private(set) var currentSeconds: Double = 0
    @Published private(set) var durationSeconds: Double = 0
    @Published private(set) var directSeekActive = false

    private weak var player: AVPlayer?
    private var mediaKey: String?
    private var galleryIsDismissed = false
    private var scrubStartSeconds: Double = 0
    private var scrubDurationSeconds: Double = 0
    private var resumesAfterScrub = false
    private var resumesAfterDirectSeek = false
    private var lastPreviewSeekAt: CFTimeInterval = 0
    private var rateObservation: NSKeyValueObservation?
    private var muteObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var startPictureInPictureAction: (() -> Void)?
    private var pictureInPictureRegistrationID: UUID?
    private var cleanupTask: Task<Void, Never>?

    var isScrubbing: Bool {
        scrubState != nil || directSeekActive
    }

    func attach(player: AVPlayer, mediaKey: String) {
        cleanupTask?.cancel()
        cleanupTask = nil
        removePlayerObservers()
        self.player = player
        self.mediaKey = mediaKey
        galleryIsDismissed = false
        scrubState = nil
        isMuted = player.isMuted
        isPlaying = player.rate != 0
        currentSeconds = finiteCurrentTime(of: player)
        durationSeconds = finiteDuration(of: player) ?? 0
        rateObservation = player.observe(
            \.rate,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            DispatchQueue.main.async {
                self?.isPlaying = player.rate != 0
            }
        }
        muteObservation = player.observe(
            \.isMuted,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            DispatchQueue.main.async {
                self?.isMuted = player.isMuted
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player else { return }
                let seconds = time.seconds
                self.currentSeconds =
                    seconds.isFinite ? max(seconds, 0) : 0
                self.durationSeconds =
                    self.finiteDuration(of: player) ?? 0
            }
        }
    }

    func detach(player: AVPlayer, mediaKey: String) {
        guard self.player === player, self.mediaKey == mediaKey else {
            return
        }
        detachAll()
    }

    func detachAll() {
        removePlayerObservers()
        scrubState = nil
        player = nil
        mediaKey = nil
        isPlaying = false
        currentSeconds = 0
        durationSeconds = 0
        directSeekActive = false
        pictureInPicturePossible = false
        pictureInPictureAvailable = false
        startPictureInPictureAction = nil
        pictureInPictureRegistrationID = nil
    }

    func setPictureInPictureActive(_ active: Bool) {
        isPictureInPictureActive = active
        guard !active, galleryIsDismissed else { return }
        player?.pause()
        scheduleCleanupAfterTransition()
    }

    func galleryDidDisappear() {
        galleryIsDismissed = true
        if isPictureInPictureActive {
            return
        }
        player?.pause()
        scheduleCleanupAfterTransition()
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
    }

    func togglePlayback() {
        guard let player else { return }
        if player.rate == 0 {
            player.play()
        } else {
            player.pause()
        }
    }

    func toggleMute() {
        guard let player else { return }
        player.isMuted.toggle()
    }

    func seek(to seconds: Double) {
        guard let player,
              let duration = finiteDuration(of: player),
              duration > 0
        else {
            return
        }
        let target = min(max(seconds, 0), duration)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.05, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600)
        )
        currentSeconds = target
    }

    func beginDirectSeeking() {
        guard let player else { return }
        directSeekActive = true
        resumesAfterDirectSeek = player.rate != 0
        player.pause()
    }

    func endDirectSeeking(at seconds: Double) {
        directSeekActive = false
        guard let player else { return }
        let shouldResume = resumesAfterDirectSeek
        seek(to: seconds)
        if shouldResume {
            player.play()
        }
    }

    func registerPictureInPicture(
        id: UUID,
        possible: Bool,
        start: @escaping () -> Void
    ) {
        pictureInPictureRegistrationID = id
        pictureInPictureAvailable = true
        pictureInPicturePossible = possible
        startPictureInPictureAction = start
    }

    func updatePictureInPicturePossible(
        _ possible: Bool,
        id: UUID
    ) {
        guard pictureInPictureRegistrationID == id else { return }
        pictureInPicturePossible = possible
    }

    func unregisterPictureInPicture(id: UUID) {
        guard pictureInPictureRegistrationID == id else { return }
        pictureInPictureAvailable = false
        pictureInPicturePossible = false
        startPictureInPictureAction = nil
        pictureInPictureRegistrationID = nil
    }

    func startPictureInPicture() {
        guard pictureInPictureAvailable else { return }
        startPictureInPictureAction?()
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

    private func removePlayerObservers() {
        rateObservation?.invalidate()
        rateObservation = nil
        muteObservation?.invalidate()
        muteObservation = nil
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    private func scheduleCleanupAfterTransition() {
        cleanupTask?.cancel()
        cleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.galleryIsDismissed,
                  !self.isPictureInPictureActive
            else {
                return
            }
            self.cleanupTask = nil
            self.detachAll()
            await MediaPlaybackAudioSession.deactivate()
        }
    }
}

private struct GalleryViewerMediaPage: View {
    let item: GalleryMediaItem
    @Binding var imageIsZoomed: Bool
    let playbackSuspended: Bool
    @ObservedObject var playbackController: GalleryPlaybackController
    let canMovePrevious: Bool
    let canMoveNext: Bool
    let movePrevious: () -> Void
    let moveNext: () -> Void
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
                playbackController: playbackController,
                canMovePrevious: canMovePrevious,
                canMoveNext: canMoveNext,
                movePrevious: movePrevious,
                moveNext: moveNext
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
    let canMovePrevious: Bool
    let canMoveNext: Bool
    let movePrevious: () -> Void
    let moveNext: () -> Void
    @State private var player: AVPlayer?
    @State private var looper: AVPlayerLooper?
    @State private var isSilent: Bool?
    @State private var playerReadyForDisplay = false
    @State private var pausedForBackground = false
    @State private var controlsVisible = true
    @State private var sliderSeconds: Double = 0
    @State private var sliderIsActive = false
    @AppStorage("postVideoBackgroundPlaybackEnabled")
    private var backgroundPlaybackEnabled = false

    var body: some View {
        ZStack {
            Color.black

            if let player {
                GalleryPlayerLayerView(
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

            if player != nil, playerReadyForDisplay {
                GalleryVideoInteractionLayer(
                    allowsSeeking: media.type == .video,
                    canMovePrevious: canMovePrevious,
                    canMoveNext: canMoveNext,
                    playbackController: playbackController,
                    movePrevious: movePrevious,
                    moveNext: moveNext,
                    toggleControls: {
                        withAnimation(.easeOut(duration: 0.16)) {
                            controlsVisible.toggle()
                        }
                    }
                )
            }

            if player != nil, controlsVisible,
               !playbackController.isPictureInPictureActive {
                GalleryVideoControlsOverlay(
                    isSilentMedia: isSilent == true,
                    sliderSeconds: $sliderSeconds,
                    sliderIsActive: $sliderIsActive,
                    playbackController: playbackController
                )
                .transition(.opacity)
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
                newPlayer.audiovisualBackgroundPlaybackPolicy = .pauses
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
                    newPlayer.audiovisualBackgroundPlaybackPolicy =
                        backgroundPlaybackEnabled && !silent
                            ? .continuesIfPossible
                            : .pauses
                    if backgroundPlaybackEnabled, !silent {
                        await MediaPlaybackAudioSession
                            .activateForBackgroundPlayback()
                    } else {
                        await MediaPlaybackAudioSession.activate(silent: true)
                    }
                } else {
                    await MediaPlaybackAudioSession.activate(silent: true)
                }
            }
            .onChange(of: backgroundPlaybackEnabled) { enabled in
                guard let player else { return }
                let continuesAudio = enabled && isSilent == false
                player.audiovisualBackgroundPlaybackPolicy =
                    continuesAudio ? .continuesIfPossible : .pauses
                Task {
                    if continuesAudio {
                        await MediaPlaybackAudioSession
                            .activateForBackgroundPlayback()
                    } else {
                        await MediaPlaybackAudioSession.activate(silent: true)
                    }
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
                                silent: backgroundPlaybackEnabled
                                    ? isSilent
                                    : true
                            )
                        }
                    }
                }
            }
            .onChange(of: playbackController.currentSeconds) { seconds in
                if !sliderIsActive {
                    sliderSeconds = seconds
                }
            }
            .onChange(
                of: playbackController.isPictureInPictureActive
            ) { active in
                guard !active else { return }
                Task {
                    if backgroundPlaybackEnabled, isSilent == false {
                        await MediaPlaybackAudioSession
                            .activateForBackgroundPlayback()
                    } else {
                        await MediaPlaybackAudioSession.activate(silent: true)
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
            }
    }
}

private struct GalleryVideoInteractionLayer: View {
    let allowsSeeking: Bool
    let canMovePrevious: Bool
    let canMoveNext: Bool
    @ObservedObject var playbackController: GalleryPlaybackController
    let movePrevious: () -> Void
    let moveNext: () -> Void
    let toggleControls: () -> Void

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                GalleryEdgePagingButton(
                    direction: .previous,
                    action: movePrevious
                )
                .frame(width: geometry.size.width / 10)
                .disabled(!canMovePrevious)

                HStack(spacing: 0) {
                    interactionHalf(seekSeconds: -5)
                    interactionHalf(seekSeconds: 5)
                }
                .simultaneousGesture(
                    scrubGesture(width: geometry.size.width),
                    including: allowsSeeking ? .gesture : .none
                )

                GalleryEdgePagingButton(
                    direction: .next,
                    action: moveNext
                )
                .frame(width: geometry.size.width / 10)
                .disabled(!canMoveNext)
            }
            .padding(.top, max(92, geometry.safeAreaInsets.top + 66))
        }
    }

    private func interactionHalf(seekSeconds: Double) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2)
                    .exclusively(before: SpatialTapGesture())
                    .onEnded { result in
                        switch result {
                        case .first(_):
                            guard allowsSeeking else { return }
                            playbackController.seek(by: seekSeconds)
                        case .second(_):
                            toggleControls()
                        }
                    }
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
}

private struct GalleryVideoControlsOverlay: View {
    let isSilentMedia: Bool
    @Binding var sliderSeconds: Double
    @Binding var sliderIsActive: Bool
    @ObservedObject var playbackController: GalleryPlaybackController

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                Spacer()

                Button {
                    playbackController.startPictureInPicture()
                } label: {
                    Image(systemName: "pip.enter")
                }
                .disabled(!playbackController.pictureInPictureAvailable)

                if !isSilentMedia {
                    Button {
                        playbackController.toggleMute()
                    } label: {
                        Image(
                            systemName: playbackController.isMuted
                                ? "speaker.slash.fill"
                                : "speaker.wave.2.fill"
                        )
                    }
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.top, 92)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .top
            )
            .buttonStyle(GalleryPlayerControlButtonStyle())

            Button {
                playbackController.togglePlayback()
            } label: {
                Image(
                    systemName: playbackController.isPlaying
                        ? "pause.fill"
                        : "play.fill"
                )
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 62, height: 62)
                .background(.black.opacity(0.52), in: Circle())
            }
            .foregroundStyle(.white)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .center
            )

            HStack(spacing: 10) {
                Text(timeText(sliderSeconds))
                Slider(
                    value: $sliderSeconds,
                    in: 0...max(
                        playbackController.durationSeconds,
                        0.1
                    ),
                    onEditingChanged: { editing in
                        sliderIsActive = editing
                        if editing {
                            playbackController.beginDirectSeeking()
                        } else {
                            playbackController.endDirectSeeking(
                                at: sliderSeconds
                            )
                        }
                    }
                )
                .tint(.white)
                Text(timeText(playbackController.durationSeconds))
            }
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .bottom
            )
        }
    }

    private func timeText(_ seconds: Double) -> String {
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

private struct GalleryPlayerControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 42, height: 42)
            .background(.black.opacity(0.52), in: Circle())
            .opacity(configuration.isPressed ? 0.58 : 1)
    }
}

private final class GalleryPlayerLayerHostView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

private struct GalleryPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    @Binding var isReadyForDisplay: Bool
    @ObservedObject var playbackController: GalleryPlaybackController

    func makeUIView(context: Context) -> GalleryPlayerLayerHostView {
        let view = GalleryPlayerLayerHostView()
        view.backgroundColor = .black
        view.playerLayer.backgroundColor = UIColor.black.cgColor
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(
        _ view: GalleryPlayerLayerHostView,
        context: Context
    ) {
        if view.playerLayer.player !== player {
            isReadyForDisplay = false
            view.playerLayer.player = player
            context.coordinator.observeReadiness(of: view.playerLayer)
            context.coordinator.configurePictureInPicture(
                for: view.playerLayer
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isReadyForDisplay: $isReadyForDisplay,
            playbackController: playbackController
        )
    }

    static func dismantleUIView(
        _ view: GalleryPlayerLayerHostView,
        coordinator: Coordinator
    ) {
        coordinator.detachAfterTransition()
    }

    final class Coordinator:
        NSObject,
        @preconcurrency AVPictureInPictureControllerDelegate {
        let playbackController: GalleryPlaybackController
        private var isReadyForDisplay: Binding<Bool>
        private weak var playerLayer: AVPlayerLayer?
        private var readinessObservation: NSKeyValueObservation?
        private var readinessHandoffTask: Task<Void, Never>?
        private var pictureInPictureController:
            AVPictureInPictureController?
        private var possibilityObservation: NSKeyValueObservation?
        private var teardownTask: Task<Void, Never>?
        private var teardownRequested = false
        private var manualPictureInPictureRequested = false
        private let pictureInPictureRegistrationID = UUID()

        init(
            isReadyForDisplay: Binding<Bool>,
            playbackController: GalleryPlaybackController
        ) {
            self.isReadyForDisplay = isReadyForDisplay
            self.playbackController = playbackController
        }

        @MainActor
        func attach(to view: GalleryPlayerLayerHostView) {
            teardownTask?.cancel()
            teardownTask = nil
            teardownRequested = false
            observeReadiness(of: view.playerLayer)
            configurePictureInPicture(for: view.playerLayer)
        }

        func observeReadiness(of layer: AVPlayerLayer) {
            guard playerLayer !== layer else { return }
            playerLayer = layer
            readinessObservation?.invalidate()
            readinessObservation = layer.observe(
                \.isReadyForDisplay,
                options: [.initial, .new]
            ) { [weak self] layer, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.readinessHandoffTask?.cancel()
                    guard layer.isReadyForDisplay else {
                        self.isReadyForDisplay.wrappedValue = false
                        return
                    }
                    self.readinessHandoffTask = Task { @MainActor [
                        weak self,
                        weak layer
                    ] in
                        try? await Task.sleep(
                            nanoseconds: 20_000_000
                        )
                        guard !Task.isCancelled,
                              let self,
                              layer?.isReadyForDisplay == true
                        else {
                            return
                        }
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            self.isReadyForDisplay.wrappedValue = true
                        }
                    }
                }
            }
        }

        @MainActor
        func configurePictureInPicture(for layer: AVPlayerLayer) {
            guard pictureInPictureController == nil,
                  AVPictureInPictureController
                    .isPictureInPictureSupported()
            else {
                return
            }
            guard let controller = AVPictureInPictureController(
                playerLayer: layer
            ) else {
                return
            }
            controller.delegate = self
            controller
                .canStartPictureInPictureAutomaticallyFromInline = false
            pictureInPictureController = controller
            possibilityObservation = controller.observe(
                \.isPictureInPicturePossible,
                options: [.initial, .new]
            ) { [weak self] controller, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.playbackController
                        .updatePictureInPicturePossible(
                            controller.isPictureInPicturePossible,
                            id: self.pictureInPictureRegistrationID
                        )
                }
            }
            playbackController.registerPictureInPicture(
                id: pictureInPictureRegistrationID,
                possible: controller.isPictureInPicturePossible,
                start: { [weak self] in
                    self?.startPictureInPicture()
                }
            )
        }

        @MainActor
        private func startPictureInPicture() {
            guard let controller = pictureInPictureController,
                  !controller.isPictureInPictureActive
            else {
                return
            }
            manualPictureInPictureRequested = true
            Task { @MainActor [weak controller] in
                await MediaPlaybackAudioSession
                    .activateForPictureInPicture()
                for _ in 0..<8 {
                    guard let controller else {
                        self.manualPictureInPictureRequested = false
                        return
                    }
                    if controller.isPictureInPicturePossible {
                        controller.startPictureInPicture()
                        return
                    }
                    try? await Task.sleep(
                        nanoseconds: 50_000_000
                    )
                }
                self.manualPictureInPictureRequested = false
            }
        }

        @MainActor
        func detachAfterTransition() {
            teardownRequested = true
            scheduleTeardown()
        }

        @MainActor
        private func scheduleTeardown() {
            teardownTask?.cancel()
            teardownTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled,
                      !self.playbackController
                        .isPictureInPictureActive
                else {
                    return
                }
                self.performDetach()
            }
        }

        @MainActor
        private func performDetach() {
            teardownTask = nil
            readinessHandoffTask?.cancel()
            readinessHandoffTask = nil
            readinessObservation?.invalidate()
            readinessObservation = nil
            possibilityObservation?.invalidate()
            possibilityObservation = nil
            pictureInPictureController?.delegate = nil
            pictureInPictureController = nil
            playerLayer?.player = nil
            playerLayer = nil
            playbackController.unregisterPictureInPicture(
                id: pictureInPictureRegistrationID
            )
        }

        @MainActor
        func pictureInPictureControllerWillStartPictureInPicture(
            _ pictureInPictureController:
                AVPictureInPictureController
        ) {
            guard manualPictureInPictureRequested else { return }
            playbackController.setPictureInPictureActive(true)
        }

        @MainActor
        func pictureInPictureControllerDidStartPictureInPicture(
            _ pictureInPictureController:
                AVPictureInPictureController
        ) {
            guard manualPictureInPictureRequested else {
                pictureInPictureController.stopPictureInPicture()
                return
            }
            playbackController.setPictureInPictureActive(true)
        }

        @MainActor
        func pictureInPictureControllerDidStopPictureInPicture(
            _ pictureInPictureController:
                AVPictureInPictureController
        ) {
            manualPictureInPictureRequested = false
            playbackController.setPictureInPictureActive(false)
            if teardownRequested {
                scheduleTeardown()
            }
        }

        @MainActor
        func pictureInPictureController(
            _ pictureInPictureController:
                AVPictureInPictureController,
            failedToStartPictureInPictureWithError error: Error
        ) {
            manualPictureInPictureRequested = false
            playbackController.setPictureInPictureActive(false)
            if teardownRequested {
                scheduleTeardown()
            }
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
        controller.updatesNowPlayingInfoCenter = false
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
        private var readinessHandoffTask: Task<Void, Never>?
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
                    guard let self else { return }
                    self.readinessHandoffTask?.cancel()
                    guard controller.isReadyForDisplay else {
                        self.isReadyForDisplay.wrappedValue = false
                        return
                    }
                    self.readinessHandoffTask = Task { @MainActor [
                        weak self,
                        weak controller
                    ] in
                        try? await Task.sleep(
                            nanoseconds: 20_000_000
                        )
                        guard !Task.isCancelled,
                              let self,
                              controller?.isReadyForDisplay == true
                        else {
                            return
                        }
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            self.isReadyForDisplay.wrappedValue = true
                        }
                    }
                }
            }
        }

        func attach(to controller: AVPlayerViewController) {
            playerViewController = controller
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: UIScene.willDeactivateNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.preventAutomaticPictureInPicture()
                    }
                },
                center.addObserver(
                    forName: UIApplication.willResignActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.preventAutomaticPictureInPicture()
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
            readinessHandoffTask?.cancel()
            readinessHandoffTask = nil
            readinessObservation?.invalidate()
            readinessObservation = nil
            playerViewController = nil
        }

        @MainActor
        private func preventAutomaticPictureInPicture() {
            guard !userStartedPictureInPicture else { return }
            playerViewController?
                .canStartPictureInPictureAutomaticallyFromInline = false
            playerViewController?.allowsPictureInPicturePlayback = false
        }

        @MainActor
        func playerViewControllerWillStartPictureInPicture(
            _ playerViewController: AVPlayerViewController
        ) {
            let explicitlyStartedWhileActive =
                UIApplication.shared.applicationState == .active
            userStartedPictureInPicture = explicitlyStartedWhileActive
            guard explicitlyStartedWhileActive else {
                playerViewController
                    .allowsPictureInPicturePlayback = false
                playbackController.setPictureInPictureActive(false)
                return
            }
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
