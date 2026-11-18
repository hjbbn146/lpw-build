import Foundation
import AVFoundation

/// 产物「能不能当锁屏实况壁纸」的结构自检。
///
/// 系统相册把 photo + pairedVideo 塞进同一资产后，PHAsset.mediaSubtypes 里
/// 一定会有 .photoLive —— 所以那个标志说明不了任何问题（v2.x 的坑就在这）。
/// 壁纸引擎看的是 MOV 本身的轨结构。
///
/// 基准是**真机自己拍的实况照片**（iPhone15,4 / iOS 27.2 实测）：
///   trak1 vide(hvc1) · trak2 soun(mp4a) · trak3 meta(live-photo-info)
///   trak4 meta(still-image-time) · moov/meta(content.identifier + make/model/software/creationdate)
///
/// 注意：**真机没有 video-orientation 轨**。我们内置样本里有那条轨（值是 6 = 再转 90°），
/// 早期版本照搬过来，跟 tkhd 的 90° 旋转矩阵叠成双重旋转 —— 竖屏变横屏、照片和视频
/// 尺寸对不上、壁纸按钮变灰，就是它。v4.1 起不再移植那条轨，这里也把它当**错误**报出来。
struct LiveCheck {

    var isHEVC = false
    var hasIdentifier = false
    var hasLivePhotoInfo = false
    var hasStillImageTime = false
    /// 出现了 video-orientation 轨 = 双重旋转风险
    var hasBadOrientationTrack = false
    /// 视频显示尺寸与静帧尺寸是否一致（不一致壁纸引擎会拒绝）
    var displaySize: CGSize = .zero
    var stillSize: CGSize = .zero

    var sizeMatches: Bool {
        guard displaySize.width > 0, stillSize.width > 0 else { return true }
        let a = displaySize.width / displaySize.height
        let b = stillSize.width / stillSize.height
        return abs(a - b) < 0.02
    }

    var missing: [String] {
        var m: [String] = []
        if !isHEVC { m.append("视频不是 HEVC") }
        if !hasIdentifier { m.append("缺 content.identifier") }
        if !hasLivePhotoInfo { m.append("缺 live-photo-info 轨") }
        if !hasStillImageTime { m.append("缺 still-image-time 轨") }
        if hasBadOrientationTrack { m.append("多出 video-orientation 轨（会导致方向转两次）") }
        if !sizeMatches {
            m.append(String(format: "画面比例不符：视频 %d×%d / 静帧 %d×%d",
                            Int(displaySize.width), Int(displaySize.height),
                            Int(stillSize.width), Int(stillSize.height)))
        }
        return m
    }

    var ok: Bool { missing.isEmpty }

    var summary: String {
        ok ? "结构完整：HEVC + 实况元数据轨齐全"
           : "缺 \(missing.count) 项：" + missing.joined(separator: "、")
    }

    /// 只读文件尾部的 moov（几百 KB 封顶），不把整个视频读进内存
    static func verify(videoURL: URL, stillSize: CGSize = .zero) -> LiveCheck {
        var r = LiveCheck()
        r.stillSize = stillSize
        if let fh = try? FileHandle(forReadingFrom: videoURL) {
            defer { try? fh.close() }
            let size = (try? fh.seekToEnd()) ?? 0
            let tail = min(Int(size), 512 * 1024)
            if tail > 0 {
                try? fh.seek(toFileOffset: UInt64(Int(size) - tail))
                let d = fh.readData(ofLength: tail)
                let s = String(decoding: [UInt8](d), as: UTF8.self)
                r.hasIdentifier = s.contains("com.apple.quicktime.content.identifier")
                r.hasLivePhotoInfo = s.contains("live-photo-info")
                r.hasStillImageTime = s.contains("still-image-time")
                r.hasBadOrientationTrack = s.contains("video-orientation")
            }
        }
        let asset = AVURLAsset(url: videoURL)
        if let t = asset.tracks(withMediaType: .video).first {
            if let anyFmt = t.formatDescriptions.first {
                let fd = anyFmt as! CMFormatDescription
                let sub = CMFormatDescriptionGetMediaSubType(fd)
                r.isHEVC = (sub == 0x68766331) || (sub == 0x68657631)   // hvc1 / hev1
            }
            // 显示尺寸 = 编码尺寸应用 preferredTransform（竖屏视频编码是横的）
            let n = t.naturalSize
            let disp = n.applying(t.preferredTransform)
            r.displaySize = CGSize(width: abs(disp.width), height: abs(disp.height))
        }
        return r
    }
}
