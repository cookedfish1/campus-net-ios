import SwiftUI
import WebKit

struct ContentView: View {
    @StateObject private var model = PortalModel()
    @AppStorage("cn.user") private var user: String = ""
    @State private var password: String = ""
    @State private var wantOnline = false

    private var canOperate: Bool { !model.busy && !user.isEmpty && !password.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("账号") {
                    TextField("宽带账户", text: $user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                    SecureField("密码", text: $password)
                }

                Section("网络") {
                    HStack(spacing: 12) {
                        Button("5G") { model.join(ssid: "CMCC_RenAi_5G") }
                            .buttonStyle(.bordered)
                            .disabled(model.busy)
                        Button("2.4G") { model.join(ssid: "CMCC_RenAi_2.4G") }
                            .buttonStyle(.bordered)
                            .disabled(model.busy)
                        Spacer()
                    }
                    if !model.hotspotStatus.isEmpty {
                        Text(model.hotspotStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("状态") {
                    Toggle("已上线", isOn: $wantOnline)
                        .disabled(!canOperate)
                        .onChange(of: wantOnline) { value in
                            model.setOnline(value, user: user, password: password)
                        }
                    HStack {
                        Text(model.status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.busy { ProgressView() }
                    }
                }

                Section("日志") {
                    ShareLink(item: model.log.fileURL) {
                        Label("获取日志文件", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        model.log.clear()
                    } label: {
                        Label("清空日志", systemImage: "trash")
                    }
                }

                Section("最近日志") {
                    ScrollView {
                        Text(model.log.tail.isEmpty ? "（暂无）" : model.log.tail)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 240)
                }
            }
            .navigationTitle("校园网")
            .onAppear { model.log.ensureFile() }
            .onChange(of: model.busy) { busy in
                // 动作结束后同步开关：登录失败时自动弹回
                if !busy { wantOnline = model.isOnline }
            }
            .onChange(of: model.isOnline) { online in
                if !model.busy { wantOnline = online }
            }
            .sheet(isPresented: $model.showWeb) {
                PortalSheet(model: model)
            }
        }
    }
}

/// 承载 WKWebView 的弹层。登录过程中门户页面可见，出验证码也能手填。
struct PortalSheet: View {
    @ObservedObject var model: PortalModel
    @Environment(\.dismiss) private var dismiss
    @State private var didAttach = false

    var body: some View {
        NavigationStack {
            WebContainer(model: model)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("门户")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
                .onAppear {
                    if !didAttach {
                        didAttach = true
                        DispatchQueue.main.async { model.attached() }
                    }
                }
        }
    }
}

struct WebContainer: UIViewRepresentable {
    let model: PortalModel

    func makeUIView(context: Context) -> WKWebView {
        model.ensureWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

#Preview {
    ContentView()
}
