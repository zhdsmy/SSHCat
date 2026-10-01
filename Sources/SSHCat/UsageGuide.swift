import SwiftUI
import SSHCatCore

struct UsageGuide: View {
    @EnvironmentObject var manager: ForwardManager
    @EnvironmentObject var navigation: Navigation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("让 SSH 转发常驻菜单栏", systemImage: "network")
                    .font(.title2.weight(.semibold))
                Text("选择一种转发方式，填写 SSH 主机，保存后打开运行开关。关闭管理窗口后仍会保持连接；退出 SSHCat 会停止它启动的所有转发。")
                    .foregroundStyle(.secondary)
                GroupBox("从你想做的事开始") {
                    VStack(alignment: .leading, spacing: 16) {
                        scenario("访问远端服务", example: "本机 8080 → 远端 8080", kind: .local,
                                 detail: "把远端网页、数据库等端口映射到本机。")
                        Divider()
                        scenario("分享本机服务", example: "远端 9000 → 本机 3000", kind: .remote,
                                 detail: "让 SSH 服务器能访问本机的开发服务。")
                        Divider()
                        scenario("建立 SOCKS 代理", example: "本机 127.0.0.1:1080", kind: .dynamic,
                                 detail: "在需要代理的应用中配置这个 SOCKS 地址。")
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("第一次连接") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("先在终端成功连接一次目标主机，确认主机指纹，并配置密钥或 ssh-agent。SSHCat 不会弹出密码框，也不会代为接受主机密钥。")
                        Text("已有 ~/.ssh/config？直接填写 Host 别名。用户、端口和密钥留空时沿用配置，包括 ProxyJump。")
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("无法连接时") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("连接失败：查看状态下方的原因与建议，再展开“连接日志”。端口占用时修改监听端口；认证失败时检查密钥和主机指纹。")
                        Text("正在重连：等待倒计时，或关闭再打开运行开关立即重试。")
                        Text("运行中但服务打不开：确认转发方向、目标地址与端口。远程转发监听非回环地址还需要服务器开启 GatewayPorts。")
                        Text("需要求助时复制诊断信息，分享前检查其中的主机、地址与路径。")
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 640, alignment: .leading).padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func scenario(_ title: String, example: String, kind: ForwardKind, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("新建") { navigation.add(kind, using: manager) }
                    .disabled(!manager.canEditRules).accessibilityLabel("新建\(title)")
            }
            Text(example).font(.callout.monospaced())
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }
}
