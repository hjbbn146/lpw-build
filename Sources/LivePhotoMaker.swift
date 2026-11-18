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

// MARK: - 核心

enum LivePhotoMaker {

    /// 视频 → 实况照片素材对。
    ///
    /// 画质零损失的关键在下面两行：
    ///   AVAssetReaderTrackOutput(track:outputSettings: nil)  ← 不解码，拿原始压缩样本
    ///   AVAssetWriterInput(mediaType:outputSettings: nil, sourceFormatHint:) ← 不编码，原样写
    /// 也就是说源视频的 H.264/HEVC 数据包一个字节都不动，只换了个容器，
    /// 补上 iOS 认实况照片所需要的那两条元数据。
    static func make(source: URL,
                     maxSeconds: Double,
                     keepAudio: Bool,
                     progress: @escaping (String) -> Void) throws -> MadeLive {

        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let vTrack = asset.tracks(withMediaType: .video).first else {
            throw MakeError.msg("源文件里没有视频轨")
        }
        guard let anyFmt = vTrack.formatDescriptions.first else {
            throw MakeError.msg("取不到视频格式描述")
        }
        let fmt = anyFmt as! CMFormatDescription
        let sub = CMFormatDescriptionGetMediaSubType(fmt)
        let isH264 = (sub == 0x61766331)                                  // avc1
        let isHEVC = (sub == 0x68766331) || (sub == 0x68657631)           // hvc1 / hev1
        guard isH264 || isHEVC else {
            throw MakeError.msg("编码 \(fourCCString(sub)) 无法零重编码直通，请先转成 H.264 / HEVC")
        }

        let total = CMTimeGetSeconds(asset.duration)
        guard total.isFinite, total > 0.4 else {
            throw MakeError.msg(String(format: "视频太短（%.2f 秒）", total.isFinite ? total : 0))
        }
        let use = (maxSeconds > 0.2 && total > maxSeconds) ? maxSeconds : total

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lpw", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = "\(Int(Date().timeIntervalSince1970))\(Int.random(in: 100...999))"
        let videoURL = dir.appendingPathComponent("live_\(stamp).mov")
        let photoBase = "live_\(stamp)"
        try? FileManager.default.removeItem(at: videoURL)

        let identifier = UUID().uuidString

        // ---- 读取器
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero,
                                       duration: CMTime(seconds: use, preferredTimescale: 600))

        // 注意：outputSettings 传 nil 表示「不解码」，直接拿原始压缩样本
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw MakeError.msg("读取器不接受视频输出") }
        reader.add(vOut)

        var aOut: AVAssetReaderTrackOutput?
        var aFmt: CMFormatDescription?
        if keepAudio, let aTrack = asset.tracks(withMediaType: .audio).first {
            if let af = aTrack.formatDescriptions.first {
                aFmt = (af as! CMFormatDescription)
            }
            let ao = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            ao.alwaysCopiesSampleData = false
            if reader.canAdd(ao) {
                reader.add(ao)
                aOut = ao
            }
        }

        // ---- 写入器
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)

        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else {
            throw MakeError.msg("写入器不接受该视频格式（编码或色彩空间不支持直通）")
        }
        writer.add(vIn)

        var aIn: AVAssetWriterInput?
        if let af = aFmt {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: af)
            ai.expectsMediaDataInRealTime = false
            if writer.canAdd(ai) {
                writer.add(ai)
                aIn = ai
            }
        }

        // ---- still-image-time 元数据轨（iOS 靠它认定这是实况照片）
        guard let mf = makeStillImageTimeFormat() else {
            throw MakeError.msg("拿不到 still-image-time 元数据格式。\n"
                                + "需要相册「完全访问」权限，并且相册里至少有一张实况照片作样本"
                                + "（相机默认就是实况，随便拍一张即可）。\n"
                                + "路径：设置 → 隐私与安全性 → 照片 → 无损实况 → 完全访问")
        }

        let mIn = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: mf)
        mIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(mIn) else { throw MakeError.msg("写入器不接受元数据轨") }
        writer.add(mIn)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: mIn)

        // ---- 顶层元数据：配对标识必须与静帧 MakerNote 里的 UUID 完全一致
        let idItem = AVMutableMetadataItem()
        idItem.keySpace = .quickTimeMetadata
        idItem.key = "com.apple.quicktime.content.identifier" as NSString
        idItem.value = identifier as NSString

        let dateItem = AVMutableMetadataItem()
        dateItem.keySpace = .quickTimeMetadata
        dateItem.key = "com.apple.quicktime.creationdate" as NSString
        dateItem.value = isoNow() as NSString

        writer.metadata = [idItem, dateItem]

        // ---- 开跑
        guard writer.startWriting() else {
            throw MakeError.msg("启动写入失败：\(writer.error?.localizedDescription ?? "未知")")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw MakeError.msg("启动读取失败：\(reader.error?.localizedDescription ?? "未知")")
        }

        // ---- 视频样本直通
        progress("直通视频轨…")
        var frameCount = 0
        while let sb = vOut.copyNextSampleBuffer() {
            if writer.status == .failed { break }
            var stall = 0
            while !vIn.isReadyForMoreMediaData {
                if writer.status == .failed { break }
                Thread.sleep(forTimeInterval: 0.002)
                stall += 1
                if stall > 6000 { break }       // 约 12 秒保护
            }
            if writer.status == .failed { break }
            if !vIn.append(sb) { break }
            frameCount += 1
            if frameCount % 90 == 0 {
                progress("直通中… 已写入 \(frameCount) 帧")
            }
        }
        vIn.markAsFinished()

        if frameCount == 0 {
            reader.cancelReading()
            writer.cancelWriting()
            throw MakeError.msg("没有读到任何视频样本（源文件可能损坏）")
        }

        // ---- 音频样本直通
        if let aIn = aIn, let aOut = aOut {
            while let sb = aOut.copyNextSampleBuffer() {
                if writer.status == .failed { break }
                var stall = 0
                while !aIn.isReadyForMoreMediaData {
                    if writer.status == .failed { break }
                    Thread.sleep(forTimeInterval: 0.002)
                    stall += 1
                    if stall > 6000 { break }
                }
                if writer.status == .failed { break }
                if !aIn.append(sb) { break }
            }
            aIn.markAsFinished()
        }

        // ---- 写 still-image-time（真机样本值就是 int8 的 -1）
        let coverTime = CMTime(value: 1, timescale: 30)
        let metaItem = AVMutableMetadataItem()
        metaItem.keySpace = .quickTimeMetadata
        metaItem.key = "com.apple.quicktime.still-image-time" as NSString
        metaItem.value = NSNumber(value: Int8(-1))
        metaItem.dataType = "com.apple.quicktime.metadata.datatype.int8"

        let group = AVTimedMetadataGroup(items: [metaItem],
                                        timeRange: CMTimeRange(
                                            start: coverTime,
                                            duration: CMTime(value: 1, timescale: 600)))
        if !adaptor.append(group) {
            Diag.log("警告：still-image-time 追加失败")
        }
        mIn.markAsFinished()

        // ---- 收尾
        progress("封装收尾…")
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        if sem.wait(timeout: .now() + 180) == .timedOut {
            writer.cancelWriting()
            throw MakeError.msg("写入超时（视频可能过大）")
        }
        guard writer.status == .completed else {
            throw MakeError.msg("收尾失败：\(writer.error?.localizedDescription ?? "未知")")
        }

        // ---- 静帧
        progress("提取静帧…")
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = .zero
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)

        let cg: CGImage
        do {
            cg = try gen.copyCGImage(at: coverTime, actualTime: nil)
        } catch {
            throw MakeError.msg("取帧失败：\(error.localizedDescription)")
        }

        let photoURL = try StillWriter.write(cgImage: cg,
                                             to: dir,
                                             baseName: photoBase,
                                             identifier: identifier,
                                             dateString: exifDateString())

        let info = MediaInspector.inspect(source) ?? VideoInfo()
        Diag.log("生成完成：\(info.width)×\(info.height) \(info.codec) \(frameCount) 帧，标识 \(identifier)")
        return MadeLive(videoURL: videoURL, photoURL: photoURL, identifier: identifier, info: info)
    }

    // MARK: - 元数据格式描述
    // 具体实现在 MetaFormatProvider：主路径是从相册现成实况照片里取格式描述，
    // 因为 CMMetadataFormatDescriptionCreateWithMetadataSpecifications 在
    // iOS 26 / macOS 26 上对 still-image-time 一律回 -12710（已实测六种组合全灭）。
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

    static func isoNow() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return f.string(from: Date())
    }
}
