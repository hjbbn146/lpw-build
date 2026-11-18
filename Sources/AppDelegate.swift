import UIKit

// 类名固定成 LPWAppDelegate / LPWSceneDelegate，
// main.swift 传给 UIApplicationMain 的字符串必须与这里一致。
@objc(LPWAppDelegate)
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Diag.mark("app:didFinishLaunching")
        return true
    }

    // iOS 13+ / iOS 26 强制 UIScene 生命周期：由这里给出 scene 配置
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let cfg = UISceneConfiguration(name: "LPW Default", sessionRole: connectingSceneSession.role)
        cfg.delegateClass = SceneDelegate.self
        return cfg
    }
}

@objc(LPWSceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        Diag.mark("scene:willConnect")
        guard let ws = scene as? UIWindowScene else {
            Diag.mark("scene:notWindowScene")
            return
        }
        let w = UIWindow(windowScene: ws)
        w.backgroundColor = Theme.background
        w.rootViewController = RootViewController()
        w.makeKeyAndVisible()
        self.window = w
        Diag.mark("scene:rootShown")
    }
}
