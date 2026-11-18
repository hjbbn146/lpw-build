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

guard let metaFmt = good else {
    print("PROBE fail: 六种构造方式全部失败")
    exit(2)
}
print("PROBE 采用: \(goodLabel)")

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
    print("PROBE pass")
    exit(0)
} else {
    print("PROBE fail: tracks=\(metaTracks.count) id=\(hasId) sit=\(hasSit) uuid=\(hasUuid)")
    exit(8)
}
