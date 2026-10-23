import XCTest
@testable import TVBoxMacOS

final class SearchSuggestionTests: XCTestCase {
    func testRanksExactThenPrefixThenContainsAndKeepsHistorySource() {
        let suggestions = SearchSuggestionEngine.suggestions(query: "星际", history: ["重返星际", "星际穿越"],
                                                             mediaNames: ["星际", "星际穿越", "星际迷航"],
                                                             channelNames: [], groupNames: [])
        XCTAssertEqual(suggestions.map(\.text), ["星际", "星际穿越", "星际迷航", "重返星际"])
        XCTAssertEqual(suggestions[1].source, .history)
    }

    func testNormalizesWidthCaseWhitespaceAndDeduplicatesAcrossSources() {
        let suggestions = SearchSuggestionEngine.suggestions(query: " cctv ", history: ["ＣＣＴＶ1"],
                                                             mediaNames: [], channelNames: ["cctv1", "CCTV2"], groupNames: ["CCTV2"])
        XCTAssertEqual(suggestions.map(\.text), ["ＣＣＴＶ1", "CCTV2"])
        XCTAssertEqual(suggestions.map(\.source), [.history, .channel])
    }

    func testEmptyQueryOnlyShowsRecentHistoryAndRespectsLimit() {
        let suggestions = SearchSuggestionEngine.suggestions(query: " \n", history: ["最近", "更早"],
                                                             mediaNames: ["影片"], channelNames: ["频道"], groupNames: ["分组"], limit: 1)
        XCTAssertEqual(suggestions.map(\.text), ["最近"])
        XCTAssertEqual(SearchSuggestionEngine.suggestions(query: "", history: ["最近"], mediaNames: [], channelNames: [], groupNames: [], limit: 0), [])
    }

    func testNonMatchingQueryHasNoSuggestions() {
        XCTAssertTrue(SearchSuggestionEngine.suggestions(query: "未找到", history: ["最近"], mediaNames: ["影片"],
                                                         channelNames: ["频道"], groupNames: ["分组"]).isEmpty)
    }

    func testHistoryPersistsPromotesDuplicatesBoundsAndClears() throws {
        let suite = "SearchSuggestionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SearchHistoryStore(defaults: defaults, limit: 2)
        store.record("电影")
        store.record("CCTV")
        store.record(" cctv ")
        store.record(" \n ")
        XCTAssertEqual(store.entries, ["cctv", "电影"])
        store.record("最新")
        XCTAssertEqual(store.entries, ["最新", "cctv"])
        XCTAssertEqual(SearchHistoryStore(defaults: defaults, limit: 2).entries, store.entries)
        store.clear()
        XCTAssertEqual(SearchHistoryStore(defaults: defaults).entries, [])
    }

    func testRestoringHistoryDropsEmptyAndDuplicateEntries() throws {
        let suite = "SearchSuggestionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["  ", " CCTV ", "cctv", "电影", "较早"], forKey: "test")
        XCTAssertEqual(SearchHistoryStore(defaults: defaults, key: "test", limit: 2).entries, ["CCTV", "电影"])
    }
}
