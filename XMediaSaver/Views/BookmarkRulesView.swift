import SwiftUI

struct BookmarkRulesView: View {
    @ObservedObject var store: BookmarkRuleStore
    let posts: [BookmarkedPost]
    @State private var editingRule: BookmarkRuleCategory?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Text("把相关 Hashtag 和正文关键词放入同一分组，任一命中即可归组；一个 Post 可以属于多个分组。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let error = store.loadError {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section("规则分组") {
                if store.rules.isEmpty {
                    Text("还没有规则分组，点击右上角加号创建。")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.rules) { rule in
                    Button { editingRule = rule } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(rule.name).foregroundStyle(.primary)
                                Spacer()
                                if !rule.isEnabled { Text("已停用").font(.caption).foregroundStyle(.secondary) }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(rule.hashtags.map { "#" + $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if !rule.keywords.isEmpty {
                                Text(rule.keywords.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }.buttonStyle(.plain)
                }
                .onDelete { offsets in
                    do { try store.remove(Set(offsets.map { store.rules[$0].id })) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
            Section {
                Text("规则保存在 App 文档目录的 rule-categories.json；清理缓存、索引或 Folder 媒体资料库不会删除规则。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("管理规则分组")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    editingRule = BookmarkRuleCategory(name: "", hashtags: [], keywords: [])
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("新建规则分组")
            }
        }
        .sheet(item: $editingRule) { rule in
            BookmarkRuleEditor(store: store, rule: rule, posts: posts)
        }
        .alert("操作未完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

private struct BookmarkRuleEditor: View {
    @ObservedObject var store: BookmarkRuleStore
    let rule: BookmarkRuleCategory
    let posts: [BookmarkedPost]
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var hashtagText: String
    @State private var keywordText: String
    @State private var enabled: Bool
    @State private var errorMessage: String?
    @State private var suggestionIndex: BookmarkSuggestionIndex?
    @State private var tagSuggestions: [BookmarkTermSuggestion] = []
    @State private var keywordSuggestions: [BookmarkTermSuggestion] = []
    @State private var showsTagPicker = false
    @State private var showsKeywordSuggestions = false
    @State private var isRecommending = false

    init(store: BookmarkRuleStore, rule: BookmarkRuleCategory, posts: [BookmarkedPost]) {
        self.store = store
        self.rule = rule
        self.posts = posts
        _name = State(initialValue: rule.name)
        _hashtagText = State(initialValue: rule.hashtags.joined(separator: "\n"))
        _keywordText = State(initialValue: rule.keywords.joined(separator: "\n"))
        _enabled = State(initialValue: rule.isEnabled)
    }

    private struct RecommendationInput: Hashable {
        let hashtags: String
        let keywords: String
        let ready: Bool
        let suggestKeywords: Bool
    }

    private var recommendationInput: RecommendationInput {
        RecommendationInput(hashtags: hashtagText, keywords: keywordText,
            ready: suggestionIndex != nil, suggestKeywords: showsKeywordSuggestions)
    }

    private var selectedTags: [String] { BookmarkRuleCategory.terms(from: hashtagText, hashtags: true) }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!BookmarkRuleCategory.terms(from: hashtagText, hashtags: true).isEmpty
                || !BookmarkRuleCategory.terms(from: keywordText, hashtags: false).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("分组名称", text: $name)
                    Toggle("启用分组", isOn: $enabled)
                }
                Section {
                    TextField("例如：travel、旅行", text: $hashtagText, axis: .vertical)
                        .lineLimit(3...8).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { showsTagPicker = true } label: {
                        Label("从已有 Hashtag 添加", systemImage: "tag.badge.plus")
                    }.disabled(suggestionIndex == nil)
                    if !tagSuggestions.isEmpty {
                        Text(selectedTags.isEmpty ? "常用标签" : "补全与相关标签")
                            .font(.caption).foregroundStyle(.secondary)
                        suggestionButtons(tagSuggestions, hashtag: true)
                    }
                } header: { Text("相关 Hashtag") }
                  footer: { Text("每行一个，也可用逗号分隔；有无 # 均可，按完整标签匹配。") }
                Section {
                    TextField("例如：风景、landscape", text: $keywordText, axis: .vertical)
                        .lineLimit(3...8).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { copyTagsToKeywords() } label: {
                        Label("将 Hashtag 复制到正文关键词", systemImage: "doc.on.doc")
                    }.disabled(selectedTags.isEmpty)
                    Button { showsKeywordSuggestions.toggle() } label: {
                        Label("推荐正文高频词", systemImage: "text.magnifyingglass")
                    }.disabled(selectedTags.isEmpty || suggestionIndex == nil)
                    if showsKeywordSuggestions {
                        if isRecommending { ProgressView() }
                        suggestionButtons(keywordSuggestions, hashtag: false)
                        Text("从包含已选 Hashtag 的帖子中按词出现的帖子数推荐；点击才会加入规则。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("正文关键词") }
                  footer: { Text("每行一个词或短语，也可用逗号分隔。正文包含任一关键词即可归组，无需 Hashtag。") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("编辑规则分组")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                let posts = posts
                let work = Task.detached(priority: .utility) { try BookmarkSuggestionIndex(posts: posts) }
                do {
                    let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                    guard !Task.isCancelled else { return }
                    suggestionIndex = result
                } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
            }
            .task(id: recommendationInput) { await updateRecommendations() }
            .sheet(isPresented: $showsTagPicker) {
                if let suggestionIndex {
                    ExistingHashtagPicker(index: suggestionIndex, selected: selectedTags, onSelect: addTag)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存规则") {
                        var updated = rule
                        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.hashtags = BookmarkRuleCategory.terms(from: hashtagText, hashtags: true)
                        updated.keywords = BookmarkRuleCategory.terms(from: keywordText, hashtags: false)
                        updated.isEnabled = enabled
                        do { try store.upsert(updated); dismiss() }
                        catch { errorMessage = error.localizedDescription }
                    }.disabled(!canSave)
                }
            }
        }
    }

    @ViewBuilder
    private func suggestionButtons(_ suggestions: [BookmarkTermSuggestion], hashtag: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
            ForEach(suggestions) { item in
                Button {
                    if hashtag { addTag(item.term) }
                    else { keywordText = mergeTerms(BookmarkRuleCategory.terms(from: keywordText, hashtags: false), [item.term]) }
                } label: {
                    HStack(spacing: 4) {
                        Text((hashtag ? "#" : "") + item.term).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text("\(item.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }.font(.caption).padding(7)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
        }
    }

    private func mergeTerms(_ original: [String], _ added: [String]) -> String {
        BookmarkRuleCategory.terms(from: (original + added).joined(separator: "\n"), hashtags: false).joined(separator: "\n")
    }

    private func copyTagsToKeywords() {
        keywordText = mergeTerms(BookmarkRuleCategory.terms(from: keywordText, hashtags: false), selectedTags)
    }

    private func addTag(_ term: String) {
        var tags = selectedTags
        if let last = tags.last, suggestionIndex?.tagCounts[BookmarkSearchDocument.normalizeTag(last)] == nil,
           BookmarkSearchDocument.normalizeTag(term).contains(BookmarkSearchDocument.normalizeTag(last)) {
            tags.removeLast()
        }
        hashtagText = BookmarkRuleCategory.terms(from: (tags + [term]).joined(separator: "\n"), hashtags: true).joined(separator: "\n") + "\n"
    }

    private func updateRecommendations() async {
        guard let index = suggestionIndex else { return }
        let input = recommendationInput
        do { try await Task.sleep(nanoseconds: 160_000_000) } catch { return }
        isRecommending = true
        defer { if recommendationInput == input { isRecommending = false } }
        let tags = selectedTags
        let keywords = BookmarkRuleCategory.terms(from: keywordText, hashtags: false)
        let last = tags.last ?? ""
        let query = index.tagCounts[BookmarkSearchDocument.normalizeTag(last)] == nil ? last : ""
        let work = Task.detached(priority: .utility) {
            let tags = try index.tags(query: query, selected: tags)
            let words = input.suggestKeywords ? try index.keywords(hashtags: BookmarkRuleCategory.terms(from: input.hashtags, hashtags: true), excluding: keywords) : []
            return (tags, words)
        }
        do {
            let (tags, words) = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, recommendationInput == input else { return }
            tagSuggestions = tags
            keywordSuggestions = words
        } catch { /* Editing cancels stale suggestions. */ }
    }
}

private struct ExistingHashtagPicker: View {
    let index: BookmarkSuggestionIndex
    let selected: [String]
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var rows: [BookmarkTermSuggestion] = []
    @State private var visibleLimit = 50
    @State private var added: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(rows.prefix(visibleLimit))) { item in
                    Button {
                        onSelect(item.term)
                        added.insert(item.term)
                    } label: {
                        HStack {
                            Text("#" + item.term).foregroundStyle(.primary)
                            Spacer()
                            Text("\(item.count)").foregroundStyle(.secondary).monospacedDigit()
                            if added.contains(item.term) || selected.map(BookmarkSearchDocument.normalizeTag).contains(item.term) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .onAppear { if item.id == rows.prefix(visibleLimit).last?.id { visibleLimit += 50 } }
                }
            }
            .searchable(text: $query, prompt: "搜索已有标签")
            .navigationTitle("已有 Hashtag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task(id: query) {
                let query = query
                let work = Task.detached(priority: .utility) { try index.tags(query: query, selected: [], limit: Int.max) }
                do {
                    let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                    guard !Task.isCancelled else { return }
                    rows = result; visibleLimit = 50
                } catch { }
            }
        }
    }
}
