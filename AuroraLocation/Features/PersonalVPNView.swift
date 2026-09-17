import SwiftUI

struct PersonalVPNView: View {
    @ObservedObject var state: AppState
    @StateObject private var vpn = PersonalVPN()
    @Environment(\.scenePhase) private var scenePhase
    @State private var password = ""
    @State private var confirmingRemoval = false

    private var locationInUse: Bool {
        state.isBusy || state.isSimulating || state.pairing.isBusy
    }

    var body: some View {
        Form {
            Section {
                Text("测试原生 IKEv2 与小火箭同时连接. 需要单独的 IKEv2 服务端, 不能直接填写小火箭订阅或代理节点.")
                Text("此方案尚未通过蜂窝定位验证. VPN 已连接只表示隧道建立, 请继续检测开发者服务并确认实际位置.")
                    .foregroundStyle(.secondary)
                Text("系统只允许一个 Personal VPN 启用. 启用此 IKEv2 会停用其他 Personal VPN; 小火箭使用另一类 VPN, 共存效果仍需实测.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("IKEv2 服务器") {
                TextField("服务器域名或 IP", text: $vpn.configuration.serverAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("服务器证书身份 / Remote ID", text: $vpn.configuration.remoteIdentifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("用户名", text: $vpn.configuration.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                SecureField(vpn.hasSavedPassword ? "密码, 留空使用已保存密码" : "密码", text: $password)
                    .textContentType(.password)
            }
            .disabled(vpn.isBusy || vpn.isActive || locationInUse)

            Section {
                LabeledContent("Personal VPN", value: vpn.status)
                if let error = vpn.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                Button("保存并连接", systemImage: "network") {
                    let submittedPassword = password
                    password = ""
                    Task { await vpn.connect(password: submittedPassword) }
                }
                .disabled(vpn.isBusy || vpn.isActive || locationInUse)

                Button("断开此 IKEv2", systemImage: "pause.circle") {
                    Task { await vpn.disconnect() }
                }
                .disabled(vpn.isBusy || !vpn.isActive || locationInUse)

                Button("读取最近断开原因", systemImage: "stethoscope") {
                    vpn.readLastDisconnectError()
                }
                .disabled(!vpn.hasConfiguration || vpn.isBusy || vpn.isActive)

                Button("检测开发者连接", systemImage: "stethoscope") {
                    Task { await state.checkConnection() }
                }
                .disabled(vpn.isBusy || locationInUse)

                LabeledContent("开发者隧道", value: state.tunnelStatus)
                LabeledContent("开发者服务", value: state.developerStatus)
            } footer: {
                if locationInUse {
                    Text("请先结束模拟定位或配对, 再调整 VPN 连接.")
                } else {
                    Text("连接后确认小火箭仍正常访问外网, 再检测开发者连接. 连接异常时可断开此 IKEv2 后重试原有方式.")
                }
            }

            Section {
                Button("移除此 IKEv2 配置", systemImage: "trash", role: .destructive) {
                    confirmingRemoval = true
                }
                .disabled(!vpn.hasConfiguration || vpn.isBusy || vpn.isActive || locationInUse)
            } footer: {
                Text("使用用户名和密码认证, 校验服务器证书. 密码仅保存在本机 Keychain, 不写入诊断或同步. 不启用自动连接.")
            }
        }
        .navigationTitle("蜂窝连接实验")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vpn.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                password = ""
            } else {
                Task { await vpn.refresh(updateDraft: false) }
            }
        }
        .confirmationDialog("移除 Aurora Location 的 IKEv2 配置和已保存密码?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("移除", role: .destructive) {
                password = ""
                Task { await vpn.removeConfiguration() }
            }
            Button("取消", role: .cancel) { }
        }
    }
}
