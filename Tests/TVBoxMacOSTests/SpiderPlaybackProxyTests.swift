import XCTest
@testable import TVBoxMacOS

final class SpiderPlaybackProxyTests: XCTestCase {
    func testCreatesForwardAndPreservesSignedURL() async throws {
        let raw = "http://localhost:20599/kaiser?url=https%3A%2F%2Fcdn.example%2Fmovie%3Fx%3D1%26y%3D2&sign=a%2Bb%252Fc"
        var calls: [[String]] = []
        let url = try await SpiderPlaybackProxy.prepare(URL(string: raw)!, serial: "emulator-5580") { args in
            calls.append(args)
            return ""
        }
        XCTAssertEqual(calls, [["forward", "--list"], ["-s", "emulator-5580", "forward", "--no-rebind", "tcp:20599", "tcp:20599"]])
        XCTAssertEqual(url.absoluteString, raw.replacingOccurrences(of: "localhost", with: "127.0.0.1"))
    }

    func testReusesOnlyMatchingDeviceAndDestination() async throws {
        let url = URL(string: "http://127.0.0.1:20599/kaiser")!
        var calls = 0
        let result = try await SpiderPlaybackProxy.prepare(url, serial: "emulator-5580") { _ in
            calls += 1
            return "emulator-5580 tcp:19190 tcp:19190\nemulator-5580 tcp:20599 tcp:20599\n"
        }
        XCTAssertEqual(result, url)
        XCTAssertEqual(calls, 1)
        for mapping in ["emulator-5554 tcp:20599 tcp:20599", "emulator-5580 tcp:20599 tcp:9999"] {
            do {
                _ = try await SpiderPlaybackProxy.prepare(url, serial: "emulator-5580") { _ in mapping }
                XCTFail("Must reject another forward's port")
            } catch { XCTAssertTrue(error.localizedDescription.contains("占用")) }
        }
    }

    func testExternalURLDoesNotUseADB() async throws {
        let url = URL(string: "https://cdn.example/movie.mp4?sign=a%2Bb")!
        let result = try await SpiderPlaybackProxy.prepare(url, serial: "emulator-5580") { _ in
            XCTFail("Public CDN must not be forwarded")
            return ""
        }
        XCTAssertEqual(result, url)
    }

    func testIPv6AndDefaultPort() async throws {
        var calls: [[String]] = []
        let result = try await SpiderPlaybackProxy.prepare(URL(string: "http://[::1]/stream")!, serial: "emulator-5580") { args in
            calls.append(args)
            return ""
        }
        XCTAssertEqual(result.absoluteString, "http://127.0.0.1/stream")
        XCTAssertEqual(calls.last?.suffix(2), ["tcp:80", "tcp:80"])
    }

    func testForwardFailureIsReportedBeforePlayback() async throws {
        do {
            _ = try await SpiderPlaybackProxy.prepare(URL(string: "http://127.0.0.1:20599/kaiser")!, serial: "emulator-5580") { args in
                if args.contains("--list") { return "" }
                throw URLError(.cannotConnectToHost)
            }
            XCTFail("A failed forward must not reach the player")
        } catch { XCTAssertTrue(error.localizedDescription.contains("20599")) }
    }

    func testSpiderParserPreservesNestedURLAndSignatureEscapes() throws {
        let url = "http://127.0.0.1:20599/kaiser?url=https%3A%2F%2Fcdn.example%2Fa%3Fx%3D1%26y%3D2&sign=a%2Bb%252Fc"
        let data = try JSONSerialization.data(withJSONObject: ["parse": 0, "url": url])
        XCTAssertEqual(try SourceLoader.parseSpiderPlayback(data: data).url.absoluteString, url)
        let encoded = "https%3A%2F%2Fcdn.example%2Fmovie.mp4%3Fsign%3Da%252Bb"
        let encodedData = try JSONSerialization.data(withJSONObject: ["url": encoded])
        XCTAssertEqual(try SourceLoader.parseSpiderPlayback(data: encodedData).url.absoluteString,
                       "https://cdn.example/movie.mp4?sign=a%2Bb")
    }
}
