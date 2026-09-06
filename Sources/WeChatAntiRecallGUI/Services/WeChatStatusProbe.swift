import Foundation
import AppKit

struct DirectAppInfo {
    let marketingVersion: String
    let installedBuild: String
    let bundleIdentifier: String
}

enum WeChatStatusProbe {
    static let officialBundleIDs: Set<String> = ["com.tencent.xinWeChat", "com.tencent.xin"]
    /// Matches the CLI's selected-app guard: only processes whose bundle or executable path
    /// is the selected app (or lives inside it) count as running.
    static func path(_ candidateURL: URL?, belongsToAppAt appPath: String) -> Bool {
        guard let candidateURL else { return false }
        let target = URL(fileURLWithPath: appPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let candidate = candidateURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let prefix = target.hasSuffix("/") ? target : target + "/"
        return candidate == target || candidate.hasPrefix(prefix)
    }

    static func runningInstances(appPath: String) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            path(app.bundleURL, belongsToAppAt: appPath)
                || path(app.executableURL, belongsToAppAt: appPath)
        }
    }

    static func isRunning(appPath: String) -> Bool {
        !runningInstances(appPath: appPath).isEmpty
    }

    /// Politely quits only the selected app, then force-terminates that same target if needed.
    static func quit(appPath: String) async {
        let running = runningInstances(appPath: appPath)
        for app in running {
            app.terminate()
        }
        for _ in 0..<20 where !runningInstances(appPath: appPath).isEmpty {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        for app in runningInstances(appPath: appPath) {
            app.forceTerminate()
        }
    }

    /// Reads the target app's Info.plist directly. Used as a fallback when the CLI refuses
    /// (e.g. `notAWechatApp` because WeChat isn't installed) so the GUI can still say something.
    static func readInfo(appPath: String) -> DirectAppInfo? {
        let plistURL = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let build = plist["CFBundleVersion"] as? String,
              let bundleID = plist["CFBundleIdentifier"] as? String else {
            return nil
        }
        let short = plist["CFBundleShortVersionString"] as? String ?? "—"
        return DirectAppInfo(marketingVersion: short, installedBuild: build, bundleIdentifier: bundleID)
    }

    static func appExists(at appPath: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: appPath, isDirectory: &isDir) && isDir.boolValue
    }
}
