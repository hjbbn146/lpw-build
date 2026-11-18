import Foundation
import Darwin

/// 崩溃取证。
///
/// 目标很具体：**下次再闪退，要有调用栈可看**。
///
/// 两条路：
///  1. ObjC 异常（NSException）—— 代码写错这类，能抓全量符号化堆栈；
///  2. 致命信号（SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGTRAP）—— 运行期崩
///     （越界、野指针、assert、内存被回收…），抓裸地址栈。
///
/// 全部落盘到 Documents/crash.log。
///
/// 实现约束：signal handler 必须是**顶层函数**（不能是 `enum` 里的 static 闭包，
/// 否则 Swift 判定为捕获上下文，无法转成 C 函数指针），且内部只用
/// open/write/backtrace_symbols_fd —— 崩溃时堆可能已损坏，任何内存分配
/// 都可能二次死锁，反而一条栈都拿不到。

private typealias BTFn = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?, Int32) -> Int32
private typealias BTFDn = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?, Int32, Int32) -> Void

// ---- 文件级全局状态（handler 只读这些，不涉及任何对象/self）

private var gBT: BTFn?
private var gBTFd: BTFDn?
private var gCrashPath = [CChar]()
// 预分配，避免 handler 里再分配内存
private var gFrames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)

@inline(never)
private func cFd() -> Int32 {
    if gCrashPath.isEmpty { return -1 }
    var fd: Int32 = -1
    gCrashPath.withUnsafeBufferPointer { b in
        guard let base = b.baseAddress else { return }
        fd = open(base, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    }
    return fd
}

@inline(never)
private func cWrite(_ text: StaticString) {
    let f = cFd()
    if f < 0 { return }
    text.withUTF8Buffer { buf in
        if let p = buf.baseAddress, buf.count > 0 {
            _ = write(f, UnsafeRawPointer(p), buf.count)
        }
    }
    close(f)
}

@inline(never)
private func cStack() {
    let f = cFd()
    if f < 0 { return }
    if let bt = gBT {
        let n = gFrames.withUnsafeMutableBufferPointer { p -> Int32 in
            bt(p.baseAddress, 64)
        }
        if n > 0, let fdw = gBTFd {
            gFrames.withUnsafeMutableBufferPointer { p in
                fdw(p.baseAddress, n, f)
            }
        }
    }
    close(f)
}

// ---- 信号处理（顶层函数，可直接转成 C 函数指针）

private func crashSignalABRT(_ s: Int32) { cWrite("\n=== crash: SIGABRT ===\n"); cStack(); signal(s, SIG_DFL); raise(s) }
private func crashSignalSEGV(_ s: Int32) { cWrite("\n=== crash: SIGSEGV ===\n"); cStack(); signal(s, SIG_DFL); raise(s) }
private func crashSignalBUS(_ s: Int32)  { cWrite("\n=== crash: SIGBUS ===\n");  cStack(); signal(s, SIG_DFL); raise(s) }
private func crashSignalILL(_ s: Int32)  { cWrite("\n=== crash: SIGILL ===\n");  cStack(); signal(s, SIG_DFL); raise(s) }
private func crashSignalFPE(_ s: Int32)  { cWrite("\n=== crash: SIGFPE ===\n");  cStack(); signal(s, SIG_DFL); raise(s) }
private func crashSignalTRAP(_ s: Int32) { cWrite("\n=== crash: SIGTRAP ===\n"); cStack(); signal(s, SIG_DFL); raise(s) }

// ---- ObjC 异常（此时堆还健在，可以正常拼字符串）

private func crashException(_ ex: NSException) {
    let df = DateFormatter()
    df.dateFormat = "MM-dd HH:mm:ss"
    var text = "\n=== NSException @ \(df.string(from: Date())) ===\n"
    text += "name   : \(ex.name.rawValue)\n"
    text += "reason : \(ex.reason ?? "-")\n"
    text += "memory : " + Mem.summary() + "\n"
    text += "stack:\n" + ex.callStackSymbols.joined(separator: "\n") + "\n"
    guard let d = text.data(using: .utf8) else { return }
    let url = Diag.dir.appendingPathComponent("crash.log")
    if let fh = try? FileHandle(forWritingTo: url) {
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        _ = try? fh.write(contentsOf: d)
    } else {
        try? d.write(to: url)
    }
}

enum CrashCatcher {

    static var logURL: URL { Diag.dir.appendingPathComponent("crash.log") }

    static func install() {
        let path = Diag.dir.appendingPathComponent("crash.log").path
        gCrashPath = Array(path.utf8CString)

        // 这两个符号不在 iOS 公开头文件里，但 libSystem 里有；
        // 安装阶段解析一次，handler 里只读指针，绝不重复解析
        if let h = dlopen(nil, RTLD_NOW) {
            if let s = dlsym(h, "backtrace") {
                gBT = unsafeBitCast(s, to: BTFn.self)
            }
            if let s = dlsym(h, "backtrace_symbols_fd") {
                gBTFd = unsafeBitCast(s, to: BTFDn.self)
            }
        }

        NSSetUncaughtExceptionHandler(crashException)

        signal(SIGABRT, crashSignalABRT)
        signal(SIGSEGV, crashSignalSEGV)
        signal(SIGBUS, crashSignalBUS)
        signal(SIGILL, crashSignalILL)
        signal(SIGFPE, crashSignalFPE)
        signal(SIGTRAP, crashSignalTRAP)
    }

    static func readAll() -> String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }

    static var hasRecord: Bool {
        (try? Data(contentsOf: logURL))?.isEmpty == false
    }
}
