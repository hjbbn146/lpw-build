import Foundation
import AVFoundation
import CoreMedia
import Photos

// still-image-time 元数据轨的格式描述。
//
// 为什么不能只靠 API 构造：
// CMMetadataFormatDescriptionCreateWithMetadataSpecifications 在 iOS 26 / macOS 26 上
// 对 still-image-time 这个 spec 一律回 -12710（kCMFormatDescriptionError_InvalidParameter）。
// 已在 macOS 26 runner 上实测六种参数组合（mdta/ 前缀有无、dataType 有无、
// Swift 数组 vs NSArray 桥接）—— 全部失败。所以主路径改成
// 「从相册里现成的实况照片把格式描述取出来」，那是系统自己写的，一定被认可。
// API 构造保留为兜底，覆盖还没收紧的旧系统版本。
enum MetaFormatProvider {

    private static var cache: CMFormatDescription?
    private static let lock = NSLock()

    static func stillImageTime() -> CMFormatDescription? {
        lock.lock()
        defer { lock.unlock() }
        if let c = cache { return c }

        // 优先级调整（v2.6）：内置真机样本 → 相册 → API 构造。
        // 内置样本是从相机实况照片直接导出的 .mov，里面的 mebx 轨格式描述
        // 由系统自己写入，一定被认可，而且完全不碰相册权限。
        // 旧版先走相册 + 同步 semaphore 等授权，在 iOS 27 / 重签环境下
        // 可能直接崩，这是「点生成立刻闪退」的重点嫌疑之一。
        if let f = fromBundledSample() {
            cache = f
            return f
        }
        if let f = fromLibrary() {
            cache = f
            return f
        }
        if let f = buildManually() {
            cache = f
            return f
        }
        return nil
    }


    static func isStillImageTimeFormat(_ fd: CMFormatDescription) -> Bool {
        guard let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any],
              let table = ext["MetadataKeyTable"] as? [AnyHashable: Any] else { return false }
        for (_, raw) in table {
            guard let entry = raw as? [String: Any] else { continue }
            if let v = entry["MetadataKeyValue"] as? Data,
               let s = String(data: v, encoding: .utf8),
               s.contains("com.apple.quicktime.still-image-time") {
                return true
            }
        }
        return false
    }

    // MARK: - 主路径：从 App 内置的真机实况样本提取（零权限依赖）

    private static func fromBundledSample() -> CMFormatDescription? {
        guard let url = Bundle.main.url(forResource: "sample_live", withExtension: "mov") else {
            Diag.log("元数据格式：内置样本缺失")
            return nil
        }
        let src = AVURLAsset(url: url)
        // 样本相机实况视频里有多条 mebx 轨（content.identifier / still-image-time /
        // live-photo-info …），必须挑出 still-image-time 那条，不能用第一条。
        for t in src.tracks(withMediaType: .metadata) {
            guard let anyFmt = t.formatDescriptions.first else { continue }
            let fd = anyFmt as! CMFormatDescription
            if isStillImageTimeFormat(fd) {
                Diag.log("元数据格式：已从内置样本提取 still-image-time 轨")
                return fd
            }
        }
        Diag.log("元数据格式：内置样本里没有 still-image-time 轨")
        return nil
    }

    // MARK: - 主路径：从相册实况照片提取

    private static func fromLibrary() -> CMFormatDescription? {
        guard ensureReadPermission() else {
            Diag.log("元数据格式：没有相册读取权限，换不了格式描述")
            return nil
        }

        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "mediaSubtypes & %d != 0",
                                     Int(PHAssetMediaSubtype.photoLive.rawValue))
        opts.fetchLimit = 1
        let assets = PHAsset.fetchAssets(with: .image, options: opts)
        guard let asset = assets.firstObject else {
            Diag.log("元数据格式：相册里找不到实况照片作样本")
            return nil
        }

        let resources = PHAssetResource.assetResources(for: asset)
        guard let res = resources.first(where: {
            $0.type == .pairedVideo || $0.type == .fullSizePairedVideo
        }) else {
            Diag.log("元数据格式：样本没有配对视频资源")
            return nil
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmt_\(UUID().uuidString).mov")
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        let reqOpts = PHAssetResourceRequestOptions()
        reqOpts.isNetworkAccessAllowed = true
        PHAssetResourceManager.default().writeData(for: res, toFile: tmp, options: reqOpts) { err in
            ok = (err == nil)
            if let err = err {
                Diag.log("元数据格式：下载样本失败 \(err.localizedDescription)")
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 60)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard ok else { return nil }

        let src = AVURLAsset(url: tmp)
        for t in src.tracks(withMediaType: .metadata) {
            guard let anyFmt = t.formatDescriptions.first else { continue }
            let fd = anyFmt as! CMFormatDescription
            let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
            Diag.log("元数据格式：已从相册样本提取 extensions=\(ext)")
            return fd
        }
        Diag.log("元数据格式：样本里没有元数据轨")
        return nil
    }

    private static func ensureReadPermission() -> Bool {
        let st = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if st == .authorized || st == .limited { return true }
        if st == .denied || st == .restricted {
            Diag.log("元数据格式：相册权限被拒绝，需在设置里改成完全访问")
            return false
        }
        var granted = false
        let sem = DispatchSemaphore(value: 0)
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in
            granted = (s == .authorized || s == .limited)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 90)
        Diag.log("元数据格式：相册完全访问 \(granted ? "已允许" : "被拒绝")")
        return granted
    }

    // MARK: - 从样本取真实的 item 模板（保证 dataType/language tag 完全匹配格式描述）

    /// 返回样本 still-image-time 轨里的第一个真实 AVMetadataItem。
    /// 用它做模板 append，dataType / keySpace / extendedLanguageTag 一定与
    /// fromBundledSample() 返回的格式描述匹配 —— 这正是真机崩溃的原因：
    /// 硬编码的 dataType 字符串与格式描述声明的对不上。
    static func stillImageTimeItemTemplate() -> AVMetadataItem? {
        guard let url = Bundle.main.url(forResource: "sample_live", withExtension: "mov") else { return nil }
        let asset = AVURLAsset(url: url)
        for t in asset.tracks(withMediaType: .metadata) {
            guard let anyFmt = t.formatDescriptions.first,
                  isStillImageTimeFormat(anyFmt as! CMFormatDescription) else { continue }
            guard let reader = try? AVAssetReader(asset: asset) else { continue }
            let out = AVAssetReaderTrackOutput(track: t, outputSettings: nil)
            out.alwaysCopiesSampleData = true
            guard reader.canAdd(out) else { continue }
            reader.add(out)
            guard reader.startReading() else { continue }
            while let sb = out.copyNextSampleBuffer() {
                if let groups = try? sb.metadataGroups(), let g = groups.first,
                   let real = g.items.first {
                    return real
                }
            }
        }
        return nil
    }

    // MARK: - 兜底：自己构造

    private static func buildManually() -> CMFormatDescription? {
        let idKey = kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String
        let dtKey = kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String
        let int8Type = "com.apple.quicktime.metadata.datatype.int8"
        let prefixed = "mdta/com.apple.quicktime.still-image-time"
        let plain = "com.apple.quicktime.still-image-time"

        let combos: [(String, String, String?)] = [
            ("ns/mdta/int8", prefixed, int8Type),
            ("ns/plain/int8", plain, int8Type),
            ("ns/mdta/nodt", prefixed, nil),
            ("ns/plain/nodt", plain, nil)
        ]
        for (label, id, dt) in combos {
            let d = NSMutableDictionary()
            d[idKey] = id
            if let dt = dt { d[dtKey] = dt }
            var fmt: CMFormatDescription?
            let st = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                allocator: kCFAllocatorDefault,
                metadataType: kCMMetadataFormatType_Boxed,
                metadataSpecifications: NSArray(object: d),
                formatDescriptionOut: &fmt)
            if st == noErr, let f = fmt {
                Diag.log("元数据格式 \(label)：构造成功")
                return f
            }
            Diag.log("元数据格式 \(label)：失败 status=\(st)")
        }

        let spec: [String: Any] = [idKey: prefixed, dtKey: int8Type]
        var fmt2: CMFormatDescription?
        let st2 = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray,
            formatDescriptionOut: &fmt2)
        if st2 == noErr, let f = fmt2 {
            Diag.log("元数据格式 swiftarray：构造成功")
            return f
        }
        Diag.log("元数据格式 swiftarray：失败 status=\(st2)")
        return nil
    }
}
