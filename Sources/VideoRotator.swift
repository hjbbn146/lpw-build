import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics

/// 把「横屏编码 + 旋转矩阵」的视频物理旋转成「竖屏编码 + 单位矩阵」。
///
/// 为什么非做不可（2026-11-19 真机取证）：
///   iPhone 竖屏拍的普通视频是「1920×1080 编码 + 90° 旋转矩阵」；
///   而 iOS 实况照片的配对视频**永远是「1080×1920 物理编码 + 单位矩阵」**。
///   三个「确定能设壁纸」的样本（p0066 真机自拍、p0061/p0065 第三方可用产物）全都是这样。
///
/// 我们之前把源视频的 preferredTransform 写进 tkhd，产物就成了「1920×1080 + 90°」：
///   系统按 tkhd 认它是横屏，而静帧是从显示方向取的竖图（1080×1920），
///   两者比例对不上 → 壁纸按钮永远是灰的。自检用 preferredTransform 算显示尺寸，
///   所以一直误判为「尺寸匹配」。
///
/// 旋转无法在压缩域完成（H.265 宏块不能简单重排），必须解码→旋转→编码一次。
/// 这里用系统最高质量的 HEVC 预设，视觉上几乎无损。
enum VideoRotator {

    /// 源视频的 tkhd 矩阵是否需要物理旋转
    static func needsRotation(_ t: AVAssetTrack) -> Bool {
        let m = t.preferredTransform
        let identity = abs(m.a - 1) < 0.01 && abs(m.b) < 0.01
            && abs(m.c) < 0.01 && abs(m.d - 1) < 0.01
        return !identity
    }

    /// 旋转导出为物理竖屏的 MOV（HEVC 最高质量）。同步等待，带硬超时。
    /// - Returns: 实际导出的时长（秒）
    @discardableResult
    static func rotate(source: URL,
                       outputURL: URL,
                       maxSeconds: Double,
                       progress: @escaping (String) -> Void) throws -> Double {

        let asset = AVURLAsset(url: source,
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let vTrack = asset.tracks(withMediaType: .video).first else {
            throw MakeError.msg("源文件里没有视频轨")
        }
        let tf = vTrack.preferredTransform
        let natural = vTrack.naturalSize
        let disp = natural.applying(tf)
        let renderW = max(2, Int(abs(disp.width).rounded()))
        let renderH = max(2, Int(abs(disp.height).rounded()))
        // 渲染尺寸强制偶数（HEVC 要求）
        let rw = renderW % 2 == 0 ? renderW : renderW + 1
        let rh = renderH % 2 == 0 ? renderH : renderH + 1

        let total = CMTimeGetSeconds(asset.duration)
        let use = min(total, maxSeconds > 0.2 ? maxSeconds : 2.9)
        let fps = max(24, min(60, Int(vTrack.nominalFrameRate.rounded())))
        Diag.log("旋转：源编码 \(Int(natural.width))×\(Int(natural.height)) → 渲染 \(rw)×\(rh) · \(fps)fps · 取 \(String(format: "%.2f", use))s")

        let comp = AVMutableVideoComposition()
        comp.renderSize = CGSize(width: rw, height: rh)
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        let inst = AVMutableVideoCompositionInstruction()
        inst.timeRange = CMTimeRange(start: .zero,
                                     duration: CMTime(seconds: use, preferredTimescale: 600))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
        layer.setTransform(tf, at: .zero)
        inst.layerInstructions = [layer]
        comp.instructions = [inst]

        try? FileManager.default.removeItem(at: outputURL)
        guard let ex = AVAssetExportSession(asset: asset,
                                            presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw MakeError.msg("无法创建旋转导出会话（系统不支持 HEVC 预设）")
        }
        ex.videoComposition = comp
        ex.outputURL = outputURL
        ex.outputFileType = .mov
        ex.shouldOptimizeForNetworkUse = false
        ex.timeRange = CMTimeRange(start: .zero,
                                   duration: CMTime(seconds: use, preferredTimescale: 600))

        progress("旋转为竖屏（Live Photo 要求）…")
        let sem = DispatchSemaphore(value: 0)
        ex.exportAsynchronously { sem.signal() }
        if sem.wait(timeout: .now() + 240) == .timedOut {
            ex.cancelExport()
            throw MakeError.msg("旋转导出超时 240 秒")
        }
        guard ex.status == .completed else {
            throw MakeError.msg("旋转导出失败：\(ex.error?.localizedDescription ?? "状态 \(ex.status.rawValue)")")
        }
        let outBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.doubleValue ?? 0
        Diag.log("旋转完成 · \(String(format: "%.1f", outBytes / 1_048_576.0))MB")
        return use
    }
}
