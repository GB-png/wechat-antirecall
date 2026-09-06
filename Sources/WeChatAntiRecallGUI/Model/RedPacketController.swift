import Foundation

@MainActor
final class RedPacketController: ObservableObject {
    @Published private(set) var enabled = false
    @Published var delayMilliseconds = 500
    @Published private(set) var supported = false
    @Published private(set) var runtimeAvailable = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    private var revision: UInt64 = 0

    struct Report: Decodable {
        struct Settings: Decodable { let enabled: Bool; let delayMilliseconds: Int }
        let schemaVersion: Int
        let settings: Settings
        let supported: Bool
        let build: String
        let runtimeAvailable: Bool
    }

    func load(appPath: String) async { await run(["get"], appPath: appPath, saving: false) }
    func setEnabled(_ value: Bool, appPath: String) async {
        var arguments = [value ? "on" : "off"]
        if value { arguments += ["--delay-ms", String(delayMilliseconds)] }
        await run(arguments, appPath: appPath, saving: true)
    }

    private func run(_ arguments: [String], appPath: String, saving: Bool) async {
        revision &+= 1
        let activeRevision = revision
        busy = true
        error = nil
        message = nil
        if !saving { enabled = false; supported = false; runtimeAvailable = false }
        let result = await CLIRunner.runUser(
            BundledPaths.cli, ["red-packet"] + arguments + ["--app", appPath, "--json"])
        guard revision == activeRevision else { return }
        busy = false
        if result.succeeded,
           let report = try? JSONDecoder().decode(Report.self, from: Data(result.output.utf8)),
           report.schemaVersion == GUICLIProtocol.schemaVersion {
            enabled = report.settings.enabled
            delayMilliseconds = report.settings.delayMilliseconds
            supported = report.supported
            runtimeAvailable = report.runtimeAvailable
            if saving {
                message = enabled ? "已保存。新安装或更新组件后，请完全退出并重新打开微信。" : "已关闭自动红包。"
            }
        } else {
            let failureText = (result.output + result.stderr).lowercased()
            if failureText.contains("permission") || failureText.contains("not permitted") || failureText.contains("权限") {
                error = "无法读取微信设置。请为本工具开启「完全磁盘访问权限」，退出并重新打开后重试。"
            } else if let envelope = try? JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(result.output.utf8)) {
                error = envelope.error.message
            } else {
                error = "无法读取或保存红包设置。请重新读取后重试。"
            }
        }
    }
}
