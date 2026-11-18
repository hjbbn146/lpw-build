import UIKit

// 入口。
// 第 4 个参数直接传 ObjC 类名字符串，避开 NSStringFromClass 带模块前缀的问题。
// AppDelegate 类用 @objc(LPWAppDelegate) 固定名字，两边必须一致。
exit(UIApplicationMain(CommandLine.argc,
                       CommandLine.unsafeArgv,
                       nil,
                       "LPWAppDelegate"))
