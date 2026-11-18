import Foundation

// 轻量落盘日志：启动阶段写 boot.log，业务阶段写 lpw.log。
// 万一闪退，用户能在「文件 App → 无损实况」里把日志拿出来，直接定位卡在哪一步。
enum Diag {

    static let dir: URL = {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return u ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }()

    static var bootURL: URL { dir.appendingPathComponent("boot.log") }
    static var logURL: URL { dir.appendingPathComponent("lpw.log") }

    private static let lock = NSLock()
    private static var bootCleared = false

    static func mark(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        if !bootCleared {
            bootCleared = true
            try? "".write(to: bootURL, atomically: true, encoding: .utf8)
        }
        append(s + "\n", to: bootURL)
    }

    static func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let line = "[\(f.string(from: Date()))] \(s)\n"
        lock.lock(); defer { lock.unlock() }
        append(line, to: logURL)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .lpwLog, object: nil, userInfo: ["line": s])
        }
    }

    static func resetLog() {
        lock.lock(); defer { lock.unlock() }
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
    }

    private static func append(_ s: String, to url: URL) {
        guard let d = s.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            _ = try? fh.write(contentsOf: d)
        } else {
            try? d.write(to: url)
        }
    }
}

extension Notification.Name {
    static let lpwLog = Notification.Name("lpwLog")
}
