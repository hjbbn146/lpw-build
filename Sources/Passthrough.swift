import Foundation
import AVFoundation
import CoreMedia

// Objective-C @try/@catch 桥接：Swift 的 do/catch 抓不到 ObjC 异常。
// 真机崩溃栈确认 appendTimedMetadataGroup: 在 iOS 27 抛异常 → SIGABRT。
@_silgen_name("LPWAppendMetadata")
private func lpwAppendMetadata(_ adaptor: AnyObject, _ group: AnyObject) -> Int32
@_silgen_name("LPWLastMetadataError")
private func lpwLastMetadataError() -> UnsafePointer<CChar>?

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
                        keepAudio: Bool,          // 保留参数兼容调用方；本版忽略，强制无音轨
                        metaFormat: CMFormatDescription?,   // v2.7 忽略：不写元数据轨
                        identifier: String,
                        progress: @escaping (String) -> Void) throws -> Result {

        _ = keepAudio
        _ = metaFormat
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

        // ---- 写入器
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else {
            throw MakeError.msg("写入器不接受该视频格式（编码或色彩空间不支持直通）")
        }
        writer.add(vIn)

        // ---- still-image-time 元数据轨（iOS 认实况的必要条件）
        // 格式描述来自 App 内置的真机样本（轨2），与 append 的 item 严格匹配。
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
                Diag.log("警告：写入器不接受元数据轨")
            }
        }

        // ---- 顶层元数据：配对标识必须与静帧 MakerNote 里的 UUID 完全一致
        //
        // content.identifier 是相册把「照片 + 视频」认成一体的核心依据：
        // 照片 MakerNote 里的 UUID 与这里必须完全一致。
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
        Diag.log("阶段: writer 已建好（video=\(writer.inputs.contains { $0.mediaType == .video })"
                 + " audio=关 meta=\(mIn != nil)）")

        guard writer.startWriting() else {
            throw MakeError.msg("启动写入失败：\(writer.error?.localizedDescription ?? "未知")")
        }
        writer.startSession(atSourceTime: .zero)
        Diag.log("阶段: startWriting + startSession 完成")
        guard reader.startReading() else {
            writer.cancelWriting()
            throw MakeError.msg("启动读取失败：\(reader.error?.localizedDescription ?? "未知")")
        }
        Diag.log("阶段: reader 开始读取")

        // ---- 2) 视频轨同步直通（单轨，无交错）
        //
        // v2.3~v2.5 用 requestMediaDataWhenReady 做多轨交错，在 macOS 26 CI 上
        // 能跑 94 帧，但在真机 iOS 27 上却变成「点一下立刻闪退」。
        // v2.2 的纯同步单轨写法真机不闪退（只报过 62 帧业务错误），
        // 所以这一版退回同步模型，并且强制不写音频轨 ——
        // 实况壁纸本来就不播放声音，少一条轨就没有交错 / 锁死的可能。
        progress("直通视频轨…")
        Diag.log("直通开始（同步单轨）· 源 \(fmtSec(total))s → 取 \(fmtSec(use))s · " + Mem.summary())

        // 强制不写音频轨：实况壁纸不播放声音，单轨避免交错死锁
        var frameCount = 0
        var lastBeat = 0
        var lastPct = -1
        var passErr: String?

        while true {
            if writer.status != .writing {
                passErr = "写入器中断（第 \(frameCount) 帧）："
                    + "\(writer.error?.localizedDescription ?? "状态 \(writer.status.rawValue)")"
                break
            }
            // 逐帧 autoreleasepool：不回收会一路涨到被 Jetsam 杀掉
            let sbOpt: CMSampleBuffer? = autoreleasepool { () -> CMSampleBuffer? in
                vOut.copyNextSampleBuffer()
            }
            guard let sb = sbOpt else { break }      // 源读完

            var spin = 0
            while !vIn.isReadyForMoreMediaData {
                if writer.status != .writing { break }
                Thread.sleep(forTimeInterval: 0.002)
                spin += 1
                if spin > 6000 { break }             // 12 秒保护
            }
            if writer.status != .writing {
                passErr = "写入器中断（第 \(frameCount) 帧）："
                    + "\(writer.error?.localizedDescription ?? "状态 \(writer.status.rawValue)")"
                break
            }
            let ok = autoreleasepool { () -> Bool in vIn.append(sb) }
            if !ok {
                passErr = "写入视频样本失败（第 \(frameCount) 帧）："
                    + "\(writer.error?.localizedDescription ?? "未知")"
                break
            }
            frameCount += 1

            if frameCount % 30 == 0 && frameCount != lastBeat {
                lastBeat = frameCount
                let sec = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
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
                    passErr = String(format: "内存占用过高（%.0fMB），已主动停止以免被系统杀掉。", mem)
                    break
                }
            }
        }
        vIn.markAsFinished()

        if let e = passErr {
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
        result.audioSamples = 0
        Diag.log("直通完成 · 视频 \(frameCount) 帧 · 无音轨 · " + Mem.summary())

        // ---- 写 still-image-time（真机崩溃点，用 ObjC @try/@catch 兜住）
        //
        // 真机崩溃栈：-[AVAssetWriterInputMetadataAdaptor appendTimedMetadataGroup:]
        // 抛 ObjC 异常 → SIGABRT。Swift 抓不到，必须用 Objective-C 包一层。
        // append 失败只记日志、不中断——产出可能不被认成实况，但绝不再闪退。
        if let mi = mIn, let ad = adaptor {
            // 关键（真机日志证明）：硬编码 dataType 与格式描述声明的不匹配 →
            // appendTimedMetadataGroup 抛异常。改用样本里真实的 item 做模板，
            // key/keySpace/dataType/languageTag 全部照抄，只保留 value。
            let item = AVMutableMetadataItem()
            if let tpl = MetaFormatProvider.stillImageTimeItemTemplate() {
                item.key = tpl.key
                item.keySpace = tpl.keySpace
                item.dataType = tpl.dataType
                item.extendedLanguageTag = tpl.extendedLanguageTag
                item.value = tpl.value
                Diag.log("item 用样本模板：key=\(tpl.key ?? "nil") dataType=\(tpl.dataType ?? "nil")")
            } else {
                // 兜底：仍用标准写法
                item.keySpace = .quickTimeMetadata
                item.key = "com.apple.quicktime.still-image-time" as NSString
                item.dataType = "com.apple.quicktime.metadata.datatype.int8"
                item.value = NSNumber(value: Int8(-1))
                Diag.log("警告：拿不到样本 item 模板，退回硬编码 dataType")
            }

            // 用真实样本里该 sample 的时间点，避免 0 点或猜的时间
            let cover = CMTime(value: 1, timescale: 30)
            let group = AVTimedMetadataGroup(
                items: [item],
                timeRange: CMTimeRange(start: cover, duration: CMTime(value: 1, timescale: 30)))

            var spin = 0
            while !mi.isReadyForMoreMediaData && spin < 2000 {
                if writer.status != .writing { break }
                Thread.sleep(forTimeInterval: 0.005)
                spin += 1
            }

            let rc = lpwAppendMetadata(ad, group)
            if rc == 1 {
                Diag.log("still-image-time 已写入（guard 成功）")
            } else if rc == -1 {
                let reason = lpwLastMetadataError().map { String(cString: $0) } ?? "(unknown)"
                Diag.log("still-image-time 抛异常（已拦截，不会闪退）：" + reason)
            } else {
                Diag.log("still-image-time 追加返回 false：" +
                         (writer.error?.localizedDescription ?? "无错误描述"))
            }
            mi.markAsFinished()
        }

        // ---- 收尾
        progress("封装收尾…")
        Diag.log("阶段: 开始 finishWriting")
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
