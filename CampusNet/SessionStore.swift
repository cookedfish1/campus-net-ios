import Foundation

/// 登录成功后保存的会话：下线要用「登录当时的 cookie + 下线表单字段」，
/// 这两样只在登录那一刻存在（重新打开成功页会得到空字段）。
struct SavedSession: Codable {
    var fields: [String: String]
    var cookies: [String: String]
    var savedAt: Date
}

extension SavedSession {
    var isUsable: Bool { !fields.isEmpty && !cookies.isEmpty }

    /// 表单编码（严格转义，避免 & = 破坏 body）
    func formEncoded() -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    var cookieHeader: String {
        cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }
}

final class SessionStore {
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = dir.appendingPathComponent("session.json")
    }

    func save(fields: [String: String], cookies: [String: String]) {
        let s = SavedSession(fields: fields, cookies: cookies, savedAt: Date())
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: url)
    }

    func load() -> SavedSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedSession.self, from: data)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
