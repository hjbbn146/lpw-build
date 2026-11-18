import Foundation
import AVFoundation

/// 产物「能不能当锁屏实况壁纸」的结构自检。
///
/// 系统相册把 photo + pairedVideo 塞进同一资产后，PHAsset.mediaSubtypes 里
/// 一定会有 .photoLive —— 所以那个标志说明不了任何问题（v2.x 的坑就在这）。
/// 壁纸引擎看的是 MOV 本身的轨结构：必须是 HEVC，且四条轨齐全。
///
/// 这里直接扫 moov 里的 key 字符串，比问 AVFoundation 更接近壁纸引擎的判据。
struct LiveCheck {

    var isHEVC = false
    var hasIdentifier = false
    var hasLivePhotoInfo = false
    var hasStillImageTime = false
    var hasOrientation = false

    var missing: [String] {
        var m: [String] = []
        if !isHEVC { m.append("视频不是 HEVC") }
        if !hasIdentifier { m.append("缺 content.identifier") }
        if !hasLivePhotoInfo { m.append("缺 live-photo-info 轨") }
        if !hasStillImageTime { m.append("缺 still-image-time 轨") }
        if !hasOrientation { m.append("缺 video-orientation 轨") }
        return m
    }

    var ok: Bool { missing.isEmpty }

    var summary: String {
        ok ? "结构完整：HEVC + 4 轨齐全"
           : "缺 \(missing.count) 项：" + missing.joined(separator: "、")
    }

    /// 只读文件尾部的 moov（几百 KB 封顶），不把整个视频读进内存
    static func verify(videoURL: URL) -> LiveCheck {
        var r = LiveCheck()
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
                r.hasOrientation = s.contains("video-orientation")
            }
        }
        let asset = AVURLAsset(url: videoURL)
        if let t = asset.tracks(withMediaType: .video).first,
           let anyFmt = t.formatDescriptions.first {
            let fd = anyFmt as! CMFormatDescription
            let sub = CMFormatDescriptionGetMediaSubType(fd)
            r.isHEVC = (sub == 0x68766331) || (sub == 0x68657631)   // hvc1 / hev1
        }
        return r
    }
}
