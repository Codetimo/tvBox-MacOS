import Foundation

/// 目录、CMS 和 Spider 分别限流；一个慢目录或启动中的 Spider 不占用 CMS 名额。
enum SearchPipeline {
    enum Event {
        case catalog(TVSource, [TVBoxSite])
        case catalogFailure(TVSource, Error)
        case result(TVBoxSite, Result<[TVMediaItem], Error>)
    }

    private enum Completion {
        case catalog(TVSource, Result<[TVBoxSite], Error>)
        case site(TVBoxSite, Result<[TVMediaItem], Error>)
    }

    /// 完成一个请求就补入下一个，取消后不再发出结果或派发新请求。
    static func run(
        sources: [TVSource], catalogLimit: Int = 3, siteLimit: Int = 4,
        loadCatalog: @escaping @Sendable (TVSource) async throws -> [TVBoxSite],
        search: @escaping @Sendable (TVBoxSite) async throws -> [TVMediaItem],
        receive: @MainActor (Event) -> Void
    ) async {
        await withTaskGroup(of: Completion.self) { group in
            var sourceIndex = 0
            var pendingCMS: [TVBoxSite] = []
            var pendingSpiders: [TVBoxSite] = []
            var activeCatalogs = 0
            var activeCMS = 0
            var activeSpiders = 0
            while !Task.isCancelled {
                while sourceIndex < sources.count && activeCatalogs < max(1, catalogLimit) {
                    let source = sources[sourceIndex]
                    sourceIndex += 1
                    activeCatalogs += 1
                    group.addTask {
                        do { try Task.checkCancellation(); return .catalog(source, .success(try await loadCatalog(source))) }
                        catch { return .catalog(source, .failure(error)) }
                    }
                }
                while !pendingCMS.isEmpty && activeCMS < max(1, siteLimit) {
                    let site = pendingCMS.removeFirst()
                    activeCMS += 1
                    group.addTask {
                        do { try Task.checkCancellation(); return .site(site, .success(try await search(site))) }
                        catch { return .site(site, .failure(error)) }
                    }
                }
                while !pendingSpiders.isEmpty && activeSpiders < max(1, siteLimit) {
                    let site = pendingSpiders.removeFirst()
                    activeSpiders += 1
                    group.addTask {
                        do { try Task.checkCancellation(); return .site(site, .success(try await search(site))) }
                        catch { return .site(site, .failure(error)) }
                    }
                }
                guard let completion = await group.next(), !Task.isCancelled else { break }
                switch completion {
                case .catalog(let source, let result):
                    activeCatalogs -= 1
                    switch result {
                    case .success(let sites):
                        await receive(.catalog(source, sites))
                        pendingCMS.append(contentsOf: sites.filter { $0.searchable && $0.api != nil })
                        pendingSpiders.append(contentsOf: sites.filter { $0.searchable && $0.usesSpider })
                    case .failure(let error): await receive(.catalogFailure(source, error))
                    }
                case .site(let site, let result):
                    if site.usesSpider { activeSpiders -= 1 } else { activeCMS -= 1 }
                    await receive(.result(site, result))
                }
            }
            group.cancelAll()
        }
    }
}
