import Foundation

enum VideoSimilaritySizeRule: String, CaseIterable, Identifiable, Sendable {
    case exactPixels, exactAspect, nearAspect, any
    var id: String { rawValue }
}

enum VideoSimilarityDurationRule: String, CaseIterable, Identifiable, Sendable {
    case exact, close, relaxed, any
    var id: String { rawValue }

    fileprivate static let closeMaximumDelta = 200
    fileprivate static let relaxedMaximumDelta = 1_000

    fileprivate var maximumDelta: Int? {
        switch self {
        case .exact: return 0
        case .close: return Self.closeMaximumDelta
        case .relaxed: return Self.relaxedMaximumDelta
        case .any: return nil
        }
    }
}

enum VideoSimilarityPosterRule: String, CaseIterable, Identifiable, Sendable {
    case sameURL, similar, any
    var id: String { rawValue }
}

struct VideoSimilarityCriteria: Equatable, Sendable {
    var size: VideoSimilaritySizeRule
    var duration: VideoSimilarityDurationRule
    var poster: VideoSimilarityPosterRule
    var requiresUsablePoster = false
}

enum VideoSimilarityPreset: String, CaseIterable, Identifiable, Sendable {
    case parameters, qualityVersions, previewVersions
    var id: String { rawValue }

    var criteria: VideoSimilarityCriteria {
        switch self {
        case .parameters: return .init(size: .exactPixels, duration: .exact, poster: .any)
        case .qualityVersions: return .init(size: .exactAspect, duration: .close, poster: .any)
        case .previewVersions: return .init(size: .any, duration: .any, poster: .similar)
        }
    }
}

struct VideoSimilarityDescriptor: Sendable {
    let id: String
    let width: Int?
    let height: Int?
    let durationMilliseconds: Int?
    let posterIdentity: String?
    let posterFingerprint: UInt64?

    init(
        id: String,
        width: Int?,
        height: Int?,
        durationMilliseconds: Int?,
        posterIdentity: String?,
        posterFingerprint: UInt64?
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.durationMilliseconds = durationMilliseconds
        self.posterIdentity = posterIdentity
        self.posterFingerprint = posterFingerprint
    }
}

enum VideoSimilarityEvidence: String, Sendable {
    case exactPixels, exactAspect, nearAspect
    case exactDuration, closeDuration, relaxedDuration
    case samePosterURL, similarPoster

    fileprivate var weight: Int {
        switch self {
        case .exactPixels, .exactDuration: return 3
        case .exactAspect, .closeDuration: return 2
        case .nearAspect, .relaxedDuration: return 1
        case .samePosterURL: return 20
        case .similarPoster: return 10
        }
    }
}

struct VideoSimilarityMatch: Identifiable, Sendable {
    let first: VideoSimilarityDescriptor
    let second: VideoSimilarityDescriptor
    let evidence: [VideoSimilarityEvidence]

    var id: String { "\(first.id.utf8.count):\(first.id)\(second.id)" }

    var possiblePreview: Bool {
        guard evidence.contains(.samePosterURL) || evidence.contains(.similarPoster),
              let firstLength = first.durationMilliseconds, firstLength > 0,
              let secondLength = second.durationMilliseconds, secondLength > 0
        else { return false }
        let shorter = min(firstLength, secondLength)
        let longer = max(firstLength, secondLength)
        let difference = longer - shorter
        // Ceil(longer / 5), without a multiplying cross product.
        let fifth = longer / 5 + (longer % 5 == 0 ? 0 : 1)
        return difference >= 2_000 && difference >= fifth
    }
}

struct VideoSimilarityGroup: Identifiable, Sendable {
    let reference: VideoSimilarityDescriptor
    let matches: [VideoSimilarityMatch]

    var id: String { reference.id }
    var members: [VideoSimilarityDescriptor] {
        [reference] + matches.map { $0.first.id == id ? $0.second : $0.first }
    }
}

enum VideoSimilarityMatcher {
    static func groups(
        _ descriptors: [VideoSimilarityDescriptor], criteria: VideoSimilarityCriteria
    ) throws -> [VideoSimilarityGroup] {
        guard criteria.size != .any || criteria.duration != .any || criteria.poster != .any else { return [] }
        var seen = Set<String>()
        let candidates = descriptors.sorted {
            let a = $0.posterFingerprint != nil
            let b = $1.posterFingerprint != nil
            return a == b ? $0.id < $1.id : a
        }.compactMap { descriptor -> Candidate? in
            guard seen.insert(descriptor.id).inserted,
                  !criteria.requiresUsablePoster || descriptor.posterFingerprint != nil else { return nil }
            let candidate = Candidate(descriptor)
            guard criteria.size == .any || candidate.pixels != nil,
                  criteria.duration == .any || candidate.duration != nil else { return nil }
            return candidate
        }
        var assigned = Set<String>()
        var groups: [VideoSimilarityGroup] = []
        for (index, anchor) in candidates.enumerated() {
            try Task.checkCancellation()
            guard !assigned.contains(anchor.descriptor.id) else { continue }
            var matches: [VideoSimilarityMatch] = []
            for next in (index + 1)..<candidates.count {
                if next.isMultiple(of: 256) { try Task.checkCancellation() }
                let candidate = candidates[next]
                guard !assigned.contains(candidate.descriptor.id),
                      let pair = matchingPair(anchor, candidate, criteria: criteria, commonPosters: [])
                else { continue }
                assigned.insert(candidate.descriptor.id)
                matches.append(pair.match)
            }
            if !matches.isEmpty {
                groups.append(.init(reference: anchor.descriptor, matches: matches))
            }
        }
        return groups.sorted {
            $0.matches.count == $1.matches.count ? $0.id < $1.id : $0.matches.count > $1.matches.count
        }
    }
    static func scan(
        _ candidates: [VideoSimilarityDescriptor],
        criteria: VideoSimilarityCriteria,
        limit: Int = 400
    ) throws -> (matches: [VideoSimilarityMatch], truncated: Bool) {
        try Task.checkCancellation()
        guard criteria.size != .any || criteria.duration != .any || criteria.poster != .any
        else { return ([], false) }

        let durationWindow = criteria.duration.maximumDelta
        var seen: Set<String> = []
        var countedPosterIDs: Set<String> = []
        var posterCounts: [String: Int] = [:]
        var prepared: [Candidate] = []
        for descriptor in candidates {
            try Task.checkCancellation()
            let candidate = Candidate(descriptor)
            if let poster = candidate.posterIdentity, countedPosterIDs.insert(descriptor.id).inserted {
                posterCounts[poster, default: 0] += 1
            }
            guard criteria.size == .any || candidate.pixels != nil,
                  !criteria.requiresUsablePoster || descriptor.posterFingerprint != nil,
                  durationWindow == nil || candidate.duration != nil,
                  criteria.poster == .any || candidate.posterIdentity != nil
                    || (criteria.poster == .similar && descriptor.posterFingerprint != nil),
                  seen.insert(descriptor.id).inserted
            else { continue }
            prepared.append(candidate)
        }
        let commonPosters = Set(posterCounts.compactMap { $0.value >= 8 ? $0.key : nil })

        // An exact condition can put candidates in disjoint buckets. For duration
        // filters, scan only the relevant sorted time window within each bucket.
        let buckets: [[Candidate]]
        if criteria.poster == .sameURL {
            buckets = grouped(prepared) { $0.posterIdentity }
        } else if criteria.size == .exactPixels {
            buckets = grouped(prepared) { $0.pixels }
        } else if criteria.size == .exactAspect {
            buckets = grouped(prepared) { $0.aspect }
        } else {
            buckets = [prepared]
        }

        var best = BestPairs(limit: max(0, limit))
        for bucket in buckets where bucket.count >= 2 {
            try Task.checkCancellation()
            let entries = durationWindow == nil ? bucket : bucket.sorted {
                ($0.duration ?? 0) < ($1.duration ?? 0)
            }
            for i in 0..<(entries.count - 1) {
                try Task.checkCancellation()
                let first = entries[i]
                for j in (i + 1)..<entries.count {
                    if j.isMultiple(of: 256) { try Task.checkCancellation() }
                    let second = entries[j]
                    if let durationWindow, let a = first.duration, let b = second.duration,
                       b - a > durationWindow { break }
                    if let pair = matchingPair(first, second, criteria: criteria, commonPosters: commonPosters) {
                        best.offer(pair)
                    }
                }
            }
        }
        try Task.checkCancellation()
        return (best.pairs.sorted(by: RankedPair.ranksBefore).map(\.match), best.truncated)
    }

    private struct Dimensions: Hashable {
        let width: Int
        let height: Int

        var reduced: Dimensions {
            var a = width
            var b = height
            while b != 0 { (a, b) = (b, a % b) }
            return .init(width: width / a, height: height / a)
        }
    }

    private struct Candidate {
        let descriptor: VideoSimilarityDescriptor
        let pixels: Dimensions?
        let aspect: Dimensions?
        let ratio: Double?
        let duration: Int?
        let posterIdentity: String?

        init(_ descriptor: VideoSimilarityDescriptor) {
            self.descriptor = descriptor
            if let width = descriptor.width, let height = descriptor.height, width > 0, height > 0 {
                let dimensions = Dimensions(width: width, height: height)
                pixels = dimensions
                aspect = dimensions.reduced
                ratio = Double(width) / Double(height)
            } else {
                pixels = nil
                aspect = nil
                ratio = nil
            }
            duration = descriptor.durationMilliseconds.flatMap { $0 > 0 ? $0 : nil }
            posterIdentity = descriptor.posterIdentity.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    private static func grouped<Key: Hashable>(
        _ entries: [Candidate],
        key: (Candidate) -> Key?
    ) -> [[Candidate]] {
        var result: [Key: [Candidate]] = [:]
        for entry in entries {
            if let bucket = key(entry) { result[bucket, default: []].append(entry) }
        }
        return Array(result.values)
    }

    private static func matchingPair(
        _ first: Candidate,
        _ second: Candidate,
        criteria: VideoSimilarityCriteria,
        commonPosters: Set<String>
    ) -> RankedPair? {
        let size: VideoSimilarityEvidence?
        if let a = first.pixels, let b = second.pixels, a == b {
            size = .exactPixels
        } else if let a = first.aspect, let b = second.aspect, a == b {
            size = .exactAspect
        } else if let a = first.ratio, let b = second.ratio,
                  abs(a - b) / max(a, b) <= 0.01 + 8 * Double.ulpOfOne {
            size = .nearAspect
        } else {
            size = nil
        }
        switch criteria.size {
        case .exactPixels: guard size == .exactPixels else { return nil }
        case .exactAspect: guard size == .exactPixels || size == .exactAspect else { return nil }
        case .nearAspect: guard size != nil else { return nil }
        case .any: break
        }

        let time: VideoSimilarityEvidence?
        if let a = first.duration, let b = second.duration {
            let delta = max(a, b) - min(a, b)
            if delta == 0 {
                time = .exactDuration
            } else if delta <= VideoSimilarityDurationRule.closeMaximumDelta {
                time = .closeDuration
            } else if delta <= VideoSimilarityDurationRule.relaxedMaximumDelta {
                time = .relaxedDuration
            } else {
                time = nil
            }
        } else {
            time = nil
        }
        switch criteria.duration {
        case .exact: guard time == .exactDuration else { return nil }
        case .close: guard time == .exactDuration || time == .closeDuration else { return nil }
        case .relaxed: guard time != nil else { return nil }
        case .any: break
        }

        let poster: VideoSimilarityEvidence?
        var commonPoster = false
        if let a = first.posterIdentity, let b = second.posterIdentity, a == b,
           !criteria.requiresUsablePoster {
            poster = .samePosterURL
            commonPoster = commonPosters.contains(a)
        } else if let a = first.descriptor.posterFingerprint, let b = second.descriptor.posterFingerprint,
                  (a ^ b).nonzeroBitCount <= VideoPerceptualFingerprint.matchingDistance {
            let sharedAddress = first.posterIdentity != nil && first.posterIdentity == second.posterIdentity
            poster = sharedAddress ? .samePosterURL : .similarPoster
            commonPoster = sharedAddress && commonPosters.contains(first.posterIdentity ?? "")
        } else {
            poster = nil
        }
        switch criteria.poster {
        case .sameURL: guard poster == .samePosterURL else { return nil }
        case .similar: guard poster != nil else { return nil }
        case .any: break
        }

        let a = first.descriptor
        let b = second.descriptor
        return RankedPair(
            first: a.id < b.id ? a : b,
            second: a.id < b.id ? b : a,
            size: size, time: time, poster: poster, commonPoster: commonPoster
        )
    }

    // Keep one evidence value per dimension; allocate evidence arrays only for
    // the matches we return, not for every eligible pair in a popular bucket.
    private struct RankedPair {
        let first: VideoSimilarityDescriptor
        let second: VideoSimilarityDescriptor
        let size: VideoSimilarityEvidence?
        let time: VideoSimilarityEvidence?
        let poster: VideoSimilarityEvidence?
        let score: Int

        init(
            first: VideoSimilarityDescriptor, second: VideoSimilarityDescriptor,
            size: VideoSimilarityEvidence?, time: VideoSimilarityEvidence?,
            poster: VideoSimilarityEvidence?, commonPoster: Bool
        ) {
            self.first = first
            self.second = second
            self.size = size
            self.time = time
            self.poster = poster
            // A widely reused cover is still evidence, but weak enough to
            // leave room for more informative matches at the result cap.
            score = (size?.weight ?? 0) + (time?.weight ?? 0) + (commonPoster ? 2 : (poster?.weight ?? 0))
        }

        static func ranksBefore(_ a: RankedPair, _ b: RankedPair) -> Bool {
            if a.score != b.score { return a.score > b.score }
            if a.first.id != b.first.id { return a.first.id < b.first.id }
            return a.second.id < b.second.id
        }

        var match: VideoSimilarityMatch {
            var evidence: [VideoSimilarityEvidence] = []
            if let size { evidence.append(size) }
            if let time { evidence.append(time) }
            if let poster { evidence.append(poster) }
            return .init(first: first, second: second, evidence: evidence)
        }
    }

    // The root is the weakest retained pair. The result cap bounds memory even
    // when many videos share the same metadata or cover.
    private struct BestPairs {
        let limit: Int
        private(set) var pairs: [RankedPair] = []
        private(set) var truncated = false

        mutating func offer(_ pair: RankedPair) {
            if pairs.count < limit {
                pairs.append(pair)
                var child = pairs.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    guard RankedPair.ranksBefore(pairs[parent], pairs[child]) else { break }
                    pairs.swapAt(parent, child)
                    child = parent
                }
                return
            }
            truncated = true
            guard let weakest = pairs.first, RankedPair.ranksBefore(pair, weakest) else { return }
            pairs[0] = pair
            var parent = 0
            while parent < pairs.count / 2 {
                let left = parent * 2 + 1
                let right = left + 1
                let weakerChild = right < pairs.count && RankedPair.ranksBefore(pairs[left], pairs[right])
                    ? right : left
                guard RankedPair.ranksBefore(pairs[parent], pairs[weakerChild]) else { break }
                pairs.swapAt(parent, weakerChild)
                parent = weakerChild
            }
        }
    }
}
