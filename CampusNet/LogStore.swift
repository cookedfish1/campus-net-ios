import Foundation
import Combine

/// 极简日志：同时写内存（给界面）和沙盒文件（给「获取日志文件」导出）
final class LogStore: ObservableObject {
    @Published private(set) var lines: [String] = []
    let fileURL: URL

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("campusnet.log")
    }

    func ensureFile() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        }
    }

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > 500 {
                self.lines.removeFirst(self.lines.count - 500)
            }
        }

        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        DispatchQueue.main.async { self.lines.removeAll() }
        ensureFile()
    }

    var tail: String { lines.suffix(60).joined(separator: "\n") }
}
