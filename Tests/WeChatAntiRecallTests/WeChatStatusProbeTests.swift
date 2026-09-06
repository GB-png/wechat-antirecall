import Foundation
import XCTest
@testable import WeChatAntiRecall
@testable import WeChatAntiRecallGUI

final class WeChatStatusProbeTests: XCTestCase {
    func testPathMatchesOnlySelectedBundleAndItsChildren() {
        let selected = "/Applications/WeChat.app"

        XCTAssertTrue(WeChatStatusProbe.path(
            URL(fileURLWithPath: selected),
            belongsToAppAt: selected))
        XCTAssertTrue(WeChatStatusProbe.path(
            URL(fileURLWithPath: "/Applications/WeChat.app/Contents/MacOS/WeChat"),
            belongsToAppAt: selected))

        XCTAssertFalse(WeChatStatusProbe.path(
            URL(fileURLWithPath: "/Applications/WeChat 1.app/Contents/MacOS/WeChat"),
            belongsToAppAt: selected))
        XCTAssertFalse(WeChatStatusProbe.path(
            URL(fileURLWithPath: "/Applications/WeChat.app-copy/Contents/MacOS/WeChat"),
            belongsToAppAt: selected))
    }

    func testPathResolvesSelectedAppSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechat-status-symlink-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let appURL = root.appendingPathComponent("WeChat.app", isDirectory: true)
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/WeChat")
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data().write(to: executableURL)

        let aliasURL = root.appendingPathComponent("Selected WeChat.app", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: appURL)

        XCTAssertTrue(WeChatStatusProbe.path(executableURL, belongsToAppAt: aliasURL.path))
        XCTAssertTrue(processExecutablePath(executableURL.path, belongsToAppAt: aliasURL))
    }
}
