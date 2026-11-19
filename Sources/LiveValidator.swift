import Foundation
import Photos

/// 用系统自己的判据验证「静帧 + 配对视频」到底能不能被加载成一张合法 Live Photo。
///
/// 这是整套流程里唯一真正的裁判：静态轨结构再怎么对齐真机，也只是「看起来对」；
/// Apple 官方文档 `PHLivePhoto.request(withResourceFileURLs:...)` 明确写着：
///   "Photos loads, validates, and prepares data ... If Photos cannot load a Live Photo
///    from the specified files, the result parameter ... is nil, and the info dictionary
///    contains an NSError object describing the error."
/// fileURLs 只放 still URL + video URL 两项，顺序无关。
///
/// 同步等待：调用方已经在后台队列，这里用信号量把异步回调拉平，并设硬超时。
/// 验证失败不抛错、不阻断导出——只返回 verdict 供上层择优 + 写日志定位。
enum LiveValidator {

    struct Verdict {
        /// 系统成功加载为 Live Photo（高置信可设壁纸）
        var accepted = false
        var errorText = ""
        var elapsed: TimeInterval = 0
        var isAccepted: Bool { accepted }
    }

    /// - Parameter timeout: 单次验证硬超时（秒）。封面搜索会跑多次，默认给 8 秒。
    static func validate(photoURL: URL,
                         videoURL: URL,
                         timeout: TimeInterval = 8) -> Verdict {
        var v = Verdict()
        let start = Date()
        let sem = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var finished = false

        // 结果回调可能被多次调用（先 degraded 低清、后完整）。以最后一次非 degraded 为准。
        PHLivePhoto.request(withResourceFileURLs: [photoURL, videoURL],
                            placeholderImage: nil,
                            targetSize: .zero,
                            contentMode: .aspectFit) { live, info in
            let degraded = (info[PHLivePhotoInfoIsDegradedKey] as? Bool) ?? false
            // 只认非 degraded 的最终结果，避免把「只有静帧的低清占位」误判成通过。
            if !degraded {
                lock.lock()
                if !finished {
                    finished = true
                    v.accepted = (live != nil)
                    if live == nil {
                        if let err = info[PHLivePhotoInfoErrorKey] as? Error {
                            v.errorText = err.localizedDescription
                        } else {
                            v.errorText = "系统未能加载为 Live Photo（未返回错误详情）"
                        }
                    }
                }
                lock.unlock()
                sem.signal()
            }
        }

        _ = sem.wait(timeout: .now() + timeout)
        v.elapsed = Date().timeIntervalSince(start)
        if !finished {
            v.errorText = "系统验证超时 \(Int(timeout))s（无法判定，按未通过处理）"
        }
        return v
    }
}
