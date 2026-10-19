import AppKit
import CoreImage
import XCTest
@testable import TVBoxMacOS

final class PanLoginTests: XCTestCase {
    /// 验证输出是可扫描的原始登录链接，避免误把 URL 当成远程图片下载。
    func testRawLoginPayloadRoundTripsThroughQRCode() throws {
        let payload = "https://pan.example.test/scan?token=fixture%2Bvalue&client=desktop"
        let image = try XCTUnwrap(PanLoginResponse.qrImage(payload))
        XCTAssertEqual(try decodedMessages(in: image), [payload])
    }

    /// 已编码图片应保留二维码内容，不能再次把 data URL 编成二维码。
    func testBase64ImagePreservesOriginalQRCode() throws {
        let payload = "fixture-login-session-12345"
        let original = try XCTUnwrap(PanLoginResponse.qrImage(payload))
        let tiff = try XCTUnwrap(original.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let image = try XCTUnwrap(PanLoginResponse.qrImage("data:image/png;base64," + png.base64EncodedString()))
        XCTAssertEqual(try decodedMessages(in: image), [payload])
    }

    /// 拒绝损坏图片和过大输入，避免出现空白二维码或不受限解码。
    func testMalformedOrOversizedQRInputIsRejected() {
        for payload in ["", "data:image/png;base64,invalid!", "data:image/png;base64,", "data:image/png,not-base64",
                        "data:image/png;base64," + Data("not an image".utf8).base64EncodedString(),
                        String(repeating: "x", count: 3_000), String(repeating: "x", count: 1_000_001)] {
            XCTAssertNil(PanLoginResponse.qrImage(payload))
        }
    }

    /// 登录凭据按网盘隔离，访客 Cookie 和空身份字段均不能触发保存。
    func testAuthenticatedCookieRequiresProviderIdentity() {
        XCTAssertEqual(PanLoginResponse(cookie: "__pus=quark-session; visitor=1").authenticatedCookie(for: .quark), "__pus=quark-session; visitor=1")
        XCTAssertEqual(PanLoginResponse(cookie: "__puus=alternate-session").authenticatedCookie(for: .quark), "__puus=alternate-session")
        XCTAssertEqual(PanLoginResponse(cookie: "BAIDUID=guest; BDUSS=baidu-session").authenticatedCookie(for: .baidu), "BAIDUID=guest; BDUSS=baidu-session")
        for cookie in ["BAIDUID=visitor", "BDUSS=", "BDUSS=   ", "__pus=quark-session"] {
            XCTAssertNil(PanLoginResponse(cookie: cookie).authenticatedCookie(for: .baidu))
        }
        XCTAssertNil(PanLoginResponse(cookie: "BDUSS=baidu-session").authenticatedCookie(for: .quark))
        XCTAssertNil(PanLoginResponse().authenticatedCookie(for: .baidu))
    }

    /// 多行头部必须拒绝，防止凭据混入额外 HTTP 头。
    func testAuthenticatedCookieRejectsHeaderInjection() {
        for separator in ["\n", "\r", "\r\n"] {
            XCTAssertNil(PanLoginResponse(cookie: "BDUSS=session" + separator + "X-Test: invalid").authenticatedCookie(for: .baidu))
            XCTAssertNil(PanLoginResponse(cookie: "__pus=session" + separator + "X-Test: invalid").authenticatedCookie(for: .quark))
        }
    }

    /// 使用系统二维码识别器回读像素，检验真正可扫描的结果。
    private func decodedMessages(in image: NSImage) throws -> [String] {
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let input = try XCTUnwrap(CIImage(data: tiff))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        return detector.features(in: input).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }
}
