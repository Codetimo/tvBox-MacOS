import Foundation
import Combine

struct SearchSuggestion: Identifiable, Equatable {
    enum Source: String {
        case history = "搜索历史"
        case movie = "已加载影片"
        case channel = "频道"
        case group = "分组"
    }

    let text: String
    let source: Source
    var id: String { SearchSuggestionEngine.normalized(text) }
}

enum SearchSuggestionEngine {
    /// 合并本地候选并按完整匹配、前缀、包含排序；相同名称优先保留最近搜索历史。
    static func suggestions(query: String, history: [String], mediaNames: [String],
                            channelNames: [String], groupNames: [String], limit: Int = 8) -> [SearchSuggestion] {
        guard limit > 0 else { return [] }
        let keyword = normalized(query)
        let candidates = history.map { SearchSuggestion(text: $0, source: .history) }
            + (keyword.isEmpty ? [] : mediaNames.map { SearchSuggestion(text: $0, source: .movie) }
               + channelNames.map { SearchSuggestion(text: $0, source: .channel) }
               + groupNames.map { SearchSuggestion(text: $0, source: .group) })
        var seen = Set<String>()
        return candidates.enumerated().compactMap { index, candidate -> (SearchSuggestion, Int, Int)? in
            let name = normalized(candidate.text)
            guard !name.isEmpty, keyword.isEmpty || name.contains(keyword), seen.insert(name).inserted else { return nil }
            let rank = keyword.isEmpty || name == keyword ? 0 : (name.hasPrefix(keyword) ? 1 : 2)
            return (SearchSuggestion(text: candidate.text.trimmingCharacters(in: .whitespacesAndNewlines), source: candidate.source), rank, index)
        }.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1 }.prefix(limit).map { $0.0 }
    }

    /// 使用固定语言环境统一大小写、全半角和首尾空白，避免不同系统语言导致历史重复。
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

final class SearchHistoryStore: ObservableObject {
    @Published private(set) var entries: [String]
    private let defaults: UserDefaults
    private let key: String
    private let limit: Int

    /// 仅在本机保存有界历史；可注入独立 UserDefaults，测试不会污染用户数据。
    init(defaults: UserDefaults = .standard, key: String = "TVBoxMacOS.searchHistory", limit: Int = 30) {
        self.defaults = defaults
        self.key = key
        self.limit = max(0, limit)
        var seen = Set<String>()
        entries = (defaults.stringArray(forKey: key) ?? []).compactMap { value in
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(SearchSuggestionEngine.normalized(value)).inserted else { return nil }
            return value
        }.prefix(max(0, limit)).map { $0 }
    }

    /// 搜索提交时才记录，将重复关键词移到最前，输入过程不产生历史或网络请求。
    func record(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return }
        let normalized = SearchSuggestionEngine.normalized(query)
        entries = ([query] + entries.filter { SearchSuggestionEngine.normalized($0) != normalized }).prefix(limit).map { $0 }
        defaults.set(entries, forKey: key)
    }

    /// 清空本地历史及其持久化值。
    func clear() {
        entries = []
        defaults.removeObject(forKey: key)
    }
}
