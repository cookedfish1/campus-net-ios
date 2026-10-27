import Foundation
import WebKit
import Combine

/// 最小验证：探测门户 → 无头（但可见）WKWebView 加载 → 注入账号密码并提交 → 判定结果
final class PortalModel: NSObject, ObservableObject {
    @Published var status = "未检测"
    @Published var busy = false
    @Published var showWeb = false

    let log = LogStore()
    let client = PortalClient()

    private var webView: WKWebView?
    private var pendingURL: URL?
    private var user = ""
    private var password = ""

    private enum Phase { case idle, loading, submitting, finished }
    private var phase: Phase = .idle

    // MARK: - WebView

    func ensureWebView() -> WKWebView {
        if let wv = webView { return wv }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = false
        webView = wv
        return wv
    }

    /// 视图进入层级后再发起加载（WKWebView 必须有 window 才稳定渲染）
    func attached() {
        guard let wv = webView, let url = pendingURL else { return }
        pendingURL = nil
        phase = .loading
        log.log("加载门户：\(url.absoluteString)")
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        wv.load(req)
    }

    // MARK: - 入口

    func startLogin(user: String, password: String) {
        guard !busy else { return }
        self.user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
        busy = true
        phase = .idle
        status = "检测网络…"
        log.log("=== 开始上线 ===")

        Task {
            do {
                let info = try await client.detect()
                if info == nil {
                    self.log.log("探测结果：已在线（HTTP 204）")
                    DispatchQueue.main.async {
                        self.status = "已在线，无需登录"
                        self.busy = false
                    }
                    return
                }
                let p = info!
                self.log.log("未认证 → IP=\(p.userIP)  AC=\(p.acName)  SSID=\(p.ssid)")
                DispatchQueue.main.async {
                    self.pendingURL = p.pageURL
                    self.status = "打开门户…"
                    self.showWeb = true
                }
            } catch {
                self.log.log("探测失败：\(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.status = "检测失败：\(error.localizedDescription)"
                    self.busy = false
                }
            }
        }
    }

    // MARK: - 判定

    private func handleFinish() {
        guard let wv = webView else { return }
        switch phase {
        case .loading:
            phase = .submitting
            injectCredentials(into: wv)
        case .submitting:
            inspectResult(on: wv)
        default:
            break
        }
    }

    private func injectCredentials(into wv: WKWebView) {
        let js = """
        (function(){
          var u = document.getElementById('Wp_user');
          var p = document.getElementById('Wp_password');
          if (!u || !p) { return 'noform'; }
          u.value = \(Self.jsLiteral(user));
          p.value = \(Self.jsLiteral(password));
          var f = document.getElementById('loginForm');
          if (f) { f.submit(); return 'submitted'; }
          return 'noform';
        })();
        """
        wv.evaluateJavaScript(js) { result, error in
            if let e = error {
                self.log.log("注入异常：\(e.localizedDescription)")
            }
            self.log.log("注入结果：\(String(describing: result ?? "nil"))")
        }
    }

    private func inspectResult(on wv: WKWebView) {
        wv.evaluateJavaScript("document.documentElement.outerHTML") { result, error in
            if let e = error {
                self.log.log("读取结果页失败：\(e.localizedDescription)")
            }
            let html = (result as? String) ?? ""
            self.log.log("结果页长度：\(html.count)")

            let alertText = Self.extractAlert(html)
            if let a = alertText { self.log.log("服务器提示：\(a)") }

            let looksOK = html.contains("logoutLeave") || html.contains("portalLoginRedirect")
            if looksOK {
                self.finishOK()
                return
            }

            Task {
                let online = await self.client.isOnline()
                DispatchQueue.main.async {
                    if online {
                        self.finishOK()
                    } else {
                        self.finishFail(alertText ?? "未识别到成功页，且外网仍不通")
                    }
                }
            }
        }
    }

    private func finishOK() {
        log.log("✓ 登录成功（探针已放行）")
        status = "已登录"
        busy = false
        phase = .finished
        showWeb = false
    }

    private func finishFail(_ reason: String) {
        log.log("✗ 登录失败：\(reason)")
        status = "失败：\(reason)"
        busy = false
        phase = .finished
        showWeb = false
    }

    // MARK: - 工具

    private static func jsLiteral(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    private static func extractAlert(_ html: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "alert\\(\"([^\"]*)\"\\)") else { return nil }
        let ns = html as NSString
        guard let m = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}

// MARK: - WKNavigationDelegate

extension PortalModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.async { self.handleFinish() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log.log("导航失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log.log("导航失败(provisional)：\(error.localizedDescription)")
    }

    /// 门户是自签证书，必须放行，否则页面根本打不开
    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            log.log("接受证书：\(challenge.protectionSpace.host)")
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
