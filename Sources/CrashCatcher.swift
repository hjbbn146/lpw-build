import Foundation
import Darwin

/// 崩溃取证。
///
/// 目标很具体：**下次再闪退，要有调用栈可看**。
///
/// 两条路：
///  1. ObjC 异常（NSException）—— 这类是「代码写错」，能抓全量堆栈；
///  2. 致命信号（SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGTRAP）—— 这类是
///     运行期崩（数组越界、野指针、assert、内存被回收…），只能抓裸地址栈。
///
/// 落盘到 Documents/crash.log，重启 App 后在「文件 App → 无损实况」里可见，
/// 也可以点 App 里的「复制日志」一起复制出来。
///
/// 实现上刻意保守：signal handler 里只做 open/write/backtrace_symbols_fd，
/// 不调用 malloc、不拼接字符串、不用 DateFormatter —— 崩溃时堆已经可能坏了，
/// 任何内存分配都可能二次死锁，反而什么都拿不到。
enum CrashCatcher {

    private typealias BTFn = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?, Int32) -> Int32
    private typealias BTFDn = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?, Int32, Int32) -> Void

    // 这两个符号不在 iOS 公开头文件里，但 libSystem 里存在。
    // 用 dlsym 在安装阶段解析好，handler 里只读指针，绝不重复解析。
    private static var btFn: BTFn?
    private static var btFdFn: BTFDn?

    private static var pathBuf: [CChar] = []

    static func install() {
        let p = Diag.dir.appendingPathComponent("crash.log").path
        pathBuf = Array(p.utf8CString)

        let h = dlopen(nil, RTLD_NOW)
        if h != nil {
            if let s = dlsym(h, "backtrace") {
                btFn = unsafeBitCast(s, to: BTFn.self)
            }
            if let s = dlsym(h, "backtrace_symbols_fd") {
                btFdFn = unsafeBitCast(s, to: BTFDn.self)
            }
        }

        // ---- 1) ObjC 异常：这里可以安全地做字符串拼接
        NSSetUncaughtExceptionHandler { ex in
            let df = DateFormatter()
            df.dateFormat = "MM-dd HH:mm:ss"
            let head = "\n=== NSException @ \(df.string(from: Date())) ===\n"
                + "name   : \(ex.name.rawValue)\n"
                + "reason : \(ex.reason ?? "-")\n"
                + "memory : \(Mem.summary())\n"
                + "stack:\n"
            append(head + ex.callStackSymbols.joined(separator: "\n") + "\n")
        }

        // ---- 2) 致命信号
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, { s in
                writeStatic("\n=== fatal signal ===\n")
                writeNumber(Int(s))
                writeStatic("\n")
                dumpStack()
                // 恢复默认处理并重新抛出，让系统照常生成 .ips，两边都不丢
                signal(s, SIG_DFL)
                raise(s)
            })
        }
    }

    // MARK: - 安全写（崩溃上下文可用）

    private static func fd() -> Int32 {
        guard !pathBuf.isEmpty else { return -1 }
        return pathBuf.withUnsafeBufferPointer { b -> Int32 in
            guard let base = b.baseAddress else { return -1 }
            return open(base, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        }
    }

    private static func writeStatic(_ s: StaticString) {
        let f = fd()
        guard f >= 0 else { return }
        s.withUTF8Buffer { buf in
            if let p = buf.baseAddress, buf.count > 0 {
                _ = write(f, UnsafeRawPointer(p), buf.count)
            }
        }
        close(f)
    }

    /// 把整数写成十进制（不用 String(format:)，避免 malloc）
    private static func writeNumber(_ v: Int) {
        var n = v < 0 ? -v : v
        var digits = [UInt8](repeating: 0, count: 24)
        var i = 0
        repeat {
            digits[23 - i] = UInt8(48 + n % 10)
            n /= 10
            i += 1
        } while n > 0 && i < 24
        let f = fd()
        guard f >= 0 else { return }
        digits.withUnsafeBufferPointer { b in
            if let base = b.baseAddress {
                _ = write(f, UnsafeRawPointer(base + (24 - i)), i)
            }
        }
        close(f)
    }

    private static func dumpStack() {
        guard let bt = btFn else { return }
        let f = fd()
        guard f >= 0 else { return }
        var buf = [UnsafeMutableRawPointer?](repeating: nil, count: 96)
        let frames = buf.withUnsafeMutableBufferPointer { p in
            bt(p.baseAddress, 96)
        }
        if frames > 0, let fdw = btFdFn {
            buf.withUnsafeMutableBufferPointer { p in
                fdw(p.baseAddress, frames, f)
            }
        }
        close(f)
    }

    // MARK: - 常规追加（NSException 用）

    private static func append(_ s: String) {
        let url = Diag.dir.appendingPathComponent("crash.log")
        guard let d = s.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            _ = try? fh.write(contentsOf: d)
        } else {
            try? d.write(to: url)
        }
    }

    static var logURL: URL { Diag.dir.appendingPathComponent("crash.log") }

    static func readAll() -> String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }
}
