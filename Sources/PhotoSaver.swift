import Foundation
import UIKit
import Photos

// 实况照片必须由「照片 + 配对视频」在同一次 performChanges 里一起提交，
// 分成两次写会成为一张静态照片 + 一段普通视频。
enum PhotoSaver {

    static func requestAddOnlyPermission() -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .authorized || status == .limited { return true }
        if status == .denied || status == .restricted { return false }

        let sem = DispatchSemaphore(value: 0)
        var granted = false
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { s in
            granted = (s == .authorized || s == .limited)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 90)
        Diag.log("相册权限：\(granted ? "已允许" : "被拒绝")")
        return granted
    }

    @discardableResult
    static func savePair(photo: URL, video: URL) throws -> String {
        guard requestAddOnlyPermission() else {
            throw MakeError.msg("没有相册写入权限，请到 设置 → 隐私与安全性 → 照片 里允许")
        }

        var localId = ""
        var failureText: String?
        let sem = DispatchSemaphore(value: 0)

        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()

            let o1 = PHAssetResourceCreationOptions()
            o1.shouldMoveFile = false
            req.addResource(with: .photo, fileURL: photo, options: o1)

            let o2 = PHAssetResourceCreationOptions()
            o2.shouldMoveFile = false
            req.addResource(with: .pairedVideo, fileURL: video, options: o2)

            if let ph = req.placeholderForCreatedAsset {
                localId = ph.localIdentifier
            }
        }, completionHandler: { ok, err in
            if !ok {
                failureText = err?.localizedDescription ?? "未知错误"
            }
            sem.signal()
        })

        if sem.wait(timeout: .now() + 180) == .timedOut {
            throw MakeError.msg("写入相册超时")
        }
        if let f = failureText {
            throw MakeError.msg("写入相册失败：\(f)")
        }
        Diag.log("已写入相册，localIdentifier=\(localId)")
        return localId
    }

    /// 系统认定为实况照片的唯一判据：mediaSubtypes 含 .photoLive
    static func isPhotoLive(localIdentifier: String) -> Bool {
        guard !localIdentifier.isEmpty else { return false }
        let r = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let a = r.firstObject else { return false }
        return a.mediaSubtypes.contains(.photoLive)
    }

    /// 轮询几次，PhotoKit 入库后 mediaSubtypes 才可能被填好
    static func waitPhotoLive(localIdentifier: String, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isPhotoLive(localIdentifier: localIdentifier) { return true }
            Thread.sleep(forTimeInterval: 0.35)
        }
        return isPhotoLive(localIdentifier: localIdentifier)
    }

    static func openPhotosApp() {
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}
