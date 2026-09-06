import Foundation
import XCTest
@testable import WeChatAntiRecallGUI

final class InstallReportStateTests: XCTestCase {
    func testEmptyReportIsMismatch() throws {
        XCTAssertEqual(InstallState.classify(try report()), .mismatch)
    }

    func testAllAlreadyAppliedIsInstalled() throws {
        let decoded = try report(
            targetStates: ["alreadyPatched", "alreadyPatched"],
            runtimeStates: ["alreadyInjected"])

        XCTAssertEqual(InstallState.classify(decoded), .installed)
    }

    func testAllWouldApplyIsNotInstalled() throws {
        let decoded = try report(
            targetStates: ["wouldPatch", "wouldPatch"],
            runtimeStates: ["wouldInject"])

        XCTAssertEqual(InstallState.classify(decoded), .notInstalled)
    }

    func testMixedAlreadyAndWouldApplyIsMismatch() throws {
        let decoded = try report(
            targetStates: ["alreadyPatched", "wouldPatch"],
            runtimeStates: ["alreadyInjected"])

        XCTAssertEqual(InstallState.classify(decoded), .mismatch)
    }

    func testMixedUpdateOnlyEntriesAreMismatch() throws {
        let decoded = try report(
            targetIdentifier: "update",
            targetStates: ["alreadyPatched", "wouldPatch"])

        XCTAssertEqual(InstallState.classify(decoded), .mismatch)
    }

    func testCleanMixedComposedReportIsInstallable() throws {
        let decoded = try report(
            targetIdentifier: "revoke",
            targetStates: ["wouldPatch"],
            additionalTargetIdentifier: "update",
            additionalTargetStates: ["alreadyPatched"])

        XCTAssertEqual(InstallState.classify(decoded), .mismatch)
        XCTAssertEqual(InstallPreflightDisposition.classify(decoded), .installable)
    }

    func testPreflightRejectsEmptyUnknownAndNonCleanReports() throws {
        XCTAssertEqual(InstallPreflightDisposition.classify(try report()), .invalid)
        XCTAssertEqual(
            InstallPreflightDisposition.classify(try report(targetStates: ["unknownState"])),
            .invalid)
        XCTAssertEqual(
            InstallPreflightDisposition.classify(try report(targetStates: ["patched"])),
            .invalid)
    }

    func testPreflightRecognizesFullyInstalledReport() throws {
        let decoded = try report(
            targetStates: ["alreadyPatched"],
            runtimeStates: ["alreadyInjected"])

        XCTAssertEqual(InstallPreflightDisposition.classify(decoded), .alreadyInstalled)
    }

    private func report(
        targetIdentifier: String = "revoke",
        targetStates: [String] = [],
        runtimeStates: [String] = [],
        additionalTargetIdentifier: String? = nil,
        additionalTargetStates: [String] = []
    ) throws -> InstallReport {
        func entries(_ states: [String], addressBase: Int) -> [[String: Any]] {
            states.enumerated().map { index, state in
                [
                    "arch": "arm64",
                    "address": "0x\(addressBase + index)",
                    "fileOffset": "0x\(addressBase + index)",
                    "state": state,
                ]
            }
        }
        let targetEntries = entries(targetStates, addressBase: 1)
        let runtimeEntries: [[String: Any]] = runtimeStates.enumerated().map { index, state in
            [
                "arch": "arm64",
                "installName": "@executable_path/../Frameworks/libWeChatAntiRecallRuntime.dylib",
                "commandOffset": "0x\(index + 1)",
                "state": state,
            ]
        }
        var targets: [[String: Any]] = targetStates.isEmpty ? [] : [[
            "identifier": targetIdentifier,
            "binary": "Contents/Resources/wechat.dylib",
            "entries": targetEntries,
        ]]
        if let additionalTargetIdentifier, !additionalTargetStates.isEmpty {
            targets.append([
                "identifier": additionalTargetIdentifier,
                "binary": "Contents/MacOS/WeChat",
                "entries": entries(additionalTargetStates, addressBase: 100),
            ])
        }
        let object: [String: Any] = [
            "schemaVersion": GUICLIProtocol.schemaVersion,
            "command": "install",
            "dryRun": true,
            "resigned": false,
            "app": [
                "path": "/Applications/WeChat.app",
                "bundleIdentifier": "com.tencent.xinWeChat",
                "marketingVersion": "4.1.13",
                "installedBuild": "269624",
                "executable": "/Applications/WeChat.app/Contents/MacOS/WeChat",
            ],
            "mode": targets.compactMap { $0["identifier"] as? String },
            "runtime": runtimeEntries,
            "targets": targets,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(InstallReport.self, from: data)
    }
}
