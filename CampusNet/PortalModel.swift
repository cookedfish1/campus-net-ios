import Foundation
import WebKit
import Combine

/// 最小验证：探测门户 → WKWebView 加载 → 注入账号密码并提交 → 轮询 204 判定
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

    private enum Phase { case idle, loading, submitted, finished }
    private var phase: Phase = .idle
    private var injectAttempt = 0
    private var pollTimer: Timer?
    private var pollTicks = 0

    // MARK: - WebView

    func ensureWebView() -> WKWebView {
        if let wv = webView { return wv }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        webView = wv
        return wv
    }

    /// 视图进入层级后再加载（WKWebView 需要有 window 才稳定）
    func attached() {
        guard let wv = webView, let url = pendingURL else { return }
        pendingURL = nil
        phase = .loading
        injectAttempt = 0
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

    // MARK: - 注入

    private func scheduleInject(into wv: WKWebView, delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.inject(into: wv)
        }
    }

    private func inject(into wv: WKWebView) {
        injectAttempt += 1
        if injectAttempt > 4 {
            log.log("注入放弃：连续 \(injectAttempt - 1) 次没找到表单")
            finishFail("页面里找不到账号/密码输入框")
            return
        }

        let js = """
        (function(){
          function collect(doc){
            var out=[], els=doc.querySelectorAll('input');
            for(var i=0;i<els.length && i<12;i++){ out.push((els[i].id||'')+'/'+(els[i].name||'')+'/'+(els[i].type||'')); }
            return out.join(',');
          }
          function findDoc(doc, depth){
            if (depth > 3) { return null; }
            if (doc.querySelector('#Wp_user, input[name=userName], #username, input[name=username]')) { return doc; }
            var fr = doc.querySelectorAll('iframe,frame');
            for (var i=0;i<fr.length;i++){
              try {
                var d = fr[i].contentDocument;
                if (d) { var r = findDoc(d, depth+1); if (r) { return r; } }
              } catch(e) {}
            }
            return null;
          }
          var d = findDoc(document, 0);
          var url = location.href;
          if (!d) {
            return 'noform|url=' + url + '|title=' + document.title
              + '|frames=' + document.querySelectorAll('iframe,frame').length
              + '|inputs=' + collect(document);
          }
          var u = d.querySelector('#Wp_user, input[name=userName], #username, input[name=username]');
          var p = d.querySelector('#Wp_password, input[name=userPwd], #pwd, input[name=password]');
          if (!u || !p) { return 'partial|url=' + url + '|inputs=' + collect(d); }
          u.value = \(Self.jsLiteral(user));
          p.value = \(Self.jsLiteral(password));
          var f = u.form || d.getElementById('loginForm');
          if (!f) { f = d.querySelector('form'); }
          if (!f) { return 'noform-element|url=' + url + '|inputs=' + collect(d); }
          try { f.submit(); } catch(e) { return 'submit-error|' + e; }
          return 'submitted|url=' + d.location.href + '|action=' + (f.action || '');
        })();
        """

        wv.evaluateJavaScript(js) { result, error in
            if let e = error {
                self.log.log("注入异常：\(e.localizedDescription)")
            }
            let r = (result as? String) ?? "nil"
            self.log.log("注入[\(self.injectAttempt)]：\(r)")

            if r.hasPrefix("submitted") {
                self.phase = .submitted
                self.startPolling()
            } else if r.hasPrefix("noform") || r.hasPrefix("partial") || r.hasPrefix("nil") {
                // 表单可能是异步渲染的，等一下再试
                self.scheduleInject(into: wv, delay: 1.2)
            } else {
                self.finishFail("注入失败：\(r)")
            }
        }
    }

    // MARK: - 轮询判定

    private func startPolling() {
        pollTimer?.invalidate()
        pollTicks = 0
        log.log("已提交，开始轮询放行状态…")
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.pollTicks += 1
            Task {
                let online = await self.client.isOnline()
                if online {
                    DispatchQueue.main.async {
                        timer.invalidate()
                        self.finishOK()
                    }
                } else if self.pollTicks >= 12 {
                    DispatchQueue.main.async {
                        timer.invalidate()
                        self.dumpPageAfterFailure()
                    }
                }
            }
        }
    }

    private func dumpPageAfterFailure() {
        guard let wv = webView else { finishFail("等待 24 秒仍未被放行"); return }
        wv.evaluateJavaScript("document.documentElement.outerHTML") { result, _ in
            let html = (result as? String) ?? ""
            self.log.log("失败页长度：\(html.count)")
            if let a = Self.extractAlert(html) { self.log.log("服务器提示：\(a)") }
            let plain = Self.plainText(html)
            if !plain.isEmpty { self.log.log("失败页文本：\(String(plain.prefix(300)))") }
            self.finishFail("等待 24 秒仍未被放行")
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

    private static func plainText(_ html: String) -> String {
        let noScript = html.replacingOccurrences(of: "<script[\\s\\S]*?</script>",
                                                 with: " ",
                                                 options: .regularExpression)
        let noTags = noScript.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let collapsed = noTags.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - WKNavigationDelegate

extension PortalModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let current = webView.url?.absoluteString ?? "?"
        log.log("加载完成：\(current)")
        if phase == .loading {
            scheduleInject(into: webView, delay: 0.6)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log.log("导航失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log.log("导航失败(provisional)：\(error.localizedDescription)")
    }

    /// 门户是自签证书，必须放行
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
