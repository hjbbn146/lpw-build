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
        // 照片 EXIF 时间与视频 creationdate 必须来自同一个时刻：
        // 直通 + 取帧可能要跑几十秒，分两次取时间会差出好几分钟，
        // iOS 侧配对实况照片时会因为「前后差了这么久」而不认。
        let stampDate = Date()

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
                                          date: stampDate,
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
                                          date: stampDate,
                                          progress: progress)
        }

        // ---- 静帧：从「产物视频」取，不从源视频取
        //
        // ★ 这是「手动换封面就能用」的根治点：
        // 静帧必须和 still-image-time 轨指向的那一帧在同一条时间轴上。
        // 从源视频取帧时，源与产物的 PTS 起点／transform 可能有微小错位，
        // 系统验证就会发现「封面图和指定时刻的帧对不上」→ 壁纸按钮变灰。
        // 从产物取则天然对齐：same file, same timeline。
        progress("提取静帧…")
        let defaultCover = res.stillSeconds > 0.03 ? res.stillSeconds : 0.5
        guard let cg0 = LivePhotoMaker.stillFrame(from: videoURL, at: defaultCover) else {
            throw MakeError.msg("取帧失败：无法解码视频画面（可能是 HEVC 10bit/HDR 素材）")
        }
        Diag.log("静帧已解码：\(cg0.width)×\(cg0.height) bpc=\(cg0.bitsPerComponent) " + Mem.summary())
        let photoURL = try StillWriter.write(cgImage: cg0,
                                            to: dir,
                                            baseName: photoBase,
                                            identifier: identifier,
                                            dateString: exifDateString(stampDate))
        let info = MediaInspector.inspect(source) ?? VideoInfo()

        // ---- 系统验证 + 封面自动搜索
        //
        // 静态轨结构上一版已经全部对齐真机，但仍设不了壁纸 —— 差的唯一一环是
        // 「让系统自己判定」。Apple 官方 PHLivePhoto.request(withResourceFileURLs:)
        // 会加载并验证这对文件，失败返回 NSError。这里先验证默认封面；
        // 若系统不认，就遍历若干候选时刻，逐个重移植 + 重取静帧 + 重验，
        // 取第一个被系统认可的封面。全程后台自动完成，失败也不阻断导出。
        var verified = false
        var note = ""
        var finalCover = defaultCover
        progress("系统验证封面…")
        let v0 = LiveValidator.validate(photoURL: photoURL, videoURL: videoURL)
        Diag.log(String(format: "系统验证·默认封面 %.3fs：%@（%.1fs）",
                        defaultCover, v0.accepted ? "通过" : "未通过 · \(v0.errorText)", v0.elapsed))
        if v0.accepted {
            verified = true
            note = "系统验证通过"
        } else {
            // 默认封面没过：重新直通一份干净产物，逐个候选封面重移植验证。
            // （不能在已移植的产物上二次 port，否则轨会重复叠加。）
            note = "默认封面未通过：\(v0.errorText)"
            let cleanURL = dir.appendingPathComponent("clean_\(stamp).mov")
            var usedClean = false
            var chosenVideo = videoURL
            var chosenPhoto = photoURL

            var ci = 0
            for cand in LivePhotoMaker.coverCandidates(preferred: defaultCover, duration: res.usedSeconds) {
                // 默认封面刚试过，跳过与它几乎相同的候选
                if abs(cand - defaultCover) < 0.08 { continue }
                if !usedClean {
                    progress("封面搜索：准备干净副本…")
                    do {
                        _ = try Passthrough.convert(source: source, outputURL: cleanURL,
                                                maxSeconds: maxSeconds, keepAudio: keepAudio,
                                                metaFormat: nil, identifier: identifier,
                                                sampleURL: nil, date: stampDate,
                                                progress: { _ in })
                        usedClean = true
                    } catch {
                        Diag.log("封面搜索：重新直通失败 \(error.localizedDescription)")
                        break
                    }
                }
                ci += 1
                progress("封面搜索 \(ci)：\(String(format: "%.2f", cand))s…")
                let cVideo = dir.appendingPathComponent("cand_\(stamp)_\(ci).mov")
                let cPhotoBase = "\(photoBase)_c\(ci)"
                do {
                    try? FileManager.default.removeItem(at: cVideo)
                    try FileManager.default.copyItem(at: cleanURL, to: cVideo)
                    let rep = try MetaTrakPorter.port(videoURL: cVideo,
                                                      sampleURL: sampleURL,
                                                      stillSecondsOverride: cand)
                    guard let cg = LivePhotoMaker.stillFrame(from: cVideo, at: rep.stillSeconds) else {
                        Diag.log("封面搜索 \(ci)：取帧失败，跳过")
                        continue
                    }
                    let cPhoto = try StillWriter.write(cgImage: cg, to: dir,
                                                       baseName: cPhotoBase, identifier: identifier,
                                                       dateString: exifDateString(stampDate))
                    let vv = LiveValidator.validate(photoURL: cPhoto, videoURL: cVideo)
                    Diag.log(String(format: "封面搜索 \(ci)·%.3fs：%@（%.1fs）",
                                    rep.stillSeconds, vv.accepted ? "通过" : vv.errorText, vv.elapsed))
                    if vv.accepted {
                        verified = true
                        chosenVideo = cVideo
                        chosenPhoto = cPhoto
                        finalCover = rep.stillSeconds
                        note = String(format: "封面自动搜索通过（%.2fs）", rep.stillSeconds)
                        break
                    } else {
                        note = vv.errorText
                    }
                } catch {
                    Diag.log("封面搜索 \(ci) 失败：\(error.localizedDescription)")
                }
            }
            // 把选中的候选覆盖成最终产物路径（沿用调用方期待的文件名）
            if chosenVideo != videoURL {
                try? FileManager.default.removeItem(at: videoURL)
                try? FileManager.default.copyItem(at: chosenVideo, to: videoURL)
                try? FileManager.default.removeItem(at: photoURL)
                try? FileManager.default.copyItem(at: chosenPhoto, to: photoURL)
            }
            // 搜索阶段的所有临时文件清掉，只留最终产物
            LivePhotoMaker.cleanup(except: [videoURL, photoURL], in: dir, stamp: stamp)
            // 用最终产物再确认一次，保证复制过程没破坏文件
            if verified {
                let vf = LiveValidator.validate(photoURL: photoURL, videoURL: videoURL)
                verified = vf.accepted
                if !vf.accepted { note = "复验未通过：\(vf.errorText)" }
            }
        }

        Diag.log("生成完成：\(info.width)×\(info.height) \(info.codec) \(res.frames) 帧，标识 \(identifier)"
                 + " · 封面 \(String(format: "%.3f", finalCover))s · 系统验证\(verified ? "通过" : "未过")")
        return MadeLive(videoURL: videoURL, photoURL: photoURL, identifier: identifier,
                        info: info, verifiedLive: verified, verifyNote: note,
                        coverSeconds: finalCover)
    }

    /// 从产物视频的指定时刻取一帧（显示方向）。先零容差精确取，取不到再放宽容差。
    private static func stillFrame(from videoURL: URL, at seconds: Double) -> CGImage? {
        let t = seconds > 0.03 ? CMTime(seconds: seconds, preferredTimescale: 600)
                               : CMTime(value: 1, timescale: 30)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = .zero
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        var cg: CGImage?
        autoreleasepool { cg = try? gen.copyCGImage(at: t, actualTime: nil) }
        if cg == nil {
            gen.requestedTimeToleranceBefore = .positiveInfinity
            gen.requestedTimeToleranceAfter = .positiveInfinity
            autoreleasepool { cg = try? gen.copyCGImage(at: t, actualTime: nil) }
        }
        return cg
    }

    /// 封面候选时刻（秒）：默认封面之外，覆盖靠前、正中、略靠后的合法帧。
    /// 系统「换封面就能用」的经验区间集中在前半秒到 1.5 秒。
    private static func coverCandidates(preferred: Double, duration: Double) -> [Double] {
        let upper = max(0.2, duration - 0.1)
        let raw = [0.5, 0.25, 0.75, 1.0, 0.15, 1.5, 0.35, 1.2, 0.6]
        var out: [Double] = []
        for v in raw where v <= upper {
            if !out.contains(where: { abs($0 - v) < 0.06 }) { out.append(v) }
        }
        return out
    }

    /// 清掉封面搜索中间文件，只保留最终产物。
    private static func cleanup(except keep: [URL], in dir: URL, stamp: String) {
        let keepPaths = Set(keep.map { $0.lastPathComponent })
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for n in names where n.contains(stamp) && !keepPaths.contains(n) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
        }
    }

    // MARK: - 元数据格式描述

    static func makeStillImageTimeFormat() -> CMFormatDescription? {
        MetaFormatProvider.stillImageTime()
    }

    // MARK: - 时间格式

    static func exifDateString(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.string(from: date)
    }
}
