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
        var metaTracks: [String] = []
        /// still-image-time 指向的时刻；静帧画面要用同一个时刻
        var stillSeconds: Double = 0
    }

    /// - Parameter metaFormat: 保留参数兼容旧调用方，本版不再使用。
    /// - Parameter sampleURL: 真机原生实况样本。收尾后靠它把 3 条元数据轨
    ///   box 级移植进产物；传 nil 则只出纯视频（CI 单测用）。
    static func convert(source: URL,
                        outputURL: URL,
                        maxSeconds: Double,
                        keepAudio: Bool,          // 保留参数兼容调用方；本版忽略，强制无音轨
                        metaFormat: CMFormatDescription?,   // v3.0 忽略：元数据轨改走 box 移植
                        identifier: String,
                        sampleURL: URL? = nil,
                        date: Date = Date(),
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
        // 硬性保险丝：iOS 实况照片的时长上限就是 3 秒，超过一律不被接受。
        // 无论调用方传什么（早先 UI 里有个「保留全长」选项会传 0），这里都必须夹到 2.95 以内。
        if use > 2.95 {
            Diag.log(String(format: "时长 %.2fs 超过实况上限，自动截到 2.9s", use))
            use = 2.9
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
        // 关键：把源视频的旋转矩阵写进 tkhd。
        // 不设这一行，AVAssetWriter 会写成单位矩阵 —— 手机竖屏拍的视频
        // 编码尺寸是 1920×1080 + 90° 旋转，矩阵一丢就变横屏，
        // 生成的实况壁纸竖屏变横屏，壁纸引擎也会因为宽高比对不上而判成不可用。
        vIn.transform = vTrack.preferredTransform
        let tf = vTrack.preferredTransform
        let disp = vTrack.naturalSize.applying(tf)
        Diag.log(String(format: "源视频 transform=[%.2f %.2f %.2f %.2f %.1f %.1f] 编码 %.0f×%.0f 显示 %.0f×%.0f",
                        Double(tf.a), Double(tf.b), Double(tf.c), Double(tf.d), Double(tf.tx), Double(tf.ty),
                        Double(vTrack.naturalSize.width), Double(vTrack.naturalSize.height),
                        Double(abs(disp.width)), Double(abs(disp.height))))
        guard writer.canAdd(vIn) else {
            throw MakeError.msg("写入器不接受该视频格式（编码或色彩空间不支持直通）")
        }
        writer.add(vIn)

        // ---- 元数据轨为什么不在这里写
        //
        // iOS 26/27 上 CMMetadataFormatDescriptionCreateWithMetadataSpecifications
        // 对所有 spec 组合恒定返回 -12710，没法凭空造 still-image-time 的格式描述；
        // 而 appendTimedMetadataGroup: 在真机上会直接抛 ObjC 异常（崩溃栈已确认）。
        // v2.x 用 @try/@catch 兜住不崩了，但那条轨始终没真正写进文件 ——
        // 真机导出的 MOV 只有一条 vide 轨，所以相册里「实况」按钮一直是灰的。
        //
        // v3.0 改成封装收尾后做 box 级移植（MetaTrakPorter）：
        // 把内置真机样本的三条 mebx 轨整条搬过来，字节级一致，绕开整个 API 坑。

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
        dateItem.value = isoNow(date) as NSString

        // 真机自拍的实况照片 moov/meta 有 5 项（iPhone15,4 / iOS 27.2 实测）：
        //   content.identifier / make / model / software / creationdate
        // 我们原来只写 identifier + creationdate 两项。缺的这三项不参与配对，
        // 但壁纸引擎很可能拿它们判断「这是不是一台 iPhone 拍的正规实况」。
        // 值照抄真机：make=Apple / model=iPhone / software=系统版本。
        func qItem(_ key: String, _ value: String) -> AVMutableMetadataItem {
            let m = AVMutableMetadataItem()
            m.keySpace = .quickTimeMetadata
            m.key = key as NSString
            m.value = value as NSString
            return m
        }
        let makeItem = qItem("com.apple.quicktime.make", "Apple")
        let modelItem = qItem("com.apple.quicktime.model", "iPhone")
        #if canImport(UIKit)
        let osVer = UIDevice.current.systemVersion
        #else
        let osVer = "17.0"     // macOS CI probe 用固定值
        #endif
        let softItem = qItem("com.apple.quicktime.software", osVer)

        writer.metadata = [idItem, makeItem, modelItem, softItem, dateItem]
        Diag.log("顶层元数据 5 项：identifier / make=Apple / model=iPhone / software=\(osVer) / creationdate")

        // ---- 开跑
        Diag.log("阶段: writer 已建好（video=\(writer.inputs.contains { $0.mediaType == .video })"
                 + " audio=关 元数据=收尾后 box 移植）")

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

        // ---- 实况元数据轨：box 级移植（v3.0 的核心修复）
        //
        // 到这里产物只有一条 vide 轨 + moov/meta(content.identifier)。
        // 相册要把它认成实况照片，还必须有 live-photo-info / still-image-time /
        // video-orientation 三条 mebx 轨 —— 这三条整条从内置真机样本搬过来，
        // 视频 mdat 一个字节都不动。
        if let sampleURL {
            progress("补齐实况元数据…")
            let before = fileBytes(outputURL)
            do {
                let rep = try MetaTrakPorter.port(videoURL: outputURL, sampleURL: sampleURL)
                result.metaTracks = rep.tracks
                result.stillSeconds = rep.stillSeconds
                Diag.log("元数据轨移植完成：" + rep.tracks.joined(separator: " + ")
                         + " · 元数据 \(rep.sampleBytes)B"
                         + " · 静帧时刻 \(String(format: "%.3f", rep.stillSeconds))s"
                         + " · 产物 \(fmtMB(before))MB → \(fmtMB(Double(rep.outputBytes)))MB")
                progress("实况元数据已补齐（\(rep.tracks.count) 条轨）")
            } catch {
                Diag.log("元数据轨移植失败：" + error.localizedDescription)
                throw MakeError.msg("补齐实况元数据失败：" + error.localizedDescription)
            }
        } else {
            Diag.log("警告：没有传入真机样本，跳过了元数据轨移植（产物不会是实况照片）")
        }
        return result
    }

    // MARK: - 小工具

    static func fmtSec(_ s: Double) -> String {
        s.isFinite ? String(format: "%.2f", s) : "—"
    }

    static func isoNow(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return f.string(from: date)
    }

    static func fileBytes(_ url: URL) -> Double {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (a?[.size] as? NSNumber)?.doubleValue ?? 0
    }

    static func fmtMB(_ b: Double) -> String {
        String(format: "%.1f", b / 1_048_576.0)
    }
}
