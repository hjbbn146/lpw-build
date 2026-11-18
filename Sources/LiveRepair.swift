import Foundation
import Photos
import AVFoundation
import CoreGraphics

/// 修复相册里已经生成、但结构不对（设不了壁纸）的实况照片。
///
/// 思路：**不修补旧文件，直接用旧资产里的配对视频当源，重新生成一次**。
///
/// 为什么不做「原地补 box」：
/// 旧产物可能缺轨、可能超长（>3 秒）、静帧还可能是 ImageIO 写的 JPG（MakerNote 被丢）。
/// 逐项去补要处理一堆分支，而重新走一遍直通只需要几十秒，
/// 且能保证「截断到 2.9 秒 + 2 条元数据轨 + HEIC 静帧」全部到位。
/// 直通本身不重编码，所以重新生成不会损失画质。
enum LiveRepair {

    enum RepairError: LocalizedError {
        case msg(String)
        var errorDescription: String? {
            if case .msg(let s) = self { return s }
            return nil
        }
    }

    /// 修复要读回配对视频，必须「完全访问」权限（不是 addOnly）
    static func requestReadPermission() -> Bool {
        let st = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if st == .authorized || st == .limited { return true }
        if st == .denied || st == .restricted { return false }

        let sem = DispatchSemaphore(value: 0)
        var granted = false
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in
            granted = (s == .authorized || s == .limited)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 90)
        Diag.log("相册完全访问权限：\(granted ? "已允许" : "被拒绝")")
        return granted
    }

    /// 相册里最近一张「带配对视频」的照片（不管它结构对不对）
    static func latestLiveAsset() -> PHAsset? {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = 60
        let res = PHAsset.fetchAssets(with: .image, options: opts)
        var found: PHAsset?
        res.enumerateObjects { a, _, stop in
            if a.mediaSubtypes.contains(.photoLive) {
                found = a
                stop.pointee = true
            }
        }
        return found
    }

    /// 把资产的配对视频写到本地临时文件
    static func exportPairedVideo(_ asset: PHAsset, to url: URL) throws {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let pv = resources.first(where: { $0.type == .pairedVideo }) else {
            throw RepairError.msg("这张照片没有配对视频，不是实况照片（相册里可能只剩一张静态图）")
        }
        try? FileManager.default.removeItem(at: url)

        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true

        var failure: String?
        let sem = DispatchSemaphore(value: 0)
        PHAssetResourceManager.default().writeData(for: pv, toFile: url, options: opts) { err in
            if let e = err { failure = e.localizedDescription }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 120) == .timedOut {
            throw RepairError.msg("读取配对视频超时（视频可能太大或 iCloud 下载太慢）")
        }
        if let f = failure {
            throw RepairError.msg("读取配对视频失败：\(f)")
        }
        let sz = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard sz > 1024 else {
            throw RepairError.msg("读回来的配对视频是空的")
        }
        Diag.log("修复：已导出配对视频 \(sz / 1024)KB")
    }

    /// 诊断一张资产：把它现在的结构问题列出来（给界面显示用）
    static func diagnose(_ asset: PHAsset) -> String {
        let res = PHAssetResource.assetResources(for: asset)
        let types = res.map { name(of: $0.type) }
        let d = asset.duration
        var parts: [String] = []
        parts.append(String(format: "%.2f 秒", d))
        if d > 3.0 {
            parts.append("超过 3 秒上限")
        }
        parts.append("资源：" + types.joined(separator: "+"))
        return parts.joined(separator: " · ")
    }

    private static func name(of t: PHAssetResourceType) -> String {
        switch t {
        case .photo: return "照片"
        case .pairedVideo: return "配对视频"
        case .fullSizePhoto: return "原图"
        case .video: return "视频"
        case .alternatePhoto: return "备选照片"
        default: return "其他"
        }
    }

    /// 完整修复流程：导出旧视频 → 重新直通 + 截断 + 重移植 → 新静帧
    static func repair(_ asset: PHAsset,
                       maxSeconds: Double,
                       progress: @escaping (String) -> Void) throws -> MadeLive {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lprepair", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent("src_\(Int(Date().timeIntervalSince1970)).mov")

        progress("读取旧实况的配对视频…")
        try exportPairedVideo(asset, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard let info = MediaInspector.inspect(tmp) else {
            throw RepairError.msg("读回来的视频没有画面轨，无法修复")
        }
        guard info.duration > 0.15 else {
            throw RepairError.msg(String(format: "视频只有 %.2f 秒，太短，做不成实况", info.duration))
        }
        Diag.log(String(format: "修复源：%.2f 秒 %d×%d %@",
                        info.duration, info.width, info.height, info.codec))

        // 关键：走一遍完整生成流程。旧文件的元数据轨会被丢弃（我们从源视频重新直通），
        // 时长强制截到 2.9 秒，静帧重新用 HEIC 写。
        return try LivePhotoMaker.make(source: tmp,
                                       maxSeconds: maxSeconds,
                                       keepAudio: false,
                                       progress: progress)
    }
}
