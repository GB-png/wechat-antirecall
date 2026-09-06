import Foundation
import CryptoKit

// Repo the GUI pulls updates from and publishes releases to (confirmed with the user).
enum Upstream {
    static let owner = "fzlzjerry"
    static let repo = "wechat-antirecall"
    static var patchesJSON: URL {
        URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/main/patches.json")!
    }
    static var patchesChecksum: URL {
        URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/main/patches.json.sha256")!
    }
    static var latestRelease: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    }
    static var releasesPage: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases")!
    }
}

struct PatchesFetchResult {
    let count: Int
    let checksumVerified: Bool
    let sha256: String
}

struct ReleaseInfo {
    let tag: String
    let name: String
    let htmlURL: URL
}

/// A release version made only of dot-separated decimal components.
///
/// A single leading `v`/`V` is accepted. Pre-release/build suffixes are deliberately
/// rejected: GitHub tags such as `1.2.0-beta.1` do not have enough policy here to decide
/// whether they should be offered to ordinary users.
struct AppVersion: Equatable, Comparable, CustomStringConvertible {
    let components: [Int]

    init?(_ rawValue: String) {
        var candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.first == "v" || candidate.first == "V" {
            candidate.removeFirst()
        }

        let fields = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard !fields.isEmpty else { return nil }

        var parsed: [Int] = []
        parsed.reserveCapacity(fields.count)
        for field in fields {
            guard !field.isEmpty,
                  field.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(field) else {
                return nil
            }
            parsed.append(value)
        }
        components = parsed
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs, rhs) == .orderedSame
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    private static func compare(_ lhs: AppVersion, _ rhs: AppVersion) -> ComparisonResult {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }
}

enum InstalledAppVersion: Equatable {
    case packaged(String)
    case developmentBuild

    var displayText: String {
        switch self {
        case .packaged(let value):
            return value
        case .developmentBuild:
            return "开发构建（无可用版本号）"
        }
    }
}

enum AppVersionComparisonFailure: Equatable {
    case developmentBuild
    case malformedCurrent(String)
    case malformedLatest(String)
}

enum AppVersionComparison: Equatable {
    case updateAvailable(current: AppVersion, latest: AppVersion)
    case upToDate(current: AppVersion, latest: AppVersion)
    case localNewer(current: AppVersion, latest: AppVersion)
    case unableToCompare(AppVersionComparisonFailure)

    static func evaluate(current: InstalledAppVersion, latestTag: String) -> AppVersionComparison {
        guard let latest = AppVersion(latestTag) else {
            return .unableToCompare(.malformedLatest(latestTag))
        }
        guard case .packaged(let currentValue) = current else {
            return .unableToCompare(.developmentBuild)
        }
        guard let installed = AppVersion(currentValue) else {
            return .unableToCompare(.malformedCurrent(currentValue))
        }

        if installed < latest {
            return .updateAvailable(current: installed, latest: latest)
        }
        if installed > latest {
            return .localNewer(current: installed, latest: latest)
        }
        return .upToDate(current: installed, latest: latest)
    }
}

enum PatchChecksumSidecar {
    /// Returns `nil` only when the sidecar is genuinely absent (HTTP 404).
    static func expectedDigest(data: Data, response: URLResponse) throws -> String? {
        guard let http = response as? HTTPURLResponse else {
            throw GUIError("补丁校验和请求返回了无效响应，已拒绝更新。")
        }
        if http.statusCode == 404 {
            return nil
        }
        guard http.statusCode == 200 else {
            throw GUIError("下载补丁校验和失败（HTTP \(http.statusCode)），已拒绝更新。")
        }
        guard let text = String(data: data, encoding: .utf8),
              let token = text.split(whereSeparator: \.isWhitespace).first else {
            throw GUIError("补丁校验和文件格式无效，已拒绝更新。")
        }

        let digest = String(token)
        guard digest.utf8.count == 64, digest.utf8.allSatisfy(Self.isHexDigit) else {
            throw GUIError("补丁校验和文件格式无效，已拒绝更新。")
        }
        return digest.lowercased()
    }

    private static func isHexDigit(_ value: UInt8) -> Bool {
        (value >= 48 && value <= 57)
            || (value >= 65 && value <= 70)
            || (value >= 97 && value <= 102)
    }
}

enum UpdateService {
    /// SwiftPM launches are bare executables rather than packaged `.app` bundles, so any
    /// incidental process metadata must not be presented as a released app version.
    static var installedAppVersion: InstalledAppVersion {
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app",
              let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .developmentBuild
        }
        return .packaged(value)
    }

    /// Downloads the latest patches.json, verifies integrity, and writes it to the App
    /// Support override (used by the CLI via `--config`).
    /// Integrity: patches.json drives byte-writes into wechat.dylib, so a SHA-256 sidecar
    /// (`patches.json.sha256`) is authoritative when published. Only an explicit HTTP 404
    /// permits the structural-validation fallback; every other sidecar failure rejects the
    /// update.
    @discardableResult
    static func fetchLatestPatches() async throws -> PatchesFetchResult {
        var request = URLRequest(url: Upstream.patchesJSON)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GUIError("下载失败：无响应。")
        }
        guard http.statusCode == 200 else {
            throw GUIError("下载失败（HTTP \(http.statusCode)）。请检查网络。")
        }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !array.isEmpty,
              array.allSatisfy({ $0["version"] is String && $0["targets"] is [Any] }) else {
            throw GUIError("下载的补丁数据格式不正确，已忽略。")
        }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        // Verify against the sidecar whenever it exists. Only a confirmed 404 may fall back.
        var verified = false
        if let expected = try await fetchChecksum() {
            guard expected == digest.lowercased() else {
                throw GUIError("补丁数据校验和不匹配，已拒绝下载（可能被篡改或传输损坏）。")
            }
            verified = true
        }

        BundledPaths.ensureWorkingDirectories()
        try data.write(to: BundledPaths.downloadedPatchesJSON, options: .atomic)
        return PatchesFetchResult(count: array.count, checksumVerified: verified, sha256: digest)
    }

    /// Fetches the expected SHA-256 from `patches.json.sha256` (first whitespace token).
    /// A confirmed HTTP 404 is the sole case that permits structural-only validation.
    static func fetchChecksum(using session: URLSession = .shared) async throws -> String? {
        var request = URLRequest(url: Upstream.patchesChecksum)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GUIError("下载补丁校验和失败：\(error.localizedDescription)。已拒绝更新。")
        }
        return try PatchChecksumSidecar.expectedDigest(data: data, response: response)
    }

    /// Removes the downloaded override so the bundled baseline is used again.
    static func revertToBundled() throws {
        let url = BundledPaths.downloadedPatchesJSON
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func checkLatestRelease(using session: URLSession = .shared) async throws -> ReleaseInfo {
        var request = URLRequest(url: Upstream.latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WeChatAntiRecallGUI", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GUIError("查询发布版本失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)）。")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else {
            throw GUIError("暂无发布版本。")
        }
        let name = obj["name"] as? String ?? tag
        let html = (obj["html_url"] as? String).flatMap(URL.init) ?? Upstream.releasesPage
        return ReleaseInfo(tag: tag, name: name, htmlURL: html)
    }
}
