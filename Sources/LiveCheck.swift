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
    /// v4.9：视频轨是否带旋转矩阵。
    /// iOS 实况要求「物理竖屏 + 单位矩阵」；带旋转矩阵的产物系统会按横屏认，
    /// 与竖屏静帧比例不符 → 壁纸必灰。之前这里用 preferredTransform 算显示尺寸，
    /// 把 1080×1920 算成"匹配"，掩盖了真正的问题。
    var hasRotationMatrix = false
    /// v4.8：still-image-time 的 stsd 格式描述与 sample 内容是否自洽。
    /// 之前 probe 只验 sample、漏了 stsd，导致「全 PASS 却不可用」。
    var sitStsdConsistent = false
    var sitStsdNote = ""

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
        if hasStillImageTime && !sitStsdConsistent {
            m.append("still-image-time 格式描述与内容不自洽（\(sitStsdNote)）")
        }
        if hasBadOrientationTrack { m.append("多出 video-orientation 轨（会导致方向转两次）") }
        if hasRotationMatrix {
            m.append("视频带旋转矩阵（Live Photo 要求物理竖屏、单位矩阵；否则系统按横屏算，与竖屏静帧不符）")
        }
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
                // v4.8：moov 在尾部，这里能直接做 SIT 的 stsd↔sample 自洽检查
                if r.hasStillImageTime {
                    let whole = [UInt8](d)
                    let base = Int(size) - tail
                    let c = sitConsistency(whole, baseOffset: base)
                    r.sitStsdConsistent = c.ok
                    r.sitStsdNote = c.note
                }
            }
        }
        let asset = AVURLAsset(url: videoURL)
        if let t = asset.tracks(withMediaType: .video).first {
            if let anyFmt = t.formatDescriptions.first {
                let fd = anyFmt as! CMFormatDescription
                let sub = CMFormatDescriptionGetMediaSubType(fd)
                r.isHEVC = (sub == 0x68766331) || (sub == 0x68657631)   // hvc1 / hev1
            }
            // v4.9：实况要求「物理方向 + 单位矩阵」。
            // 不能用 preferredTransform 算显示尺寸——那会把 1920×1080+90° 算成 1080×1920，
            // 看起来"匹配"，但系统是按 tkhd 实际尺寸判的，于是壁纸永远灰。
            let tf = t.preferredTransform
            let identity = abs(tf.a - 1) < 0.01 && abs(tf.b) < 0.01
                && abs(tf.c) < 0.01 && abs(tf.d - 1) < 0.01
            r.hasRotationMatrix = !identity
            r.displaySize = t.naturalSize     // 单位矩阵时，编码尺寸即显示尺寸
        }
        return r
    }

    /// 在 moov 字节里定位 still-image-time 轨，比对 stsd 声明与 sample 实际 atom 数。
    /// - Parameter baseOffset: 这段字节在文件里的起始偏移（stco 指向文件绝对位置）
    private static func sitConsistency(_ b: [UInt8], baseOffset: Int) -> (ok: Bool, note: String) {
        let tops = BoxKit.boxes(b, 0, b.count)
        guard let moov = tops.first(where: { $0.type == "moov" }) else { return (false, "无 moov") }
        for tk in BoxKit.children(b, moov).filter({ $0.type == "trak" }) {
            guard let stsd = BoxKit.find(b, tk, ["mdia", "minf", "stbl", "stsd"]) else { continue }
            let p = BoxKit.payload(stsd)
            let esz = Int(BoxKit.u32(b, p + 8))
            let lo = p + 8, hi = min(b.count, lo + max(0, esz))
            guard lo < hi else { continue }
            let s = String(decoding: b[lo..<hi], as: UTF8.self)
            guard s.contains("still-image-time") else { continue }

            guard let stsz = BoxKit.find(b, tk, ["mdia", "minf", "stbl", "stsz"]) else { continue }
            let q = BoxKit.payload(stsz)
            let fixed = Int(BoxKit.u32(b, q + 4))
            guard fixed > 0,
                  let stco = BoxKit.find(b, tk, ["mdia", "minf", "stbl", "stco"]) else { continue }
            let r = BoxKit.payload(stco)
            guard Int(BoxKit.u32(b, r + 4)) >= 1 else { continue }
            let absOff = Int(BoxKit.u32(b, r + 8))
            let rel = absOff - baseOffset
            guard rel >= 0, rel + fixed <= b.count else { continue }
            let sample = Array(b[rel..<(rel + fixed)])

            var atoms = 0
            var ptr = 0
            while ptr + 8 <= sample.count {
                let sz = Int(BoxKit.u32(sample, ptr))
                if sz < 8 || ptr + sz > sample.count { break }
                atoms += 1
                ptr += sz
            }
            // 真机基准：stsd 184 字节（2 个 dtyp 块）、sample 89 字节（2 个 atom）
            let ok = (esz == 184 && atoms == 2 && fixed == 89)
            return (ok, "stsd=\(esz)B atom=\(atoms) sample=\(fixed)B")
        }
        return (false, "未找到 SIT 轨")
    }
}
