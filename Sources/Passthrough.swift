import Foundation
import AVFoundation
import CoreMedia

/// 视频轨 / 音频轨的零重编码直通。
///
/// 从 LivePhotoMaker 里抽出来单独一个类型，原因是它既能被 App 调用，
/// 也能在 macOS CI 里被单独跑一遍（不碰 Photos / UIKit）——
/// 这样「直通到底能不能跑完」这件事不用每次都靠真机试。
///
/// 画质不动的关键就两行：
///   AVAssetReaderTrackOutput(track:outputSettings: nil)          不解码
///   AVAssetWriterInput(.video, outputSettings: nil, hint:)       不编码
/// 源文件压缩数据一个字节都不改，只换容器并补元数据。
enum Passthrough {

    struct Result {
        var frames = 0
        var audioSamples = 0
        var identifier = ""
        var usedSeconds: Double = 0
        var sourceSeconds: Double = 0
    }

    /// - Parameter metaFormat: still-image-time 轨的格式描述。
    ///   传 nil 则跳过该轨（CI 测试用；App 里必须传，否则相册不认实况）。
    static func convert(source: URL,
                        outputURL: URL,
                        maxSeconds: Double,
                        keepAudio: Bool,
                        metaFormat: CMFormatDescription?,
                        identifier: String,
                        progress: @escaping (String) -> Void) throws -> Result {

        var result = Result()
        result.identifier = identifier

        let asset = AVURLAsset(url: source,
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
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
        var use = (maxSeconds > 0.2 && total > maxSeconds) ? maxSeconds : total
        // 保险丝：实况照片在 iOS 上只会播 3 秒左右，直通超长视频既没意义，
        // 又容易把内存和磁盘一起撑爆
        if use > 15.0 {
            Diag.log(String(format: "时长 %.2fs 超过 15 秒，自动只取前 15 秒", use))
            use = 15.0
        }
        result.usedSeconds = use
        result.sourceSeconds = total

        // ---- 磁盘预检：直通不压缩，输出体积 ≈ 码率 × 时长
        let estMB = Double(vTrack.estimatedDataRate) * use / 8.0 / 1_048_576.0
        let freeMB = Mem.freeDiskMB()
        Diag.log(String(format: "预检 · 预估输出 %.1fMB · 磁盘剩余 %.0fMB · 内存 %.0fMB",
                        estMB, freeMB, Mem.footprintMB()))
        if freeMB > 0 && estMB > 0 && freeMB < estMB * 2 + 80 {
            throw MakeError.msg(String(format: "磁盘空间不够：这段视频直通后约 %.0fMB，当前只剩 %.0fMB",
                                       estMB, freeMB))
        }

        try? FileManager.default.removeItem(at: outputURL)

        // ---- 读取器
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero,
                                       duration: CMTime(seconds: use, preferredTimescale: 600))

        // 必须拷贝：设为 false 时 sample buffer 直接引用读取器内部缓冲，
        // 读取器一前进就会复用这块内存，而写入器是异步消费的，
        // 结果是偶发读到被覆盖的数据 → 无规律闪退。
        // 拷贝只多一次 memcpy，压缩数据本身一个字节都没变，画质完全无损。
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        vOut.alwaysCopiesSampleData = true
        guard reader.canAdd(vOut) else { throw MakeError.msg("读取器不接受视频输出") }
        reader.add(vOut)

        var aOut: AVAssetReaderTrackOutput?
        var aFmt: CMFormatDescription?
        if keepAudio, let aTrack = asset.tracks(withMediaType: .audio).first {
            if let af = aTrack.formatDescriptions.first {
                aFmt = (af as! CMFormatDescription)
            }
            let ao = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            ao.alwaysCopiesSampleData = true
            if reader.canAdd(ao) {
                reader.add(ao)
                aOut = ao
            }
        }

        // ---- 写入器
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

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

        // ---- 元数据轨：iOS 靠 still-image-time 认定这是实况照片
        var mIn: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputMetadataAdaptor?
        if let mf = metaFormat {
            let mi = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: mf)
            mi.expectsMediaDataInRealTime = false
            if writer.canAdd(mi) {
                writer.add(mi)
                mIn = mi
                adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: mi)
            } else {
                Diag.log("警告：写入器不接受元数据轨，产物可能不被识别为实况")
            }
        }

        // ---- 顶层元数据：配对标识必须与静帧 MakerNote 里的 UUID 完全一致
        //
        // content.identifier 是相册把「照片 + 视频」认成一体的依据之一，
        // 和 still-image-time 缺一不可。
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

        // ---- 1) 先把 still-image-time 写掉
        //
        // 只有一个样本、时间点最早，所以放在最前面写完立刻结束这条轨。
        // 排在视频/音频之后是死锁的成因之一：writer 发现元数据轨一直空着，
        // 会把视频 input 压住等它补齐。
        if let mi = mIn, let ad = adaptor {
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = "com.apple.quicktime.still-image-time" as NSString
            item.value = NSNumber(value: Int8(-1))
            item.dataType = "com.apple.quicktime.metadata.datatype.int8"

            let grp = AVTimedMetadataGroup(
                items: [item],
                timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 30)))

            var waited = 0
            while !mi.isReadyForMoreMediaData && waited < 2000 {
                if writer.status != .writing { break }
                Thread.sleep(forTimeInterval: 0.005)
                waited += 1
            }
            if ad.append(grp) {
                Diag.log("still-image-time 已写入（int8 -1，起点 0s）")
            } else {
                Diag.log("警告：still-image-time 追加失败："
                         + "\(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")")
            }
            mi.markAsFinished()
        }

        // ---- 2) 视频 / 音频交错直通
        //
        // AVAssetWriter 对多轨有「交错窗口」：如果让视频轨一路跑到底、音频轨
        // 再从头开始，视频领先约 2 秒后 writer 就会把 video input 的
        // isReadyForMoreMediaData 置为 false，等后进者追上来；而后进者要等
        // 视频循环结束才动 —— 双方永远等不到，停在某个帧数再也不动。
        // （真机上停在第 62 帧，30fps 下正好 ≈2 秒，非常典型。）
        //
        // 正确做法：不自己排顺序，交给 writer 用 requestMediaDataWhenReady
        // 按需向每条轨要数据，交错自然成立，也不需要任何忙等。
        progress("直通视频轨…")
        Diag.log("直通开始 · 源 \(fmtSec(total))s → 取 \(fmtSec(use))s · 音频"
                 + "\(aIn == nil ? "关" : "开") · " + Mem.summary())

        let vQueue = DispatchQueue(label: "lpw.pass.video")
        let aQueue = DispatchQueue(label: "lpw.pass.audio")
        let grp = DispatchGroup()

        var vDone = false
        var aDone = (aIn == nil || aOut == nil)
        var vErr: String?
        var aErr: String?
        var frameCount = 0
        var audioCount = 0
        var lastBeat = 0
        var lastPct = -1

        grp.enter()                        // 视频轨
        if !aDone { grp.enter() }          // 音频轨

        vIn.requestMediaDataWhenReady(on: vQueue) {
            while vIn.isReadyForMoreMediaData {
                // 每帧一个自动释放池：AVFoundation 每帧都会产生一批临时对象，
                // 不逐帧回收会一路涨到被系统的 Jetsam 直接杀掉
                let finished = autoreleasepool { () -> Bool in
                    if writer.status != .writing {
                        vErr = "写入器中断（第 \(frameCount) 帧）："
                            + "\(writer.error?.localizedDescription ?? "状态 \(writer.status.rawValue)")"
                        return true
                    }
                    guard let sb = vOut.copyNextSampleBuffer() else {
                        return true                       // 源视频读完
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                    if !vIn.append(sb) {
                        vErr = "写入视频样本失败（第 \(frameCount) 帧）："
                            + "\(writer.error?.localizedDescription ?? "未知")"
                        return true
                    }
                    frameCount += 1

                    if frameCount % 30 == 0 && frameCount != lastBeat {
                        lastBeat = frameCount
                        let sec = CMTimeGetSeconds(pts)
                        let pct = use > 0 && sec.isFinite ? Int(min(99, max(0, sec / use * 100))) : 0
                        let mem = Mem.footprintMB()
                        let secText = String(format: "%.1f", sec.isFinite ? sec : 0)
                        Diag.log("直通 \(frameCount) 帧 · \(secText)s/\(Int(use.rounded()))s"
                                 + " · \(pct)% · 内存 \(Int(mem))MB")
                        if pct != lastPct {
                            lastPct = pct
                            progress("直通视频轨… \(pct)%（\(frameCount) 帧 · \(Int(mem))MB）")
                        }
                        if mem > 0 && mem > Mem.deviceMB * 0.55 {
                            vErr = String(format: "内存占用过高（%.0fMB），已主动停止以免被系统杀掉。"
                                          + "建议把时长改成 3 秒，或先把视频裁短", mem)
                            return true
                        }
                    }
                    return false
                }

                if finished {
                    if !vDone {
                        vDone = true
                        vIn.markAsFinished()
                        grp.leave()
                    }
                    return
                }
            }
        }

        if let ai = aIn, let ao = aOut {
            ai.requestMediaDataWhenReady(on: aQueue) {
                while ai.isReadyForMoreMediaData {
                    let finished = autoreleasepool { () -> Bool in
                        if writer.status != .writing { return true }
                        guard let sb = ao.copyNextSampleBuffer() else { return true }
                        if !ai.append(sb) {
                            aErr = "写入音频样本失败："
                                + "\(writer.error?.localizedDescription ?? "未知")"
                            return true
                        }
                        audioCount += 1
                        return false
                    }
                    if finished {
                        if !aDone {
                            aDone = true
                            ai.markAsFinished()
                            grp.leave()
                        }
                        return
                    }
                }
            }
        }

        if grp.wait(timeout: .now() + 180) == .timedOut {
            reader.cancelReading()
            writer.cancelWriting()
            throw MakeError.msg("直通超时 180 秒（已写入 \(frameCount) 帧），"
                                + "写入器长时间不接受数据。请把日志发我")
        }
        if let e = vErr {
            reader.cancelReading()
            writer.cancelWriting()
            Diag.log("直通失败：" + e)
            throw MakeError.msg(e)
        }
        if let e = aErr {
            reader.cancelReading()
            writer.cancelWriting()
            Diag.log("直通失败：" + e)
            throw MakeError.msg(e)
        }
        if frameCount == 0 {
            reader.cancelReading()
            writer.cancelWriting()
            throw MakeError.msg("没有读到任何视频样本（源文件可能损坏）")
        }

        result.frames = frameCount
        result.audioSamples = audioCount
        Diag.log("直通完成 · 视频 \(frameCount) 帧 · 音频 \(audioCount) 个样本 · " + Mem.summary())

        // ---- 收尾
        progress("封装收尾…")
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        if sem.wait(timeout: .now() + 90) == .timedOut {
            writer.cancelWriting()
            throw MakeError.msg("封装超时 90 秒（视频过大或磁盘写入过慢）")
        }
        guard writer.status == .completed else {
            throw MakeError.msg("收尾失败：\(writer.error?.localizedDescription ?? "状态 \(writer.status.rawValue)")")
        }
        Diag.log("封装完成 · 产物 \(fmtMB(fileBytes(outputURL)))MB · " + Mem.summary())
        return result
    }

    // MARK: - 小工具

    static func fmtSec(_ s: Double) -> String {
        s.isFinite ? String(format: "%.2f", s) : "—"
    }

    static func isoNow() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return f.string(from: Date())
    }

    static func fileBytes(_ url: URL) -> Double {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (a?[.size] as? NSNumber)?.doubleValue ?? 0
    }

    static func fmtMB(_ b: Double) -> String {
        String(format: "%.1f", b / 1_048_576.0)
    }
}
