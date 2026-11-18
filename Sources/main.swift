import UIKit

// 崩溃取证要在一切之前装好：只要进程还在，任何 ObjC 异常 / 致命信号
// 都会把调用栈落到 Documents/crash.log，重启 App 后可以直接复制出来。
CrashCatcher.install()

// 每次冷启动追加一行分隔，保留上一次的记录（上次可能是闪退，别覆盖掉）
Diag.log("============ 新一次启动 · iOS \(UIDevice.current.systemVersion) ============")
Diag.log("环境：" + Mem.summary())

// 入口。
// 第 4 个参数直接传 ObjC 类名字符串，避开 NSStringFromClass 带模块前缀的问题。
// AppDelegate 类用 @objc(LPWAppDelegate) 固定名字，两边必须一致。
exit(UIApplicationMain(CommandLine.argc,
                       CommandLine.unsafeArgv,
                       nil,
                       "LPWAppDelegate"))
