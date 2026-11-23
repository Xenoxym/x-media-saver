import SwiftUI

@MainActor
struct VideoSimilarityView: View {
    let posts: [BookmarkedPost]

    @State private var criteria = VideoSimilarityPreset.parameters.criteria
    @State private var result: ScanResult?
    @State private var scanID: UUID?
    @State private var scanTask: Task<Void, Never>?
    @State private var showsScanError = false

    var body: some View {
        List {
            settingsSection
            scanSection
            if let result, result.criteria == criteria {
                resultsSection(result)
            }
        }
        .onChange(of: criteria) { _ in
            cancelScan()
            result = nil
            showsScanError = false
        }
        .onDisappear { cancelScan() }
    }

    private var settingsSection: some View {
        Section {
            Menu {
                ForEach(VideoSimilarityPreset.allCases) { preset in
                    Button {
                        criteria = preset.criteria
                    } label: {
                        if criteria == preset.criteria {
                            Label(preset.title, systemImage: "checkmark")
                        } else {
                            Text(preset.title)
                        }
                    }
                }
            } label: {
                HStack {
                    Text("比较预设")
                    Spacer()
                    Text(selectedPresetTitle)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                }
            }
            Picker("画面尺寸", selection: $criteria.size) {
                ForEach(VideoSimilaritySizeRule.allCases) { rule in
                    Text(rule.title).tag(rule)
                }
            }
            Picker("视频时长", selection: $criteria.duration) {
                ForEach(VideoSimilarityDurationRule.allCases) { rule in
                    Text(rule.title).tag(rule)
                }
            }
            Picker("封面", selection: $criteria.poster) {
                ForEach(VideoSimilarityPosterRule.allCases) { rule in
                    Text(rule.title).tag(rule)
                }
            }
        } header: {
            Text("匹配条件")
        } footer: {
            Text("候选视频必须同时满足所有启用的条件。缺少所需信息的视频不参与该项匹配。")
        }
    }

    private var scanSection: some View {
        Section {
            if scanID != nil {
                HStack {
                    ProgressView()
                    Text("正在比较视频…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { cancelScan() }
                        .buttonStyle(.borderless)
                }
            } else {
                Button(action: startScan) {
                    Label("扫描相似视频", systemImage: "magnifyingglass")
                }
                .disabled(!hasActiveCriteria)
            }
            if !hasActiveCriteria {
                Text("请至少启用一项匹配条件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if showsScanError {
                Text("无法完成比较，请重试。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } footer: {
            Text("仅使用索引信息和本机已有的封面指纹；不联网、不下载视频，也不会删除或合并文件。")
        }
    }

    private func resultsSection(_ result: ScanResult) -> some View {
        Section {
            resultCoverage(result)
            if result.matches.isEmpty {
                Text("没有找到满足条件的视频对。")
                    .foregroundStyle(.secondary)
            }
            ForEach(result.matches) { match in
                NavigationLink {
                    VideoSimilarityPairView(
                        match: match,
                        firstPosts: result.references[match.first.id] ?? [],
                        secondPosts: result.references[match.second.id] ?? [],
                        relatedPosts: posts
                    )
                } label: {
                    pairRow(match, references: result.references)
                }
            }
        } header: {
            Text(L10n.format("%lld 对候选视频", result.matches.count))
        }
    }

    private func resultCoverage(_ result: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if result.truncated {
                Text("结果已达显示上限，可缩小条件后重新扫描。")
            }
            Text(L10n.format(
                "已检查 %lld 个视频 · 已知尺寸 %lld · 已知时长 %lld",
                result.videoCount, result.dimensionsCount, result.durationCount
            ))
            Text(L10n.format(
                "有封面地址 %lld · 有本地封面指纹 %lld",
                result.posterURLCount, result.fingerprintCount
            ))
            if result.criteria.poster == .similar && result.fingerprintCount < result.videoCount {
                Text("没有本地封面指纹时，无法按画面比较不同封面地址。")
            }
            Text("候选仅供核对，不代表同一视频。")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func pairRow(
        _ match: VideoSimilarityMatch, references: [String: [BookmarkedPost]]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "video")
                VideoSimilarityMetadata(descriptor: match.first, source: references[match.first.id]?.first)
                Image(systemName: "arrow.left.arrow.right")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                VideoSimilarityMetadata(descriptor: match.second, source: references[match.second.id]?.first)
            }
            Text(match.evidence.map(\.title).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            if match.possiblePreview {
                Label("可能是预览片段", systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var selectedPresetTitle: String {
        VideoSimilarityPreset.allCases.first { $0.criteria == criteria }?.title
            ?? L10n.string("自定义条件")
    }

    private var hasActiveCriteria: Bool {
        criteria.size != .any || criteria.duration != .any || criteria.poster != .any
    }

    private func startScan() {
        guard scanID == nil, hasActiveCriteria else { return }
        let id = UUID()
        let input = criteria
        let sourcePosts = posts
        scanID = id
        showsScanError = false
        result = nil
        scanTask = Task { @MainActor in
            let worker = Task.detached(priority: .utility) {
                try await Self.scan(posts: sourcePosts, criteria: input)
            }
            defer {
                if scanID == id {
                    scanID = nil
                    scanTask = nil
                }
            }
            do {
                let found = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, scanID == id, criteria == input else { return }
                result = found
            } catch is CancellationError {
                // Cancellation is a normal way to change the search or leave.
            } catch {
                if !Task.isCancelled, scanID == id { showsScanError = true }
            }
        }
    }

    private func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanID = nil
    }

    private nonisolated static func scan(
        posts: [BookmarkedPost], criteria: VideoSimilarityCriteria
    ) async throws -> ScanResult {
        var videos: [BookmarkedMedia] = []
        for post in posts {
            try Task.checkCancellation()
            videos.append(contentsOf: post.media.filter { $0.type == .video })
        }

        let descriptors = await VideoPosterFingerprints.shared.descriptors(for: videos)
        try Task.checkCancellation()
        let scan = try VideoSimilarityMatcher.scan(descriptors, criteria: criteria)
        let matchedKeys = Set(scan.matches.flatMap { [$0.first.id, $0.second.id] })
        var references: [String: [BookmarkedPost]] = [:]
        var seenReferences: [String: Set<String>] = [:]
        for post in posts {
            try Task.checkCancellation()
            for media in post.media where matchedKeys.contains(media.mediaKey) {
                guard seenReferences[media.mediaKey, default: []].insert(post.id).inserted else { continue }
                references[media.mediaKey, default: []].append(post)
            }
        }
        return ScanResult(
            criteria: criteria,
            matches: scan.matches,
            truncated: scan.truncated,
            references: references,
            videoCount: descriptors.count,
            dimensionsCount: descriptors.lazy.filter { ($0.width ?? 0) > 0 && ($0.height ?? 0) > 0 }.count,
            durationCount: descriptors.lazy.filter { ($0.durationMilliseconds ?? 0) > 0 }.count,
            posterURLCount: descriptors.lazy.filter { $0.posterIdentity != nil }.count,
            fingerprintCount: descriptors.lazy.filter { $0.posterFingerprint != nil }.count
        )
    }

    private struct ScanResult: Sendable {
        let criteria: VideoSimilarityCriteria
        let matches: [VideoSimilarityMatch]
        let truncated: Bool
        let references: [String: [BookmarkedPost]]
        let videoCount: Int
        let dimensionsCount: Int
        let durationCount: Int
        let posterURLCount: Int
        let fingerprintCount: Int
    }
}

private struct VideoSimilarityMetadata: View {
    let descriptor: VideoSimilarityDescriptor
    var source: BookmarkedPost? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(dimensions)
                .font(.subheadline.monospacedDigit())
            Text(duration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let source {
                Text(sourceCue(for: source))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceCue(for post: BookmarkedPost) -> String {
        let author = post.authorUsername.map { "@" + $0 } ?? post.authorName ?? post.id
        let text = post.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? author : author + " · " + text
    }

    private var dimensions: String {
        if let width = descriptor.width, let height = descriptor.height, width > 0, height > 0 {
            return "\(width) × \(height)"
        }
        return L10n.string("尺寸未知")
    }

    private var duration: String {
        guard let milliseconds = descriptor.durationMilliseconds, milliseconds > 0 else {
            return L10n.string("时长未知")
        }
        let seconds = milliseconds / 1_000
        let remainder = milliseconds % 1_000
        let minutes = seconds / 60
        let clock = "\(minutes):" + String(format: "%02d", seconds % 60)
        return remainder == 0 ? clock : clock + String(format: ".%03d", remainder)
    }
}

@MainActor
private struct VideoSimilarityPairView: View {
    let match: VideoSimilarityMatch
    let firstPosts: [BookmarkedPost]
    let secondPosts: [BookmarkedPost]
    let relatedPosts: [BookmarkedPost]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var verification: VerificationState = .idle
    @State private var verificationTask: Task<Void, Never>?
    @State private var verificationID: UUID?

    private enum VerificationState {
        case idle
        case unavailable
        case finished(VideoFrameVerification)
        case failed
    }

    var body: some View {
        List {
            Section("对比候选视频") {
                pairCards
                ForEach(Array(match.evidence.enumerated()), id: \.offset) { entry in
                    Label(entry.element.title, systemImage: "checkmark.circle")
                        .font(.subheadline)
                }
                if match.possiblePreview {
                    Label("可能是预览片段", systemImage: "scissors")
                        .foregroundStyle(.orange)
                    Text("封面匹配，短版至少短 2 秒，且不超过长版时长的 80%。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                verificationRow
                verificationResult
            } header: {
                Text("本地抽帧验证")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("只读取两个已保存的 Folder 视频。抽样结果不证明整段内容相同。")
                    if match.possiblePreview {
                        Text("预览模式只对比长版开头对应的时间点。")
                    }
                }
            }
            postSection("视频 A 的来源帖", posts: firstPosts)
            postSection("视频 B 的来源帖", posts: secondPosts)
        }
        .navigationTitle("候选详情")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { cancelVerification() }
    }

    private var pairCards: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        return layout {
            videoCard("视频 A", descriptor: match.first)
            videoCard("视频 B", descriptor: match.second)
        }
    }

    private func videoCard(
        _ title: LocalizedStringKey, descriptor: VideoSimilarityDescriptor
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "video")
                .font(.subheadline.weight(.semibold))
            VideoSimilarityMetadata(descriptor: descriptor)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func postSection(_ title: LocalizedStringKey, posts: [BookmarkedPost]) -> some View {
        Section(title) {
            if posts.isEmpty {
                Text("索引中没有关联的帖子。")
                    .foregroundStyle(.secondary)
            }
            ForEach(posts) { post in
                NavigationLink {
                    BookmarkPostDetailView(post: post, relatedPosts: relatedPosts)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(post.authorName ?? post.authorUsername ?? post.id)
                            .font(.subheadline.weight(.semibold))
                        if !post.text.isEmpty {
                            Text(post.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var verificationRow: some View {
        if verificationID != nil {
            HStack {
                ProgressView()
                Text("正在抽帧对比…")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { cancelVerification() }
                    .buttonStyle(.borderless)
            }
        } else {
            Button(action: verify) {
                Label("验证本地视频", systemImage: "film")
            }
        }
    }

    @ViewBuilder
    private var verificationResult: some View {
        switch verification {
        case .idle:
            EmptyView()
        case .unavailable:
            Text("至少一个视频未保存到 Folder 或文件已不可读。")
                .foregroundStyle(.secondary)
        case .failed:
            Text("无法比较这两个本地视频的帧。")
                .foregroundStyle(.orange)
        case .finished(let value):
            if value.comparedFrames == 0 {
                Text("未取得可比较的抽样帧。")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.format("抽样对比：%lld / %lld 帧相符", value.matchedFrames, value.comparedFrames))
                    if value.matchedFrames >= 2 {
                        Text("采样画面相近；未验证其他部分。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func verify() {
        guard verificationID == nil else { return }
        let id = UUID()
        verification = .idle
        verificationID = id
        verificationTask = Task { @MainActor in
            defer {
                if verificationID == id {
                    verificationID = nil
                    verificationTask = nil
                }
            }
            do {
                let first = await LocalMediaLibrary.shared.localURL(for: match.first.id)
                try Task.checkCancellation()
                let second = await LocalMediaLibrary.shared.localURL(for: match.second.id)
                try Task.checkCancellation()
                guard let first, let second, first.isFileURL, second.isFileURL else {
                    if verificationID == id { verification = .unavailable }
                    return
                }
                let value = try await VideoSimilarityFrameVerifier.verify(
                    first: first, second: second, preview: match.possiblePreview
                )
                guard !Task.isCancelled, verificationID == id else { return }
                verification = .finished(value)
            } catch is CancellationError {
                // No result from an incomplete check.
            } catch {
                if !Task.isCancelled, verificationID == id { verification = .failed }
            }
        }
    }

    private func cancelVerification() {
        verificationTask?.cancel()
        verificationTask = nil
        verificationID = nil
    }
}

private extension VideoSimilarityPreset {
    var title: String {
        switch self {
        case .parameters: return L10n.string("参数一致")
        case .qualityVersions: return L10n.string("疑似不同画质")
        case .previewVersions: return L10n.string("疑似预览片段")
        }
    }
}

private extension VideoSimilaritySizeRule {
    var title: String {
        switch self {
        case .exactPixels: return L10n.string("像素尺寸相同")
        case .exactAspect: return L10n.string("宽高比相同")
        case .nearAspect: return L10n.string("宽高比差 ≤ 1%")
        case .any: return L10n.string("不作为条件")
        }
    }
}

private extension VideoSimilarityDurationRule {
    var title: String {
        switch self {
        case .exact: return L10n.string("时长完全相同")
        case .close: return L10n.string("时长差 ≤ 200 毫秒")
        case .relaxed: return L10n.string("时长差 ≤ 1 秒")
        case .any: return L10n.string("不作为条件")
        }
    }
}

private extension VideoSimilarityPosterRule {
    var title: String {
        switch self {
        case .sameURL: return L10n.string("封面地址相同")
        case .similar: return L10n.string("封面画面相似或同地址")
        case .any: return L10n.string("不作为条件")
        }
    }
}

private extension VideoSimilarityEvidence {
    var title: String {
        switch self {
        case .exactPixels: return L10n.string("像素尺寸相同")
        case .exactAspect: return L10n.string("宽高比相同")
        case .nearAspect: return L10n.string("宽高比差 ≤ 1%")
        case .exactDuration: return L10n.string("时长完全相同")
        case .closeDuration: return L10n.string("时长差 ≤ 200 毫秒")
        case .relaxedDuration: return L10n.string("时长差 ≤ 1 秒")
        case .samePosterURL: return L10n.string("封面地址相同")
        case .similarPoster: return L10n.string("封面画面相似")
        }
    }
}
