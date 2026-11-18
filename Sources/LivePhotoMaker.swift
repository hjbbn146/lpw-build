import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics

// MARK: - 探测

enum MediaInspector {

    static func inspect(_ url: URL) -> VideoInfo? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let t = asset.tracks(withMediaType: .video).first else { return nil }

        var info = VideoInfo()
        let sz = t.naturalSize.applying(t.preferredTransform)
        info.width = Int(abs(sz.width).rounded())
        info.height = Int(abs(sz.height).rounded())
        info.duration = CMTimeGetSeconds(asset.duration)
        info.fps = Double(t.nominalFrameRate)
        info.bitRate = Double(t.estimatedDataRate)
        info.hasAudio = !asset.tracks(withMediaType: .audio).isEmpty

        if let anyFmt = t.formatDescriptions.first {
            let fd = anyFmt as! CMFormatDescription
            info.codec = fourCCString(CMFormatDescriptionGetMediaSubType(fd))
            if let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] {
                if let bpc = ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int {
                    info.bitDepth = bpc
                }
                let tfKey = kCMFormatDescriptionExtension_TransferFunction as String
                if let tf = ext[tfKey] as? String {
                    info.isHDR = (tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String))
                        || (tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String))
                }
            }
        }
        return info
    }

    static func bitrateText(_ bps: Double) -> String {
        if bps <= 0 { return "—" }
        return String(format: "%.1f Mbps", bps / 1_000_000.0)
    }

    static func durationText(_ s: Double) -> String {
        if !s.isFinite { return "—" }
        let m = Int(s) / 60
        let sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
}

// MARK: - 整体流程

/// 视频 → 实况照片素材对（一个 .mov + 一张带 MakerNote 的静帧）。
///
/// 实际的重活都在 Passthrough（零重编码直通）和 StillWriter（静帧 EXIF）里，
/// 这里只负责把它们串起来并抽出封面帧。
enum LivePhotoMaker {

    static func make(source: URL,
                     maxSeconds: Double,
                     keepAudio: Bool,
                     progress: @escaping (String) -> Void) throws -> MadeLive {

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lpw", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = "\(Int(Date().timeIntervalSince1970))\(Int.random(in: 100...999))"
        let videoURL = dir.appendingPathComponent("live_\(stamp).mov")
        let photoBase = "live_\(stamp)"
        let identifier = UUID().uuidString

        // v3.0：不再从相册里找 still-image-time 的格式描述。
        // 那条路在 iOS 26/27 上走不通（-12710 + append 抛 ObjC 异常），
        // 现在改成把内置真机样本的三条元数据轨整条 box 级搬过来。
        guard let sampleURL = Bundle.main.url(forResource: "sample_live", withExtension: "mov") else {
            throw MakeError.msg("App 内置的实况样本丢失（sample_live.mov），请重装应用")
        }

        // ---- 零重编码直通 + 元数据轨移植
        //
        // 带音轨失败时自动降级成纯视频再试一次：实况照片没有声音也照样能用，
        // 总比整个流程失败好。真机上音频轨是最容易把 writer 卡住的变量。
        let res: Passthrough.Result
        do {
            res = try Passthrough.convert(source: source,
                                          outputURL: videoURL,
                                          maxSeconds: maxSeconds,
                                          keepAudio: keepAudio,
                                          metaFormat: nil,
                                          identifier: identifier,
                                          sampleURL: sampleURL,
                                          progress: progress)
        } catch {
            guard keepAudio else { throw error }
            Diag.log("带音轨直通失败：" + error.localizedDescription)
            Diag.log("自动降级为纯视频重试")
            progress("改为纯视频重试…")
            try? FileManager.default.removeItem(at: videoURL)
            res = try Passthrough.convert(source: source,
                                          outputURL: videoURL,
                                          maxSeconds: maxSeconds,
                                          keepAudio: false,
                                          metaFormat: nil,
                                          identifier: identifier,
                                          sampleURL: sampleURL,
                                          progress: progress)
        }

        // ---- 静帧
        //
        // 关键：静帧画面必须取 still-image-time 指向的同一时刻。
        // 真机实况的封面图就是那条轨指到的那一帧；两者不一致时，
        // 锁屏静态画面和长按播放的第一帧会跳变，壁纸引擎也更容易判成不可用。
        progress("提取静帧…")
        let coverTime: CMTime
        if res.stillSeconds > 0.03 {
            coverTime = CMTime(seconds: res.stillSeconds, preferredTimescale: 600)
            Diag.log(String(format: "静帧取 %.3fs（与 still-image-time 对齐）", res.stillSeconds))
        } else {
            coverTime = CMTime(value: 1, timescale: 30)
            Diag.log("静帧取 0.033s（移植未给出静帧时刻，退回默认）")
        }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: source,
                                                          options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = .zero
        // 精确取帧：容差留大会取到相邻帧，画面就和 still-image-time 对不上了
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero

        var cg: CGImage?
        autoreleasepool {
            cg = try? gen.copyCGImage(at: coverTime, actualTime: nil)
        }
        // 关键帧不落在 1/30 秒附近时第一次可能取不到；放宽容差再试一次
        if cg == nil {
            gen.requestedTimeToleranceBefore = .positiveInfinity
            gen.requestedTimeToleranceAfter = .positiveInfinity
            autoreleasepool {
                cg = try? gen.copyCGImage(at: coverTime, actualTime: nil)
            }
        }
        guard let cg = cg else {
            throw MakeError.msg("取帧失败：无法解码视频画面（可能是 HEVC 10bit/HDR 素材）")
        }
        Diag.log("静帧已解码：\(cg.width)×\(cg.height) bpc=\(cg.bitsPerComponent) " + Mem.summary())

        let photoURL = try StillWriter.write(cgImage: cg,
                                            to: dir,
                                            baseName: photoBase,
                                            identifier: identifier,
                                            dateString: exifDateString())

        let info = MediaInspector.inspect(source) ?? VideoInfo()
        Diag.log("生成完成：\(info.width)×\(info.height) \(info.codec) \(res.frames) 帧，标识 \(identifier)")
        return MadeLive(videoURL: videoURL, photoURL: photoURL, identifier: identifier, info: info)
    }

    // MARK: - 元数据格式描述

    static func makeStillImageTimeFormat() -> CMFormatDescription? {
        MetaFormatProvider.stillImageTime()
    }

    // MARK: - 时间格式

    static func exifDateString() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.string(from: Date())
    }
}
