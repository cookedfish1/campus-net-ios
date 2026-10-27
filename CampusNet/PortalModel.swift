import Foundation
import WebKit
import Combine

/// 核心流程：探测门户 → WKWebView 打开 → documentEnd 自轮询填表提交 → 轮询 204 判定
///
/// 速度优化：不等 didFinish（它等于 window.onload，会被门户页的大图拖到 20 秒），
/// 改为在 documentEnd 注入一段自轮询脚本，一出现输入框就填并提交；同时用内容拦截器屏蔽图片。
final class PortalModel: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    @Published var status = "未检测"
    @Published var busy = false
    @Published var showWeb = false
    @Published var isOnline = false
    @Published var hotspotStatus = ""

    let log = LogStore()
    let client = PortalClient()
    let sessionStore = SessionStore()
    let provider: PortalProvider = RenAiProvider()

    private var webView: WKWebView?
    private var pendingURL: URL?
    private var user = ""
    private var password = ""

    private enum Phase { case idle, loading, submitted, finished }
    private var phase: Phase = .idle
    private var pollTimer: Timer?
    private var pollTicks = 0

    private static var ruleList: WKContentRuleList?
    private static var ruleListTried = false

    private let logoutClient = LogoutClient()

    override init() {
        super.init()
        compileRuleListIfNeeded()
    }

    // MARK: - 内容拦截：屏蔽图片

    private func compileRuleListIfNeeded() {
        guard !Self.ruleListTried else { return }
        Self.ruleListTried = true
        let json = """
        [{"trigger":{"url-filter":".*","resource-type":["image"]},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "cn-block-images",
                                                                encodedContentRuleList: json) { list, _ in
            Self.ruleList = list
        }
    }

    // MARK: - WebView

    private func makeWebView() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(self, name: "cnlog")
        ucc.addUserScript(WKUserScript(source: autoFillJS(),
                                       injectionTime: .atDocumentEnd,
                                       forMainFrameOnly: false))
        if let list = Self.ruleList { ucc.add(list) }
        cfg.userContentController = ucc
        cfg.websiteDataStore = .nonPersistent()

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        return wv
    }

    func ensureWebView() -> WKWebView {
        if let wv = webView { return wv }
        let wv = makeWebView()
        webView = wv
        return wv
    }

    private func recreateWebView() {
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = makeWebView()
    }

    private func autoFillJS() -> String {
        """
        (function(){
          if (window.__cnRunning) { return; }
          window.__cnRunning = true;
          var tries = 0;
          var timer = setInterval(function(){
            tries++;
            var u = document.querySelector('\(provider.userSelectors)');
            var p = document.querySelector('\(provider.passwordSelectors)');
            if (u && p) {
              clearInterval(timer);
              window.__cnRunning = false;
              u.value = \(Self.jsLiteral(user));
              p.value = \(Self.jsLiteral(password));
              var f = u.form || document.querySelector('\(provider.formSelectors)');
              if (!f) {
                window.webkit.messageHandlers.cnlog.postMessage('noform-element');
                return;
              }
              window.webkit.messageHandlers.cnlog.postMessage('submitted');
              try { f.submit(); } catch(e) {
                window.webkit.messageHandlers.cnlog.postMessage('submit-error|' + e);
              }
              return;
            }
            if (tries > 100) {
              clearInterval(timer);
              window.__cnRunning = false;
              var ids = [];
              document.querySelectorAll('input').forEach(function(e){
                ids.push((e.id || '') + '/' + (e.name || '') + '/' + (e.type || ''));
              });
              window.webkit.messageHandlers.cnlog.postMessage(
                'noform|url=' + location.href + '|inputs=' + ids.join(','));
            }
          }, 150);
        })();
        """
    }

    private func load(portal: URL) {
        pendingURL = portal
        phase = .loading
        pollTicks = 0
        log.log("加载门户：\(portal.absoluteString)")
        var req = URLRequest(url: portal)
        req.timeoutInterval = 30
        ensureWebView().load(req)
    }

    /// 供弹层出现后调用
    func attached() {
        guard webView?.url == nil, let url = pendingURL else { return }
        load(portal: url)
    }

    // MARK: - 上线

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
                guard let p = info else {
                    self.log.log("探测结果：已在线（HTTP 204）")
                    DispatchQueue.main.async {
                        self.status = "已在线，无需登录"
                        self.isOnline = true
                        self.busy = false
                    }
                    return
                }
                self.log.log("未认证 → IP=\(p.userIP)  AC=\(p.acName)  SSID=\(p.ssid)")
                DispatchQueue.main.async {
                    self.recreateWebView()
                    self.status = "打开门户…"
                    self.showWeb = true
                    self.pendingURL = p.pageURL
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

    func setOnline(_ want: Bool, user: String, password: String) {
        if want {
            startLogin(user: user, password: password)
        } else {
            startLogout()
        }
    }

    // MARK: - 脚本消息

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "cnlog", let body = message.body as? String else { return }
        DispatchQueue.main.async { self.handleScript(body) }
    }

    private func handleScript(_ s: String) {
        log.log("页面脚本：\(s)")
        if s == "submitted" {
            phase = .submitted
            startPolling()
        } else if s.hasPrefix("noform") {
            finishFail("页面里找不到登录表单")
        } else if s.hasPrefix("submit-error") {
            finishFail("表单提交出错")
        }
    }

    // MARK: - 判定

    private func startPolling() {
        pollTimer?.invalidate()
        pollTicks = 0
        log.log("已提交，轮询放行状态…")
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.pollTicks += 1
            Task {
                let online = await self.client.isOnline()
                if online {
                    DispatchQueue.main.async {
                        timer.invalidate()
                        self.finishOK()
                    }
                } else if self.pollTicks >= 25 {
                    DispatchQueue.main.async {
                        timer.invalidate()
                        self.dumpPageAfterFailure()
                    }
                }
            }
        }
    }

    private func dumpPageAfterFailure() {
        guard let wv = webView else { finishFail("等待 20 秒仍未被放行"); return }
        wv.evaluateJavaScript("document.documentElement.outerHTML") { result, _ in
            let html = (result as? String) ?? ""
            self.log.log("失败页长度：\(html.count)")
            if let a = Self.extractAlert(html) { self.log.log("服务器提示：\(a)") }
            let plain = Self.plainText(html)
            if !plain.isEmpty { self.log.log("失败页文本：\(String(plain.prefix(300)))") }
            self.finishFail("等待 20 秒仍未被放行")
        }
    }

    private func finishOK() {
        log.log("✓ 登录成功（探针已放行）")
        status = "已登录"
        isOnline = true
        busy = false
        phase = .finished
        showWeb = false
        captureSession()
    }

    private func finishFail(_ reason: String) {
        log.log("✗ 登录失败：\(reason)")
        status = "失败：\(reason)"
        isOnline = false
        busy = false
        phase = .finished
    }

    // MARK: - 保存会话（下线要用）

    private func captureSession() {
        guard let wv = webView else { return }
        let js = """
        (function(){
          var f = document.getElementById('formLogout');
          if (!f) { return '{}'; }
          var o = {};
          f.querySelectorAll('input').forEach(function(i){ if (i.name) { o[i.name] = i.value; } });
          return JSON.stringify(o);
        })();
        """
        wv.evaluateJavaScript(js) { result, _ in
            let json = (result as? String) ?? "{}"
            let data = json.data(using: .utf8) ?? Data()
            let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
            wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                var map: [String: String] = [:]
                for c in cookies where c.domain.contains("111.32.9.98") {
                    map[c.name] = c.value
                }
                self.sessionStore.save(fields: fields, cookies: map)
                self.log.log("会话已保存：字段 \(fields.count) 个 / cookie \(map.count) 个")
            }
        }
    }

    // MARK: - 下线

    func startLogout() {
        guard !busy else { return }
        busy = true
        status = "下线中…"
        log.log("=== 开始下线 ===")

        Task {
            guard let saved = sessionStore.load(), saved.isUsable else {
                self.log.log("没有可用会话：需要先成功登录一次")
                DispatchQueue.main.async {
                    self.status = "没有可用会话，请先登录一次"
                    self.busy = false
                }
                return
            }
            do {
                try await logoutClient.logout(using: saved, urlString: provider.logoutURL)
                // 轮询确认真的掉线
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    let online = await client.isOnline()
                    if !online {
                        self.log.log("✓ 已下线（探针回到门户）")
                        DispatchQueue.main.async {
                            self.status = "已下线"
                            self.isOnline = false
                            self.busy = false
                        }
                        return
                    }
                }
                self.log.log("✗ 下线未生效")
                DispatchQueue.main.async {
                    self.status = "下线未生效，可稍后再试"
                    self.busy = false
                }
            } catch {
                self.log.log("✗ 下线失败：\(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.status = "下线失败：\(error.localizedDescription)"
                    self.busy = false
                }
            }
        }
    }

    // MARK: - Wi-Fi 切换

    func join(ssid: String) {
        guard !busy else { return }
        status = "切换 Wi-Fi…"
        hotspotStatus = "正在切换到 \(ssid)…"
        log.log("请求加入 \(ssid)")
        Task {
            do {
                try await HotspotManager.shared.join(ssid: ssid)
                self.log.log("已发出加入请求：\(ssid)")
                DispatchQueue.main.async {
                    self.hotspotStatus = "已加入 \(ssid)"
                    self.status = "已切换，可点上线"
                }
            } catch {
                self.log.log("切换失败：\(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.hotspotStatus = "切换失败：\(error.localizedDescription)"
                    self.status = "切换失败"
                }
            }
        }
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
        let noScript = html.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ",
                                                 options: .regularExpression)
        let noTags = noScript.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let collapsed = noTags.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - WKNavigationDelegate

extension PortalModel {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log.log("加载完成：\(webView.url?.absoluteString ?? "?")")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log.log("导航失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        log.log("导航失败(provisional)：\(error.localizedDescription)")
    }

    /// 门户是自签证书，必须放行，否则页面打不开
    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
