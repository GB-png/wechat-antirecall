import XCTest
@testable import WeChatAntiRecallGUI

final class AppVersionTests: XCTestCase {
    func testLeadingVAndTrailingZeroComponentsAreEquivalent() throws {
        let plain = try XCTUnwrap(AppVersion("1.2"))
        let tagged = try XCTUnwrap(AppVersion("v1.2.0"))
        let uppercaseTag = try XCTUnwrap(AppVersion("V1.2"))

        XCTAssertEqual(plain, tagged)
        XCTAssertEqual(plain, uppercaseTag)
        XCTAssertEqual(tagged.description, "1.2.0")
    }

    func testNumericComponentsAreComparedNumerically() throws {
        let older = try XCTUnwrap(AppVersion("1.9"))
        let newer = try XCTUnwrap(AppVersion("1.10"))

        XCTAssertLessThan(older, newer)
    }

    func testComparisonClassifiesRemoteRelationship() throws {
        let current = InstalledAppVersion.packaged("1.9.0")

        XCTAssertEqual(
            AppVersionComparison.evaluate(current: current, latestTag: "v1.10.0"),
            .updateAvailable(
                current: try XCTUnwrap(AppVersion("1.9.0")),
                latest: try XCTUnwrap(AppVersion("1.10.0"))))
        XCTAssertEqual(
            AppVersionComparison.evaluate(current: current, latestTag: "1.9"),
            .upToDate(
                current: try XCTUnwrap(AppVersion("1.9.0")),
                latest: try XCTUnwrap(AppVersion("1.9"))))
        XCTAssertEqual(
            AppVersionComparison.evaluate(current: current, latestTag: "1.8.7"),
            .localNewer(
                current: try XCTUnwrap(AppVersion("1.9.0")),
                latest: try XCTUnwrap(AppVersion("1.8.7"))))
    }

    func testDevelopmentBuildCannotBeCompared() {
        XCTAssertEqual(
            AppVersionComparison.evaluate(current: .developmentBuild, latestTag: "v1.2.3"),
            .unableToCompare(.developmentBuild))
    }

    func testPrereleaseAndMalformedVersionsAreRejected() {
        XCTAssertNil(AppVersion("1.2.3-beta.1"))
        XCTAssertNil(AppVersion("1.2.3+4"))
        XCTAssertNil(AppVersion("1..3"))
        XCTAssertNil(AppVersion("release-1.2.3"))

        XCTAssertEqual(
            AppVersionComparison.evaluate(current: .packaged("1.2.3-beta.1"), latestTag: "1.2.3"),
            .unableToCompare(.malformedCurrent("1.2.3-beta.1")))
        XCTAssertEqual(
            AppVersionComparison.evaluate(current: .packaged("1.2.3"), latestTag: "vNext"),
            .unableToCompare(.malformedLatest("vNext")))
    }
}
