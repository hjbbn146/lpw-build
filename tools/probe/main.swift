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

print(passTestOK ? "PASS-TEST PASS" : "PASS-TEST FAIL")
print(threeOK ? "THREE-TEST PASS" : "THREE-TEST 未通过或跳过")
exit(passTestOK ? 0 : 9)
