import Foundation

/// 门户跳转里带出来的信息
struct PortalInfo {
    let pageURL: URL
    let userIP: String
    let acName: String
    let ssid: String
}

enum PortalError: Error, LocalizedError {
    case noResponse
    case notCaptive(Int)
    case badRedirect(String)

    var errorDescription: String? {
        switch self {
        case .noResponse:            return "探针无响应"
        case .notCaptive(let code):  return "当前不是未认证状态（HTTP \(code)）"
        case .badRedirect(let loc):  return "跳转地址异常：\(loc)"
        }
    }
}

/// 阻止自动跟随 302，才能拿到门户的 Location
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class PortalClient {
    static let probeURL = URL(string: "http://connect.rom.miui.com/generate_204")!

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpShouldSetCookies = true
        return URLSession(configuration: cfg,
                          delegate: NoRedirectDelegate(),
                          delegateQueue: nil)
    }()

    /// nil 表示已在线；否则返回门户信息
    func detect() async throws -> PortalInfo? {
        var req = URLRequest(url: Self.probeURL)
        req.timeoutInterval = 12
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: req)
        } catch {
            throw PortalError.noResponse
        }
        guard let http = result.1 as? HTTPURLResponse else { throw PortalError.noResponse }

        if http.statusCode == 204 { return nil }

        let loc = http.value(forHTTPHeaderField: "Location") ?? ""
        guard loc.contains("portal.wlan"), let url = URL(string: loc) else {
            throw PortalError.badRedirect(loc)
        }
        let q = Self.parseQuery(url)
        return PortalInfo(pageURL: url,
                          userIP: q["wlanuserip"] ?? "",
                          acName: q["wlanacname"] ?? "",
                          ssid: q["ssid"] ?? "")
    }

    /// 直接探测是否已放行
    func isOnline() async -> Bool {
        var req = URLRequest(url: Self.probeURL)
        req.timeoutInterval = 8
        guard let result = try? await session.data(for: req),
              let http = result.1 as? HTTPURLResponse else { return false }
        return http.statusCode == 204
    }

    static func parseQuery(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else { return out }
        for item in items {
            out[item.name.lowercased()] = item.value ?? ""
        }
        return out
    }
}
