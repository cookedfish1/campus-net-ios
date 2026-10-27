import SwiftUI
import WebKit

struct ContentView: View {
    @StateObject private var model = PortalModel()
    @AppStorage("cn.user") private var user: String = ""
    @State private var password: String = ""

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

                Section("操作") {
                    Button {
                        model.startLogin(user: user, password: password)
                    } label: {
                        HStack {
                            Text(model.busy ? "处理中…" : "上线（自动登录）")
                            Spacer()
                            if model.busy { ProgressView() }
                        }
                    }
                    .disabled(model.busy || user.isEmpty || password.isEmpty)

                    Text(model.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
            .sheet(isPresented: $model.showWeb) {
                PortalSheet(model: model)
            }
        }
    }
}

/// 承载 WKWebView 的弹层。登录过程中可见——出验证码时也能手动填。
struct PortalSheet: View {
    let model: PortalModel
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
