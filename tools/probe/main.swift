import Foundation
import CoreGraphics
import ImageIO
import AVFoundation
import CoreMedia

// 在 macOS runner 上跑两块实测：
//   A. StillWriter 的 MakerNote 是否真的写进字节（HEIC vs JPEG）
//   B. still-image-time 元数据格式描述该怎么建（-12710 的真因），
//      并用通过的方式跑完整条「合成视频 → 带元数据轨的 MOV → 读回校验」

// ============================================================ A. MakerNote

func makeImage(_ w: Int, _ h: Int) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 0.18, green: 0.45, blue: 0.75, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(red: 0.95, green: 0.85, blue: 0.2, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
    return ctx.makeImage()
}

let probeDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("probe_all")
try? FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)

let ident = UUID().uuidString
print("PROBE identifier = \(ident)")

if let img = makeImage(800, 800) {
    for ext in ["heic", "jpg"] {
        let u = probeDir.appendingPathComponent("still_alone.\(ext)")
        if ext == "heic" {
            _ = StillWriter.debugWriteHEIC(img, to: u, identifier: ident, dateString: "2026:11:18 10:00:00")
        } else {
            _ = try? StillWriter.debugWriteJPEG(img, to: u, identifier: ident, dateString: "2026:11:18 10:00:00")
        }
        let exists = FileManager.default.fileExists(atPath: u.path)
        let has = exists && StillWriter.containsMakerNote(at: u, expecting: ident)
        let size = (try? Data(contentsOf: u).count) ?? 0
        print("PROBE still \(ext): exists=\(exists) bytes=\(size) makerNoteBytesOK=\(has)")
    }
} else {
    print("PROBE fail: 无法渲染测试图")
}

// ============================================== B. still-image-time 元数据轨

let idKey = kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String
let dtKey = kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String
let int8Type = "com.apple.quicktime.metadata.datatype.int8"

func report(_ label: String, _ status: OSStatus, _ fmt: CMFormatDescription?) {
    let ok = status == noErr && fmt != nil
    print("TRY \(ok ? "PASS" : "FAIL") \(label): status=\(status) fmt=\(fmt != nil)")
}

// A: Swift 数组直接 as CFArray（App 当前写法）
func variantA(_ id: String, _ dt: String?) -> (OSStatus, CMFormatDescription?) {
    var d: [String: Any] = [idKey: id]
    if let dt = dt { d[dtKey] = dt }
    var fmt: CMFormatDescription?
    let st = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
        allocator: kCFAllocatorDefault,
        metadataType: kCMMetadataFormatType_Boxed,
        metadataSpecifications: [d] as CFArray,
        formatDescriptionOut: &fmt)
    return (st, fmt)
}

// B: NSArray + NSDictionary 显式桥接
func variantB(_ id: String, _ dt: String?) -> (OSStatus, CMFormatDescription?) {
    let d = NSMutableDictionary()
    d[idKey] = id
    if let dt = dt { d[dtKey] = dt }
    var fmt: CMFormatDescription?
    let st = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
        allocator: kCFAllocatorDefault,
        metadataType: kCMMetadataFormatType_Boxed,
        metadataSpecifications: NSArray(object: d),
        formatDescriptionOut: &fmt)
    return (st, fmt)
}

// C: Swift 数组 + allocator nil
func variantC(_ id: String, _ dt: String?) -> (OSStatus, CMFormatDescription?) {
    var d: [String: Any] = [idKey: id]
    if let dt = dt { d[dtKey] = dt }
    var fmt: CMFormatDescription?
    let st = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
        allocator: nil,
        metadataType: kCMMetadataFormatType_Boxed,
        metadataSpecifications: [d] as CFArray,
        formatDescriptionOut: &fmt)
    return (st, fmt)
}

var good: CMFormatDescription?
var goodLabel = ""

func runVariant(_ label: String, _ fn: (String, String?) -> (OSStatus, CMFormatDescription?),
                _ id: String, _ dt: String?) {
    let (st, fmt) = fn(id, dt)
    report(label, st, fmt)
    if good == nil, st == noErr, let f = fmt {
        good = f
        goodLabel = label
    }
}

let prefixed = "mdta/com.apple.quicktime.still-image-time"
let plain = "com.apple.quicktime.still-image-time"

print("=== 格式描述构造方式 ===")
runVariant("A swift-array  mdta/ +int8", variantA, prefixed, int8Type)
runVariant("B nsarray      mdta/ +int8", variantB, prefixed, int8Type)
runVariant("C swift-array-nil mdta/ +int8", variantC, prefixed, int8Type)
runVariant("D nsarray      plain +int8", variantB, plain, int8Type)
runVariant("E nsarray      mdta/ no-dt", variantB, prefixed, nil)
runVariant("F nsarray      plain no-dt", variantB, plain, nil)

// 元数据轨只在构造成功时才测；构造失败不影响后面的直通实测
let metaFmt = good
if good != nil {
    print("PROBE 采用: \(goodLabel)")
} else {
    print("PROBE 元数据格式构造全灭（已知 -12710），跳过元数据轨，只测视频/音频交错")
}

if let metaFmt = metaFmt {
    // ---- 完整链路：合成 15 帧 H.264 + 元数据轨，然后读回
    let outURL = probeDir.appendingPathComponent("probe.mov")
    try? FileManager.default.removeItem(at: outURL)
    let movieIdent = UUID().uuidString
    print("PROBE movie identifier = \(movieIdent)")

    do {
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
        let vSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 240
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vIn.expectsMediaDataInRealTime = false
        let pAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 240
            ])
        writer.add(vIn)

        let mIn = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: metaFmt)
        mIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(mIn) else {
            print("PROBE fail: writer 不接受元数据轨")
            exit(3)
        }
        writer.add(mIn)
        let mAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: mIn)

        let idItem = AVMutableMetadataItem()
        idItem.keySpace = .quickTimeMetadata
        idItem.key = "com.apple.quicktime.content.identifier" as NSString
        idItem.value = movieIdent as NSString
        writer.metadata = [idItem]

        guard writer.startWriting() else {
            print("PROBE fail: startWriting \(writer.error?.localizedDescription ?? "")")
            exit(4)
        }
        writer.startSession(atSourceTime: .zero)

        var frames = 0
        for i in 0..<15 {
            let deadline = Date().addingTimeInterval(5)
            while !vIn.isReadyForMoreMediaData && Date() < deadline { usleep(2000) }
            guard let pool = pAdaptor.pixelBufferPool else { break }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buf = pb else { continue }
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                memset(base, Int32(40 + i * 10), CVPixelBufferGetDataSize(buf))
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            if pAdaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)) {
                frames += 1
            }
        }
        vIn.markAsFinished()
        print("PROBE 合成视频帧数 = \(frames)")

        let metaItem = AVMutableMetadataItem()
        metaItem.keySpace = .quickTimeMetadata
        metaItem.key = "com.apple.quicktime.still-image-time" as NSString
        metaItem.value = NSNumber(value: Int8(-1))
        metaItem.dataType = int8Type
        let group = AVTimedMetadataGroup(
            items: [metaItem],
            timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 600)))
        let appended = mAdaptor.append(group)
        print("PROBE metaAppend = \(appended)")
        mIn.markAsFinished()

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        _ = sem.wait(timeout: .now() + 30)
        guard writer.status == .completed else {
            print("PROBE fail: finish status=\(writer.status.rawValue) \(writer.error?.localizedDescription ?? "")")
            exit(6)
        }
    } catch {
        print("PROBE fail: \(error)")
        exit(7)
    }

    // ---- 读回
    let asset = AVURLAsset(url: outURL)
    let metaTracks = asset.tracks(withMediaType: .metadata)
    print("PROBE 读回: 元数据轨 \(metaTracks.count) 条, 时长 \(String(format: "%.2f", CMTimeGetSeconds(asset.duration)))s")

    let all = asset.metadata(forFormat: AVMetadataFormat.quickTimeMetadata)
    var hasId = false
    for m in all {
        let k = (m.key as? String) ?? ""
        if k.contains("content.identifier") { hasId = true }
    }
    print("PROBE 读回: 顶层元数据 \(all.count) 项, 含 content.identifier = \(hasId)")

    let data = (try? Data(contentsOf: outURL)) ?? Data()
    let hasMebx = data.range(of: Data("mebx".utf8)) != nil
    let hasSit = data.range(of: Data("still-image-time".utf8)) != nil
    let hasUuid = data.range(of: Data(movieIdent.utf8)) != nil
    print("PROBE 字节: mebx=\(hasMebx) still-image-time=\(hasSit) uuid=\(hasUuid) size=\(data.count)")

    if metaTracks.count > 0 && hasId && hasSit && hasUuid {
        print("PROBE meta pass")
    } else {
        print("PROBE meta fail: tracks=\(metaTracks.count) id=\(hasId) sit=\(hasSit) uuid=\(hasUuid)")
    }
} else {
    print("PROBE 跳过元数据轨链路")
}


// ============================================================ C. 直通实测
//
// 这一段是这一轮的重点：真机上「点生成 → 转几圈 → 卡在第 62 帧」，
// 而 62 帧 ≈ 2 秒正好是 AVAssetWriter 的多轨交错窗口。
// 所以要在这里复现「视频 + 音频双轨」的交错写入，看 New passthrough
// 写法（requestMediaDataWhenReady）能不能一路跑完。


// ---- 探一下 API 到底是「只拒绝 still-image-time」还是「全部拒绝」
// 这一步决定能不能在 CI 上测三轨（视频 + 音频 + 元数据）。
print("")
print("=== 其他 metadata spec 能否构造 ===")
var altFmt: CMFormatDescription?
let altCandidates: [(String, String?)] = [
    ("mdta/com.apple.quicktime.still-image-time", "com.apple.quicktime.metadata.datatype.utf8"),
    ("mdta/com.apple.quicktime.location.ISO6709", "com.apple.quicktime.metadata.datatype.utf8"),
    ("mdta/com.apple.quicktime.make", "com.apple.quicktime.metadata.datatype.utf8"),
    ("com.apple.quicktime.location.ISO6709", nil),
    ("mebx", nil)
]
for (k, dt) in altCandidates {
    var d: [String: Any] = [idKey: k]
    if let dt = dt { d[dtKey] = dt }
    var f: CMFormatDescription?
    let st = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
        allocator: kCFAllocatorDefault,
        metadataType: kCMMetadataFormatType_Boxed,
        metadataSpecifications: [d] as CFArray,
        formatDescriptionOut: &f)
    print("ALT \(k) dt=\(dt ?? "nil") status=\(st) fmt=\(f != nil)")
    if st == noErr, let ff = f, altFmt == nil { altFmt = ff }
}
if altFmt == nil { print("ALT 全部失败 → 这个 API 在 26 上整体不可用，CI 无法测三轨") }

print("")
print("=== 直通实测（视频 + 音频交错）===")


/// 生成一段纯色渐变测试视频（H.264，30fps）
func makeSolidVideo(_ url: URL, w: Int, h: Int, seconds: Double) -> String? {
    try? FileManager.default.removeItem(at: url)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return "创建 writer 失败" }
    let vSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: w,
        AVVideoHeightKey: h
    ]
    let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
    vIn.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: vIn,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h
        ])
    guard writer.canAdd(vIn) else { return "canAdd 失败" }
    writer.add(vIn)
    guard writer.startWriting() else {
        return "startWriting 失败 \(writer.error?.localizedDescription ?? "")"
    }
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else { return "拿不到 pixelBufferPool" }

    let frames = Int(seconds * 30)
    for i in 0..<frames {
        var spin = 0
        while !vIn.isReadyForMoreMediaData && spin < 1000 { usleep(2000); spin += 1 }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let buf = pb else { continue }
        CVPixelBufferLockBaseAddress(buf, [])
        if let base = CVPixelBufferGetBaseAddress(buf) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<h {
                let p = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w {
                    p[x * 4 + 0] = UInt8((i * 5) % 256)
                    p[x * 4 + 1] = UInt8((x * 255) / max(1, w))
                    p[x * 4 + 2] = UInt8((y * 255) / max(1, h))
                    p[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        _ = adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
    }
    vIn.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    _ = sem.wait(timeout: .now() + 90)
    if writer.status != .completed {
        return "finish 失败 \(writer.error?.localizedDescription ?? "")"
    }
    return nil
}

/// 给视频配一条系统音效，做出「视频 + 音频」双轨素材
func attachSystemAudio(video: URL, to out: URL, seconds: Double) -> String? {
    let candidates = ["/System/Library/Sounds/Ping.aiff",
                      "/System/Library/Sounds/Tink.aiff",
                      "/System/Library/Sounds/Pop.aiff",
                      "/System/Library/Sounds/Glass.aiff"]
    guard let sPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
        return "系统里找不到音效文件"
    }
    let comp = AVMutableComposition()
    let vAsset = AVURLAsset(url: video)
    guard let vSrc = vAsset.tracks(withMediaType: .video).first,
          let vDst = comp.addMutableTrack(withMediaType: .video,
                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
        return "composition 加视频轨失败"
    }
    try? vDst.insertTimeRange(CMTimeRange(start: .zero, duration: vAsset.duration),
                              of: vSrc, at: .zero)

    let aAsset = AVURLAsset(url: URL(fileURLWithPath: sPath))
    guard let aSrc = aAsset.tracks(withMediaType: .audio).first,
          let aDst = comp.addMutableTrack(withMediaType: .audio,
                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
        return "composition 加音频轨失败"
    }
    let need = CMTime(seconds: seconds, preferredTimescale: 600)
    try? aDst.insertTimeRange(CMTimeRange(start: .zero, duration: min(need, aAsset.duration)),
                              of: aSrc, at: .zero)

    try? FileManager.default.removeItem(at: out)
    guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
        return "创建导出会话失败"
    }
    ex.outputURL = out
    ex.outputFileType = .mov
    let sem = DispatchSemaphore(value: 0)
    ex.exportAsynchronously { sem.signal() }
    _ = sem.wait(timeout: .now() + 180)
    if ex.status != .completed {
        return "导出失败 status=\(ex.status.rawValue) \(ex.error?.localizedDescription ?? "")"
    }
    return nil
}

let cDir = probeDir.appendingPathComponent("pass")
try? FileManager.default.createDirectory(at: cDir, withIntermediateDirectories: true)
let rawVideo = cDir.appendingPathComponent("raw.mov")
let srcWithAudio = cDir.appendingPathComponent("src_audio.mov")
let outMov = cDir.appendingPathComponent("out.mov")

var passTestOK = false

if let e = makeSolidVideo(rawVideo, w: 540, h: 960, seconds: 3.0) {
    print("PASS-TEST 测试视频生成失败: \(e)")
} else {
    print("PASS-TEST 测试视频 OK \(Passthrough.fmtMB(Passthrough.fileBytes(rawVideo)))MB")

    var src = rawVideo
    if let e = attachSystemAudio(video: rawVideo, to: srcWithAudio, seconds: 3.0) {
        print("PASS-TEST 加音轨失败（退回纯视频）: \(e)")
    } else {
        let a = AVURLAsset(url: srcWithAudio)
        print("PASS-TEST 双轨素材 OK \(Passthrough.fmtMB(Passthrough.fileBytes(srcWithAudio)))MB"
              + " v=\(a.tracks(withMediaType: .video).count)"
              + " a=\(a.tracks(withMediaType: .audio).count)")
        src = srcWithAudio
    }

    let t0 = Date()
    do {
        let r = try Passthrough.convert(source: src, outputURL: outMov, maxSeconds: 3.0,
                                        keepAudio: true, metaFormat: nil,
                                        identifier: "PROBE-TEST-IDENT",
                                        progress: { print("PASS-TEST progress: \($0)") })
        let dt = Date().timeIntervalSince(t0)
        let oa = AVURLAsset(url: outMov)
        print("PASS-TEST convert OK frames=\(r.frames) audio=\(r.audioSamples)"
              + " 用时=\(String(format: "%.2f", dt))s")
        print("PASS-TEST output video=\(oa.tracks(withMediaType: .video).count)"
              + " audio=\(oa.tracks(withMediaType: .audio).count)"
              + " dur=\(String(format: "%.2f", CMTimeGetSeconds(oa.duration)))s"
              + " size=\(Passthrough.fmtMB(Passthrough.fileBytes(outMov)))MB")
        passTestOK = r.frames > 0
    } catch {
        print("PASS-TEST convert FAIL: \(error.localizedDescription)")
    }
}

// ---- 有元数据格式时再跑一遍三轨（元数据轨全程空着、最后才写，验证不阻塞）
var threeOK = false
if let alt = altFmt, passTestOK {
    let threeURL = cDir.appendingPathComponent("three.mov")
    do {
        let r = try Passthrough.convert(source: srcWithAudio, outputURL: threeURL,
                                        maxSeconds: 3.0, keepAudio: true, metaFormat: alt,
                                        identifier: "THREE-TRACK-TEST", progress: { _ in })
        let oa = AVURLAsset(url: threeURL)
        print("THREE-TEST OK frames=\(r.frames) audio=\(r.audioSamples)"
              + " tracks v=\(oa.tracks(withMediaType: .video).count)"
              + " a=\(oa.tracks(withMediaType: .audio).count)"
              + " m=\(oa.tracks(withMediaType: .metadata).count)")
        threeOK = r.frames > 0
    } catch {
        print("THREE-TEST FAIL: \(error.localizedDescription)")
    }
} else {
    print("THREE-TEST 跳过（拿不到可用的元数据格式）")
}

// ---- 产物结构探针（v4.6）：LPI 时基 + meta 五项 ----
/// 读 MOV 里 live-photo-info 轨的 mdhd timescale；找不到返回 nil。
func probeLpiTimescale(_ url: URL) -> UInt32? {
    guard let d = try? Data(contentsOf: url) else { return nil }
    let b = [UInt8](d)
    let tops = BoxKit.boxes(b, 0, b.count)
    guard let moov = tops.first(where: { $0.type == "moov" }) else { return nil }
    for tk in BoxKit.children(b, moov).filter({ $0.type == "trak" }) {
        guard let stsd = BoxKit.find(b, tk, ["mdia", "minf", "stbl", "stsd"]) else { continue }
        let p = BoxKit.payload(stsd)
        let esz = Int(BoxKit.u32(b, p + 8))
        let lo = p + 8, hi = min(b.count, lo + max(0, esz))
        guard lo < hi else { continue }
        let s = String(decoding: b[lo..<hi], as: UTF8.self)
        guard s.contains("live-photo-info") else { continue }
        guard let mdhd = BoxKit.find(b, tk, ["mdia", "mdhd"]) else { return nil }
        let q = BoxKit.payload(mdhd)
        return BoxKit.u32(b, q + 12)      // version 0: timescale 在 payload+12
    }
    return nil
}

/// meta keys 是否含 make/model/software 三项（配 identifier/creationdate 共五项）
func txt5Keys(_ data: Data) -> Bool {
    return data.range(of: Data("com.apple.quicktime.make".utf8)) != nil
        && data.range(of: Data("com.apple.quicktime.model".utf8)) != nil
        && data.range(of: Data("com.apple.quicktime.software".utf8)) != nil
}

/// ★ v4.8 核心断言：still-image-time 轨的 **stsd 格式描述** 与 **sample 内容** 必须自洽。
///
/// 根因（2026-11-19 定位）：内置旧供体 sample_live.mov 的 SIT stsd = 293 字节，
/// 里面声明了 2 个 key（still-image-time + still-image-transform **+ reference-dimensions**，
/// 共 3 个 dtyp 块）；而我们把 sample 换成了真机的 89 字节版（只有 2 个 atom）。
/// 系统按 stsd 声明的 key 结构解析 sample，发现少一个 atom → 判定 still-image-time 非法
/// → 实况壁纸按钮永远是灰的。之前所有 probe 只验 sample、不验 stsd，所以一直"全 PASS 却不可用"。
///
/// 本函数检查：SIT 轨 stsd 的 keys 定义数量、sample 的 atom 数量，两者必须一致。
func sitStsdConsistent(_ url: URL) -> (ok: Bool, note: String) {
    guard let d = try? Data(contentsOf: url) else { return (false, "读文件失败") }
    let b = [UInt8](d)
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

        // stsd 里 keys box 的 count
        var keyCount = -1
        if let kr = s.range(of: "keys") {
            let ks = s.distance(from: s.startIndex, to: kr.lowerBound) - 4
            if ks >= 0 && ks + 16 <= hi - lo {
                let sub = [UInt8](b[(lo + ks)..<hi])
                keyCount = Int(BoxKit.u32(sub, 12))
            }
        }

        // 取第一个 sample 的字节，数 atom 个数（每个 atom = 4B size + 4B key + data）
        guard let stsz = BoxKit.find(b, tk, ["mdia", "minf", "stbl", "stsz"]) else { continue }
        let q = BoxKit.payload(stsz)
        let fixed = Int(BoxKit.u32(b, q + 4))
        guard fixed > 0 else { continue }
        guard let stco = BoxKit.find(b, tk, ["mdia", "minf", "stbl", "stco"]) else { continue }
        let r = BoxKit.payload(stco)
        guard Int(BoxKit.u32(b, r + 4)) >= 1 else { continue }
        let off = Int(BoxKit.u32(b, r + 8))
        guard off + fixed <= b.count else { continue }
        let sample = Array(b[off..<(off + fixed)])

        // 数 atom（sample 是若干 (size, key, payload) 串接）
        var atoms = 0
        var ptr = 0
        while ptr + 8 <= sample.count {
            let sz = Int(BoxKit.u32(sample, ptr))
            if sz < 8 || ptr + sz > sample.count { break }
            atoms += 1
            ptr += sz
        }
        // stsd 的 keys count 里，若含 transform-reference-dimensions 会多一个 key。
        // 真机：keyCount=1、atoms=2（标记 + 矩阵）；旧样本：keyCount=1、atoms=3（多 reference-dimensions）
        // 判据用 "stsd 的 esz 是否等于真机 184" 更直接：184 = 2 atom 版，293 = 3 atom 版。
        let note = "SIT stsd esz=\(esz) keysCount=\(keyCount) sampleAtoms=\(atoms) sampleBytes=\(fixed)"
        // 真机自洽条件：esz==184 且 atoms==2 且 fixed==89
        let ok = (esz == 184 && atoms == 2 && fixed == 89)
        return (ok, note)
    }
    return (false, "没找到 still-image-time 轨")
}

// ---- D. 内置真机样本的真实 mebx 格式描述 → 两轨直通（v2.6 主路径验证）
print("")
print("=== 内置样本元数据格式 → 直通验证 ===")
var bundledOK = false
let sampleURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/sample_live.mov")
var bundledFmt: CMFormatDescription?
if FileManager.default.fileExists(atPath: sampleURL.path) {
    let sa = AVURLAsset(url: sampleURL)
    var metaTracks = 0
    for t in sa.tracks(withMediaType: .metadata) {
        metaTracks += 1
        if let f = t.formatDescriptions.first {
            let fd = f as! CMFormatDescription
            var isSit = false
            if let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any],
               let table = ext["MetadataKeyTable"] as? [AnyHashable: Any] {
                outer: for (_, raw) in table {
                    guard let entry = raw as? [String: Any] else { continue }
                    if let v = entry["MetadataKeyValue"] as? Data,
                       let kstr = String(data: v, encoding: .utf8),
                       kstr.contains("com.apple.quicktime.still-image-time") {
                        isSit = true
                        break outer
                    }
                }
            }
            print("BUNDLED 轨\(metaTracks) isStillImageTime=\(isSit)")
            if isSit && bundledFmt == nil { bundledFmt = fd }
        }
    }
    print("BUNDLED 共 \(metaTracks) 条 metadata 轨")
} else {
    print("BUNDLED 样本文件不存在: \(sampleURL.path)")
}

// ---- v3.0 核心路径：box 级元数据轨移植（不再依赖 bundledFmt）
let bout = cDir.appendingPathComponent("bundled_out.mov")
do {
    let r = try Passthrough.convert(source: rawVideo, outputURL: bout, maxSeconds: 3.0,
                                    keepAudio: false, metaFormat: nil,
                                    identifier: "BUNDLED-TEST",
                                    sampleURL: sampleURL,
                                    progress: { _ in })
    let oa = AVURLAsset(url: bout)
    let mt = oa.tracks(withMediaType: .metadata).count
    let vt = oa.tracks(withMediaType: .video).count
    let data = (try? Data(contentsOf: bout)) ?? Data()
    let sit = data.range(of: Data("still-image-time".utf8)) != nil
    let lpi = data.range(of: Data("live-photo-info".utf8)) != nil
    let ori = data.range(of: Data("video-orientation".utf8)) != nil
    let uuid = data.range(of: Data("BUNDLED-TEST".utf8)) != nil
    let mebx = data.range(of: Data("mebx".utf8)) != nil
    print("PORTER convert OK frames=\(r.frames) video轨=\(vt) metadata轨=\(mt)")
    print("PORTER mebx=\(mebx) sit=\(sit) lpi=\(lpi) ori=\(ori) uuid=\(uuid)")
    print("PORTER 移植轨: " + r.metaTracks.joined(separator: "+"))
    // AVURLAsset 未必把 mebx 轨算进 .metadata，所以以二进制里的 key 字符串为准。
    // v4.1 起 video-orientation 必须**不存在**（真机就没有，有它=双重旋转）：
    // 所以这里断言的正是 !ori。
    // v4.4 起 still-image-time 的 sample 必须换成真机那份 89 字节（标记 + 单位矩阵），
    // 照搬样本会带上透视分量 → 封面被判不合法。
    let canonicalSIT = Data(MetaTrakPorter.canonicalStillSample)
    let sitCanonical = data.range(of: canonicalSIT) != nil
    // 静帧时刻必须是 0.5 秒（真机与两个第三方可用产物一致）
    let stillOK = abs(r.stillSeconds - 0.5) < 0.06
    // v4.6 起：LPI 轨时基必须是 60000，meta 必须有 make/model/software 五项
    var lpiTsOK = false
    if let ts = probeLpiTimescale(bout) { lpiTsOK = (ts == 60000) }
    let meta5 = txt5Keys(data)
    // ★ v4.8：stsd 与 sample 必须自洽（这次真正的根因）
    let sitCons = sitStsdConsistent(bout)
    print("PORTER SIT自洽: \(sitCons.ok) · \(sitCons.note)")
    bundledOK = r.frames > 0 && sit && lpi && !ori && uuid && sitCanonical && stillOK && lpiTsOK && meta5 && sitCons.ok
    print("PORTER 断言: frames>0=\(r.frames > 0) sit=\(sit) lpi=\(lpi) 无ori=\(!ori) uuid=\(uuid) 单位矩阵=\(sitCanonical) 静帧0.5s=\(stillOK)(\(String(format: "%.3f", r.stillSeconds))) LPI时基60000=\(lpiTsOK) meta5=\(meta5) SIT自洽=\(sitCons.ok)")
} catch {
    print("PORTER convert FAIL: \(error.localizedDescription)")
}
print(bundledOK ? "PORTER PASS" : "PORTER 未通过")


// ---- E. 从样本 still-image-time 轨读出真实的 AVMetadataItem 参数
print("")
print("=== 样本 still-image-time 真实 item 参数 ===")
if FileManager.default.fileExists(atPath: sampleURL.path) {
    let sa = AVURLAsset(url: sampleURL)
    for t in sa.tracks(withMediaType: .metadata) {
        let r = try? AVAssetReader(asset: sa)
        let out = AVAssetReaderTrackOutput(track: t, outputSettings: nil)
        guard let rr = r, rr.canAdd(out) else { continue }
        rr.add(out)
        guard rr.startReading() else { continue }
        // 直接读 CMSampleBuffer 的原始字节比走 AVMetadataItem 更稳，
        // 也不用 metadataGroups()（那个 API 在 macOS 26 SDK 里已经没有了）
        if let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            var len = 0
            var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &len, dataPointerOut: &ptr)
            if let p = ptr, len > 0 {
                print("SIT-SAMPLE bytes=\(len) hex=\(Data(bytes: p, count: min(len, 120)).map { String(format: "%02x", $0) }.joined())")
            }
        }
        break
    }
}

print(passTestOK ? "PASS-TEST PASS" : "PASS-TEST FAIL")
print(threeOK ? "THREE-TEST PASS" : "THREE-TEST 未通过或跳过")
exit(passTestOK ? 0 : 9)
