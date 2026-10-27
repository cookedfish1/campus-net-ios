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
                if !busy { wantOnline = model.isOnline }
            }
            .onChange(of: model.isOnline) { online in
                if !model.busy { wantOnline = online }
            }
            .sheet(isPresented: $model.showWeb) {
                PortalSheet(model: model)
            }
        }
        // 隐藏宿主：1×1、透明度 0.01、不可交互。
        // 必须留在视图树里——WKWebView 没有 window 就不会加载；
        // 也不能用 isHidden，WebKit 会判定不可见而节流。
        .background(alignment: .topLeading) {
            HiddenHost(model: model)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
    }
}

struct HiddenHost: UIViewRepresentable {
    let model: PortalModel

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        container.isUserInteractionEnabled = false
        container.alpha = 0.01
        container.clipsToBounds = true

        let wv = model.ensureHiddenWebView()
        wv.frame = container.bounds
        wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(wv)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 兜底用的可见门户页（自动化失败时才弹出）
struct PortalSheet: View {
    @ObservedObject var model: PortalModel
    @Environment(\.dismiss) private var dismiss

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
        }
    }
}

struct WebContainer: UIViewRepresentable {
    let model: PortalModel

    func makeUIView(context: Context) -> WKWebView {
        model.ensureVisibleWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

#Preview {
    ContentView()
}
