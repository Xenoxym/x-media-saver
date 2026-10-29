import SwiftUI

struct BookmarkRulesView: View {
    @ObservedObject var store: BookmarkRuleStore
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
            BookmarkRuleEditor(store: store, rule: rule)
        }
        .alert("操作未完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

private struct BookmarkRuleEditor: View {
    @ObservedObject var store: BookmarkRuleStore
    let rule: BookmarkRuleCategory
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var hashtagText: String
    @State private var keywordText: String
    @State private var enabled: Bool
    @State private var errorMessage: String?

    init(store: BookmarkRuleStore, rule: BookmarkRuleCategory) {
        self.store = store
        self.rule = rule
        _name = State(initialValue: rule.name)
        _hashtagText = State(initialValue: rule.hashtags.joined(separator: "\n"))
        _keywordText = State(initialValue: rule.keywords.joined(separator: "\n"))
        _enabled = State(initialValue: rule.isEnabled)
    }

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
                } header: { Text("相关 Hashtag") }
                  footer: { Text("每行一个，也可用逗号分隔；有无 # 均可，按完整标签匹配。") }
                Section {
                    TextField("例如：风景、landscape", text: $keywordText, axis: .vertical)
                        .lineLimit(3...8).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("正文关键词") }
                  footer: { Text("每行一个词或短语，也可用逗号分隔。正文包含任一关键词即可归组，无需 Hashtag。") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("编辑规则分组")
            .navigationBarTitleDisplayMode(.inline)
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
}
