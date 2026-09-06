import Foundation
import XCTest
@testable import WeChatAntiRecallGUI

final class UpdateServiceTests: XCTestCase {
    private let requestURL = URL(string: "https://example.invalid/update")!

    override func tearDown() {
        UpdateURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testValidChecksumIsNormalizedAnd404IsTheOnlyFallback() throws {
        let uppercaseDigest = String(repeating: "AB", count: 32)
        let validResponse = try XCTUnwrap(httpResponse(statusCode: 200))
        let parsed = try PatchChecksumSidecar.expectedDigest(
            data: Data("\(uppercaseDigest)  patches.json\n".utf8),
            response: validResponse)

        XCTAssertEqual(parsed, uppercaseDigest.lowercased())
        XCTAssertNil(try PatchChecksumSidecar.expectedDigest(
            data: Data(),
            response: try XCTUnwrap(httpResponse(statusCode: 404))))
    }

    func testSidecarHTTPFailuresAreRejectedInsteadOfFallingBack() throws {
        for statusCode in [403, 500] {
            XCTAssertThrowsError(try PatchChecksumSidecar.expectedDigest(
                data: Data(),
                response: try XCTUnwrap(httpResponse(statusCode: statusCode)))) { error in
                XCTAssertTrue(error.localizedDescription.contains("HTTP \(statusCode)"))
                XCTAssertTrue(error.localizedDescription.contains("已拒绝更新"))
            }
        }
    }

    func testMalformedAndNonHexSidecarsAreRejected() throws {
        let response = try XCTUnwrap(httpResponse(statusCode: 200))
        let malformedValues = [
            "abc123",
            String(repeating: "g", count: 64),
            "",
        ]

        for value in malformedValues {
            XCTAssertThrowsError(try PatchChecksumSidecar.expectedDigest(
                data: Data(value.utf8),
                response: response)) { error in
                XCTAssertEqual(error.localizedDescription, "补丁校验和文件格式无效，已拒绝更新。")
            }
        }
    }

    func testNonHTTPResponseIsRejected() {
        let response = URLResponse(
            url: requestURL,
            mimeType: "text/plain",
            expectedContentLength: 0,
            textEncodingName: "utf-8")

        XCTAssertThrowsError(try PatchChecksumSidecar.expectedDigest(
            data: Data(),
            response: response)) { error in
            XCTAssertEqual(error.localizedDescription, "补丁校验和请求返回了无效响应，已拒绝更新。")
        }
    }

    func testChecksumNetworkFailureIsNotSwallowed() async {
        UpdateURLProtocolStub.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let session = makeStubSession()
        defer { session.invalidateAndCancel() }

        do {
            _ = try await UpdateService.fetchChecksum(using: session)
            XCTFail("network failure must reject the patch update")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("下载补丁校验和失败"))
            XCTAssertTrue(error.localizedDescription.contains("已拒绝更新"))
        }
    }

    func testReleaseRequestSendsRequiredGitHubHeaders() async throws {
        UpdateURLProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "WeChatAntiRecallGUI")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            let body = Data(#"{"tag_name":"v1.2.3","name":"Version 1.2.3","html_url":"https://example.invalid/release"}"#.utf8)
            return (response, body)
        }
        let session = makeStubSession()
        defer { session.invalidateAndCancel() }

        let release = try await UpdateService.checkLatestRelease(using: session)
        XCTAssertEqual(release.tag, "v1.2.3")
    }

    private func httpResponse(statusCode: Int) -> HTTPURLResponse? {
        HTTPURLResponse(
            url: requestURL,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil)
    }

    private func makeStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private final class UpdateURLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (URLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
