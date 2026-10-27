import Foundation
import WebKit
import Combine

/// 核心流程（隐藏模式）：
///   1×1 的 WKWebView 挂在视图树里（不 isHidden，避免 WebKit 判定不可见而挂起）
///   Swift 定时器每 250ms 注入一次「查找表单 → 填 → 提交」
///   提交后每 800ms 探测 204
///   成功 → 静默；失败 → 自动弹出可见门户页供人工处理（验证码 / 异常）
///
/// 为什么不用 JS 的 setInterval：非可见 webview 里定时器会被节流到 ≥1 秒甚至暂停，
/// 由 App 侧驱动才稳定。
final class PortalModel: NSObject, ObservableObject {
    @Published var status = "未检测"
    @Published var busy = false
    @Published var showWeb = false
    @Published var isOnline = false
    @Published var hotspotStatus = ""

    let log = LogStore()
    let client = PortalClient()
    let sessionStore = SessionStore()
    let provider: PortalProvider = RenAiProvider()

    let logoutClient = LogoutClient()

    /// 自动化用的隐藏 webview（常驻）
    private var hiddenWV: WKWebView?
    /// 兜底用的可见 webview（需要人工时创建）
    private var visibleWV: WKWebView?
    private var portalURL: URL?
    private var user = ""
    private var password = ""

    private var injectTimer: Timer?
    private var injectTries = 0
    private var pollTimer: Timer?
    private var pollTicks = 0

    private static var ruleList: WKContentRuleList?
    private static var ruleListTried = false

    override init() {
        super.init()
        compileRuleListIfNeeded()
    }

    // MARK: - 构建 webview

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

    private func makeWebView() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let ucc = WKUserContentController()
        if let list = Self.ruleList { ucc.add(list) }
        cfg.userContentController = ucc
        cfg.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: cfg)
        wv.navigationDelegate = self
        wv.isUserInteractionEnabled = false
        return wv
    }

    func ensureHiddenWebView() -> WKWebView {
        if let wv = hiddenWV { return wv }
        let wv = makeWebView()
        hiddenWV = wv
        return wv
    }

    func ensureVisibleWebView() -> WKWebView {
        if let wv = visibleWV { return wv }
        let wv = makeWebView()
        wv.isUserInteractionEnabled = true
        visibleWV = wv
        return wv
    }

    // MARK: - 上线

    func startLogin(user: String, password: String) {
        guard !busy else { return }
        self.user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
        busy = true
        status = "检测网络…"
        log.log("=== 开始上线（隐藏模式）===")

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
                    self.portalURL = p.pageURL
                    self.status = "登录中…"
                    self.loadInHidden(p.pageURL)
                    self.startInjecting()
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

    private func loadInHidden(_ url: URL) {
        let wv = ensureHiddenWebView()
        wv.load(URLRequest(url: url, timeoutInterval: 30))
        log.log("加载门户（隐藏）：\(url.absoluteString)")
    }

    // MARK: - 注入（Swift 驱动）

    private func startInjecting() {
        injectTimer?.invalidate()
        injectTries = 0
        injectTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.injectTries += 1
            if self.injectTries > 80 {          // 20 秒
                timer.invalidate()
                self.fallbackToManual("页面里找不到登录表单")
                return
            }
            self.tryFill()
        }
    }

    private func tryFill() {
        guard let wv = hiddenWV else { return }
        wv.evaluateJavaScript(fillJS) { [weak self] result, error in
            guard let self else { return }
            if let error = error {
                if self.injectTries % 8 == 0 {
                    self.log.log("注入异常：\(error.localizedDescription)")
                }
                return
            }
            let r = (result as? String) ?? ""
            if r.hasPrefix("submitted") {
                self.injectTimer?.invalidate()
                self.injectTimer = nil
                self.log.log("已提交：\(r)")
                self.startPolling()
            } else if self.injectTries % 8 == 0 {
                self.log.log("等待表单… \(r)")
            }
        }
    }

    private var fillJS: String {
        """
        (function(){
          if (window.__cnSubmitted) { return 'submitted|already'; }
          function collect(doc){
            var out=[];
            doc.querySelectorAll('input').forEach(function(e){ out.push((e.id||'')+'/'+(e.name||'')); });
            return out.join(',');
          }
          function find(doc, depth){
            if (depth > 3) { return null; }
            if (doc.querySelector('\(provider.userSelectors)')) { return doc; }
            var fr = doc.querySelectorAll('iframe,frame');
            for (var i=0;i<fr.length;i++){
              try { var d = fr[i].contentDocument; if (d) { var r = find(d, depth+1); if (r) { return r; } } } catch(e) {}
            }
            return null;
          }
          var d = find(document, 0);
          if (!d) { return 'noform|' + location.href + '|' + collect(document); }
          var u = d.querySelector('\(provider.userSelectors)');
          var p = d.querySelector('\(provider.passwordSelectors)');
          if (!u || !p) { return 'partial|' + location.href + '|' + collect(d); }
          u.value = \(Self.jsLiteral(user));
          p.value = \(Self.jsLiteral(password));
          var f = u.form || d.querySelector('\(provider.formSelectors)');
          if (!f) { return 'noform-element'; }
          window.__cnSubmitted = true;
          try { f.submit(); } catch(e) { return 'submit-error|' + e; }
          return 'submitted|' + (f.action || '');
        })();
        """
    }

    // MARK: - 判定

    private func startPolling() {
        pollTimer?.invalidate()
        pollTicks = 0
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
                        self.fallbackToManual("提交后 20 秒仍未被放行")
                    }
                }
            }
        }
    }

    private func finishOK() {
        log.log("✓ 登录成功（探针已放行）")
        status = "已登录"
        isOnline = true
        busy = false
        showWeb = false
        captureSession()
        if let wv = hiddenWV {
            wv.loadHTMLString("<html><body></body></html>", baseURL: nil)
        }
    }

    // MARK: - 兜底：转人工

    private func fallbackToManual(_ reason: String) {
        log.log("转为人工处理：\(reason)")
        status = "需要手动处理：\(reason)"
        isOnline = false
        busy = false
        injectTimer?.invalidate()
        injectTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil

        if let url = portalURL {
            visibleWV = nil            // 用干净的实例，避免和隐藏实例抢同一个 webview
            let wv = ensureVisibleWebView()
            wv.load(URLRequest(url: url, timeoutInterval: 30))
            log.log("已打开可见门户：\(url.absoluteString)")
        }
        showWeb = true
    }

    // MARK: - 保存会话

    private func captureSession() {
        guard let wv = hiddenWV else { return }
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
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    let online = await self.client.isOnline()
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
}

// MARK: - WKNavigationDelegate

extension PortalModel: WKNavigationDelegate {
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
