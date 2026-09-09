import SwiftUI
import AppKit

struct RedPacketView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var controller = RedPacketController()

    private var runtimeInstalled: Bool {
        controller.runtimeAvailable && state.installedMode == .customTip && state.installState == .installed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            HStack {
                Text("自动红包").font(.title2.weight(.semibold))
                StatusPill(tone: .neutral, text: "实验功能", systemImage: "flask")
            }
            Text("自动处理新收到的普通红包，跳过历史消息、自己发送和已经领取的红包。每个红包只尝试一次。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let banner = state.banner { BannerView(banner: banner) }
            if let error = controller.error {
                HintRow(systemImage: "exclamationmark.circle", text: error, tint: .orange)
                Button("重新读取设置") { Task { await controller.load(appPath: state.appPath) } }
                    .disabled(controller.busy)
                Button("打开完全磁盘访问设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "当前支持")
                    Text("微信 4.1.13 · 构建 269624 / 269628")
                    Text("此版本已完成协议静态分析和离线检查，尚未完成真实红包领取验证。")
                        .font(.callout).foregroundStyle(.secondary)
                    if controller.supported && !runtimeInstalled {
                        Text("需要更新本工具的运行组件，并使用自定义撤回提示模式。安装前请完全退出微信。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button(controller.runtimeAvailable ? "安装运行组件" : "安装或更新运行组件") {
                            Task {
                                await state.install(InstallRequest(mode: .customTip), refreshRuntime: true)
                                await controller.load(appPath: state.appPath)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.busy || controller.busy || state.wechatRunning || !state.customTipAvailable)
                        if state.wechatRunning {
                            Button("退出微信") { Task { await state.quitWeChat() } }.disabled(state.busy)
                        }
                    } else if !controller.supported && !controller.busy && controller.error == nil {
                        Text("当前所选构建尚未适配，无法开启自动红包。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("自动领取新红包", isOn: Binding(
                        get: { controller.enabled },
                        set: { value in Task { await controller.setEnabled(value, appPath: state.appPath) } }))
                        .disabled(controller.busy || state.busy || (!controller.enabled && (!runtimeInstalled || !controller.supported)))
                    Stepper("收到后等待 \(controller.delayMilliseconds) 毫秒", value: $controller.delayMilliseconds, in: 0...5000, step: 100)
                        .disabled(controller.busy || state.busy)
                    if controller.enabled {
                        Button("保存等待时间") { Task { await controller.setEnabled(true, appPath: state.appPath) } }
                            .disabled(controller.busy || state.busy)
                    }
                    if let message = controller.message {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: state.appPath) { await controller.load(appPath: state.appPath) }
    }
}
