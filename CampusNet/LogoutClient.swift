import Foundation

/// 允许自签证书的 URLSession（下线接口是 https + 自签）
final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
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

final class LogoutClient {
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg, delegate: TrustAllDelegate(), delegateQueue: nil)
    }

    func logout(using saved: SavedSession, urlString: String) async throws {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        guard let url = URL(string: "\(urlString)?\(ts)&isCloseWindow=N") else {
            throw NSError(domain: "CampusNet", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "下线地址无效"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(saved.cookieHeader, forHTTPHeaderField: "Cookie")
        req.httpBody = saved.formEncoded().data(using: .utf8)

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8) ?? ""
        if code >= 400 {
            throw NSError(domain: "CampusNet", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "下线接口返回 \(code)"])
        }
        if !body.isEmpty && !body.contains("下线成功") && !body.contains("success") {
            // 门户无论成败都会说成功，这里仅作记录，最终以探针为准
        }
    }
}
