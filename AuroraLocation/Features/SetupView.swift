import SwiftUI
import UIKit

struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var state: AppState
    @ObservedObject private var pairing: PairingService
    @State private var copied = false
    @State private var configCopied = false
    @State private var exportError: String?

    init(state: AppState) {
        _state = ObservedObject(wrappedValue: state)
        _pairing = ObservedObject(wrappedValue: state.pairing)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("连接状态") {
                    LabeledContent("最近操作", value: state.lastOperation)
                    LabeledContent("配对", value: pairing.status)
                    LabeledContent("Wi-Fi", value: state.wifiAvailable ? "接口有地址" : "未检测到地址")
                    LabeledContent("开发者隧道", value: state.tunnelStatus)
                    LabeledContent("开发者服务", value: state.developerStatus)
                    LabeledContent("本机中继", value: state.relayStatus)
                    Button("重新检测", systemImage: "arrow.clockwise") {
                        pairing.refresh()
                        Task { await state.checkConnection() }
                    }
                    .disabled(pairing.isBusy || state.isBusy)
                }

                Section("Shadowrocket 本机连接") {
                    Text("保持小火箭连接. 模拟定位期间保留连接和本机中继, 点恢复真实定位后关闭. App 在后台被系统挂起或终止时可能恢复真实位置.")
                    Button(configCopied ? "已复制, 请切到小火箭导入" : "复制小火箭连接配置", systemImage: "doc.on.doc") {
                        do {
                            let config = try TunnelKeys.loadOrCreate().wireGuardConfiguration
                            UIPasteboard.general.setItems([["public.utf8-plain-text": config]],
                                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                            configCopied = true
                            exportError = nil
                        } catch { exportError = "配置生成失败. 请解锁设备后重试." }
                    }
                    .disabled(pairing.isBusy || state.isBusy)
                    if let exportError { Text(exportError).foregroundStyle(.red) }
                    Button("复制本机分流模块", systemImage: "doc.on.doc") {
                        UIPasteboard.general.setItems([["public.utf8-plain-text": "#!name=Aurora Local\n#!desc=Local developer connection only\n[Rule]\nIP-CIDR,10.7.0.1/32,AuroraLocal,no-resolve\n"]],
                            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                    }
                    Text("仅用于本机小火箭, 剪贴板 2 分钟后过期. 配置含连接密钥, 不含 Apple 配对凭据, 不要上传到订阅或分享给他人.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    if pairing.hasPairing {
                        Label("已保存本机配对凭据", systemImage: "checkmark.shield")
                        Text("配对凭据只保存在本机. PIN 不会写入日志.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("需要完成一次设备配对, 才能建立开发者连接.")
                    }

                    if let pin = pairing.pin {
                        LabeledContent("6 位 PIN", value: pin)
                            .font(.title3.monospacedDigit())
                            .accessibilityLabel("配对 PIN 为 \(pin)")
                    }

                    if pairing.isBusy {
                        Button("取消配对", systemImage: "xmark.circle", role: .cancel) {
                            pairing.cancel()
                        }
                    } else {
                        Button(pairing.hasPairing ? "重新配对" : "开始配对", systemImage: "link") {
                            pairing.start()
                        }
                        .disabled(state.isBusy || state.isSimulating)
                    }
                } header: {
                    Text("设备配对")
                } footer: {
                    Text("配对最多等待 3 分钟. App 进入后台后可用时间有限, 请保持 Aurora Location 打开.")
                }

                Section("配对步骤") {
                    step(1, "点 '开始配对', 保持 Aurora Location 打开.")
                    step(2, "打开系统 设置 > 隐私与安全性 > 开发者模式 > Pair with Host.")
                    step(3, "选择 Aurora Location, 输入设备锁屏密码.")
                    step(4, "在系统提示中输入这里显示的 6 位 PIN, 然后返回 App.")
                    Text("请允许本地网络和通知权限并连接 Wi-Fi. PIN 通知会自动清理. 配对完成后保持 Shadowrocket 连接, 再检测开发者服务.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("诊断") {
                    Text("诊断内容已脱敏, 不包含 PIN 或配对凭据.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(copied ? "已复制" : "复制脱敏诊断", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = state.diagnostics
                        copied = true
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.semibold))
                .frame(width: 22, height: 22)
                .background(.tint, in: Circle())
                .foregroundStyle(.white)
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }
}
