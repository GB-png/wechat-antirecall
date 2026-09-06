import SwiftUI
import AppKit

struct CloneView: View {
    @EnvironmentObject var state: AppState

    @AppStorage("clone.count") private var count = 2
    @AppStorage("clone.namePrefix") private var namePrefix = "WeChat"
    @AppStorage("clone.outputDirectory") private var outputDir = "/Applications"
    @AppStorage("clone.keepURLSchemes") private var keepURLSchemes = false
    @AppStorage("clone.replaceExisting") private var replace = false
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("微信多开").font(.title2.weight(.semibold))

            if let banner = state.banner { BannerView(banner: banner) }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "复制出独立的微信")
                    Text("多开不改动原始微信，而是复制出独立的 App 副本，可同时登录多个账号。任何版本都能用，不依赖补丁数据。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Stepper(value: $count, in: 1...9) {
                        HStack { Text("副本数量"); Spacer(); Text("\(count)").foregroundStyle(.secondary) }
                    }
                    HStack {
                        Text("名称前缀")
                        Spacer()
                        TextField("WeChat", text: $namePrefix)
                            .frame(width: 160)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("名称前缀")
                    }
                    HStack {
                        Text("输出目录")
                        Spacer()
                        TextField("/Applications", text: $outputDir)
                            .frame(width: 205)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("输出目录")
                        Button {
                            chooseOutputDirectory()
                        } label: {
                            Label("选择…", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }
                    if let validationError {
                        HintRow(
                            systemImage: "exclamationmark.circle",
                            text: validationError,
                            tint: .red)
                    }
                    Divider()
                    Toggle(isOn: $keepURLSchemes) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("保留 URL Scheme")
                            Text("默认移除，避免系统回调随机落到副本").font(.caption).foregroundStyle(.secondary)
                        }
                    }.tint(Theme.accent)
                    Toggle(isOn: $replace) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("覆盖已存在的副本")
                            Text("把旧副本改名为时间戳备份后再创建").font(.caption).foregroundStyle(.secondary)
                        }
                    }.tint(Theme.accent)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button {
                            submitClone()
                        } label: {
                            Text("创建多开副本").frame(minWidth: 120)
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .disabled(state.busy)
                        if state.busy {
                            ProgressView().controlSize(.small)
                            Text(state.busyMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HintRow(
                        systemImage: "info.circle",
                        text: "如果所选目录需要更高权限，系统会请求管理员授权。每个副本通常要单独登录。")
                }
            }
        }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择多开副本的输出目录"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        let candidate = outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
           isDirectory.boolValue {
            panel.directoryURL = URL(fileURLWithPath: candidate, isDirectory: true)
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        outputDir = selectedURL.path
        validationError = nil
    }

    private func submitClone() {
        let submittedPrefix = namePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedPrefix.isEmpty else {
            validationError = "名称前缀不能为空。请输入名称后再创建副本。"
            return
        }

        guard !submittedPrefix.hasPrefix("/"),
              !submittedPrefix.contains("/"),
              !submittedPrefix.contains("\\"),
              submittedPrefix != ".",
              submittedPrefix != ".." else {
            validationError = "名称前缀只能是名称，不能包含“/”或“\\”，也不能使用“.”或“..”。"
            return
        }

        let submittedDirectory = outputDir.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory = ObjCBool(false)
        guard !submittedDirectory.isEmpty,
              FileManager.default.fileExists(atPath: submittedDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            validationError = "输出目录不存在或不是文件夹。请选择一个现有文件夹。"
            return
        }

        validationError = nil
        Task {
            await state.clone(
                count: count,
                namePrefix: submittedPrefix,
                outputDir: submittedDirectory,
                keepURLSchemes: keepURLSchemes,
                replace: replace)
        }
    }
}
