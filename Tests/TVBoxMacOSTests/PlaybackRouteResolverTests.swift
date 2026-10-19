import XCTest
@testable import TVBoxMacOS

final class PlaybackRouteResolverTests: XCTestCase {
    private let resolved = ResolvedMediaPlayback(url: URL(string: "https://cdn.example/movie.mp4")!, headers: [:], isDirect: true)

    /// 构造同一站点不同线路的剧集，保持与目录解析器相同的名称结构。
    private func source(_ flag: String, _ episode: String) -> TVPlaySource {
        TVPlaySource(name: "\(flag) · \(episode)", url: nil, playerID: episode, flag: flag)
    }

    func testStorageErrorWithEmptyURLPreservesActualCause() throws {
        for url in [NSNull(), ""] as [Any] {
            let data = try JSONSerialization.data(withJSONObject: ["url": url, "msg": "[quark](task) 夸克网盘空间不足，请清理空间后重试"])
            XCTAssertThrowsError(try SourceLoader.parseSpiderPlayback(data: data)) { error in
                guard case .insufficientStorage = error as? SpiderPlaybackFailure else { return XCTFail("Expected quota error") }
                XCTAssertFalse(error.localizedDescription.contains("需要授权"))
                XCTAssertTrue(error.localizedDescription.contains("空间不足"))
            }
        }
    }

    func testSingleMovieFallsBackFromQuarkToBaiduDespiteDifferentFilenames() async throws {
        let quark = source("夸克原画", "[一人之下 番外篇][天师下山].mp4")
        let baidu = source("百度原画", "番外篇：天师下山.mp4")
        var calls: [TVPlaySource] = []
        let result = try await PlaybackRouteResolver.resolve(source: quark, sources: [quark, baidu]) { candidate in
            calls.append(candidate)
            if candidate == quark { throw SpiderPlaybackFailure.insufficientStorage("夸克网盘空间不足") }
            return self.resolved
        }
        XCTAssertEqual(calls, [quark, baidu])
        XCTAssertEqual(result.source, baidu)
        XCTAssertTrue(result.notice?.contains("已切换到百度原画") == true)
    }

    func testSeriesNeverFallsBackToAnotherEpisodeOrAnotherQuarkQuality() {
        let selected = source("夸克原画", "第02集")
        let correct = source("百度原画", "第02集")
        let candidates = [source("夸克原画", "第01集"), selected,
                          source("夸克超清", "第02集"), source("百度原画", "第01集"), correct]
        XCTAssertEqual(PlaybackRouteResolver.alternatives(for: selected, in: candidates), [correct])
        XCTAssertTrue(PlaybackRouteResolver.alternatives(for: selected, in: candidates.filter { $0 != correct }).isEmpty)
    }

    func testAuthorizationErrorDoesNotTriggerStorageFallback() async {
        let first = source("夸克原画", "正片")
        var calls = 0
        do {
            _ = try await PlaybackRouteResolver.resolve(source: first, sources: [first, source("百度原画", "正片")]) { _ in
                calls += 1
                throw SpiderPlaybackFailure.rejected("还没有配置 Cookie")
            }
            XCTFail("Expected login error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Cookie")) }
        XCTAssertEqual(calls, 1)
    }

    func testAttemptsAreBoundedAndAllFailuresStayVisible() async {
        let routes = [source("夸克原画", "正片"), source("百度原画", "正片"), source("百度原画(无限)", "正片"), source("其他", "正片")]
        var calls = 0
        do {
            _ = try await PlaybackRouteResolver.resolve(source: routes[0], sources: routes) { _ in
                calls += 1
                if calls == 1 { throw SpiderPlaybackFailure.insufficientStorage("夸克网盘空间不足") }
                throw URLError(.timedOut)
            }
            XCTFail("Expected explicit failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("空间不足"))
            XCTAssertTrue(error.localizedDescription.contains("备用线路也未能解析"))
        }
        XCTAssertEqual(calls, 3)
    }

    func testCancellationDoesNotContinueTryingRoutes() async {
        let first = source("夸克原画", "正片")
        var calls = 0
        do {
            _ = try await PlaybackRouteResolver.resolve(source: first, sources: [first, source("百度原画", "正片"), source("其他", "正片")]) { _ in
                calls += 1
                if calls == 1 { throw SpiderPlaybackFailure.insufficientStorage("夸克网盘空间不足") }
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 2)
    }
    func testMuouFilenamesMatchOnlyUnambiguousSeasonAndEpisode() {
        let quark = source("夸克原画", "[389.1MB]2026.S06E03.2160p.WEB-DL.mp4【一人！之下--6】")
        let baidu = source("百度原画", "[389.1MB]The.Outcast.2026.S06E03.2160p.WEB-DL.mp4【一人之下 第6季】")
        let next = source("百度原画", "The.Outcast.S06E04.mp4")
        let otherSeason = source("UC原画", "The.Outcast.S05E03.mp4")
        XCTAssertEqual(PlaybackRouteResolver.alternatives(for: quark, in: [quark, baidu, next, otherSeason]), [baidu])
        XCTAssertTrue(PlaybackRouteResolver.alternatives(for: quark, in: [quark, baidu, source("百度原画", "Other.S06E03.mp4")]).isEmpty)
        for name in ["S06E03-04.mp4", "S06E03E04.mp4", "S06E03.S06E04.mp4", "S06E03.花絮.mp4", "S05E03.mp4"] {
            XCTAssertFalse(PlaybackRouteResolver.matchesEpisode(quark, source("备用", name)))
        }
    }

}
