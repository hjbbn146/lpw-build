import Foundation
import Photos

/// 用系统自己的判据验证「静帧 + 配对视频」到底能不能被加载成一张合法 Live Photo。
///
/// Apple 官方文档 `PHLivePhoto.request(withResourceFileURLs:...)`：
///   "Photos loads, validates, and prepares data ... If Photos cannot load a Live Photo
///    from the specified files, the result parameter ... is nil, and the info dictionary
///    contains an NSError object describing the error."
/// fileURLs 只放 still URL + video URL 两项，顺序无关。
///
/// 结果用引用类型盒子承载，避免逃逸闭包捕获可变局部变量在 Swift 6 严格并发下报错。
/// 同步等待 + 硬超时；验证失败不抛错、不阻断导出，只返回 verdict 供上层择优与写日志。
enum LiveValidator {

    struct Verdict {
        /// 系统成功加载为 Live Photo（高置信可设壁纸）
        var accepted = false
        var errorText = ""
        var elapsed: TimeInterval = 0
        var isAccepted: Bool { accepted }
    }

    /// 线程安全结果盒（引用类型，逃逸闭包内只改其属性，不改捕获的 var 本身）
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var accepted = false
        var finished = false
        var errorText = ""
    }

    /// - Parameter timeout: 单次验证硬超时（秒）。封面搜索会跑多次，默认给 8 秒。
    static func validate(photoURL: URL,
                         videoURL: URL,
                         timeout: TimeInterval = 8) -> Verdict {
        let start = Date()
        let box = Box()
        let sem = DispatchSemaphore(value: 0)

        PHLivePhoto.request(withResourceFileURLs: [photoURL, videoURL],
                            placeholderImage: nil,
                            targetSize: .zero,
                            contentMode: .aspectFit) { live, info in
            let degraded = (info[PHLivePhotoInfoIsDegradedKey] as? Bool) ?? false
            // 只认非 degraded 的最终结果，避免把「只有静帧的低清占位」误判成通过。
            guard !degraded else { return }
            box.lock.lock()
            if !box.finished {
                box.finished = true
                box.accepted = (live != nil)
                if live == nil {
                    if let err = info[PHLivePhotoInfoErrorKey] as? Error {
                        box.errorText = err.localizedDescription
                    } else {
                        box.errorText = "系统未能加载为 Live Photo（未返回错误详情）"
                    }
                }
            }
            box.lock.unlock()
            sem.signal()
        }

        _ = sem.wait(timeout: .now() + timeout)
        var v = Verdict()
        box.lock.lock()
        v.accepted = box.accepted
        if !box.finished {
            v.errorText = "系统验证超时 \(Int(timeout))s（无法判定，按未通过处理）"
        } else {
            v.errorText = box.errorText
        }
        box.lock.unlock()
        v.elapsed = Date().timeIntervalSince(start)
        return v
    }
}
