import Foundation
import UIKit
import AVFoundation
import CoreMedia
import CoreGraphics

/// 环境自检。
///
/// 目的：**用一次点击，把「是 iOS 版本/权限的问题，还是业务代码的问题」分开。**
///
/// 它自己造一段 2 秒的 H.264 测试视频，然后原样走一遍完整的直通链路
/// （建 writer → 加三轨 → 交错写入 → 补 still-image-time → 封装 → 读回校验），
/// 每一步都落盘。哪怕中途崩溃，`lpw.log` 的最后一行就是卡点。
///
/// 用自造素材而不是用户视频，是为了排除「输入文件本身有问题」这个变量。
enum SelfTest {

    private static var running = false

    static func run(step: @escaping (String) -> Void,
                    finish: @escaping (String) -> Void) {
        guard !running else { return }
        running = true

        DispatchQueue.global(qos: .userInitiated).async {
            defer { running = false }
            let lines = NSMutableString()

            func log(_ s: String) {
                lines.append(s + "\n")
                Diag.log("[自检] " + s)
                DispatchQueue.main.async { step(s) }
            }

            func end(_ verdict: String) {
                DispatchQueue.main.async { finish(lines as String) }
            }

            log("① 环境 · iOS \(UIDevice.current.systemVersion) · " + Mem.summary())

            // ---- ② 内置真机样本（元数据轨的供体）
            log("② 检查内置实况样本…")
            guard let sampleURL = Bundle.main.url(forResource: "sample_live", withExtension: "mov") else {
                log("   ✗ sample_live.mov 不在 App 包里，重装应用")
                end("自检中断：缺内置样本")
                return
            }
            let sData = (try? Data(contentsOf: sampleURL)) ?? Data()
            let sTxt = String(decoding: [UInt8](sData.prefix(1_000_000)), as: UTF8.self)
            let hasLpi = sTxt.contains("live-photo-info")
            let hasSit = sTxt.contains("still-image-time")
            let hasOri = sTxt.contains("video-orientation")
            // 样本里那条 video-orientation 我们**故意不用**（见 MetaTrakPorter.donorOrder），
            // 所以这里只要求 live-photo-info + still-image-time 两条在。
            log("   \(hasLpi && hasSit ? "✓" : "✗") 样本 \(sData.count / 1024)KB"
                + " · live-photo-info=\(hasLpi) still-image-time=\(hasSit)"
                + "（样本里另有一条 video-orientation=\(hasOri)，按真机基准不使用）")
            if !(hasLpi && hasSit) {
                end("自检中断：内置样本不完整")
                return
            }

            // ---- ③ 自造测试视频
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("selftest", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let src = dir.appendingPathComponent("t.mov")
            let dst = dir.appendingPathComponent("o.mov")

            log("③ 生成 2 秒测试视频（H.264 540×960）…")
            if let e = makeTestVideo(src, w: 540, h: 960, seconds: 2.0) {
                log("   ✗ " + e)
                end("自检中断：造不出测试视频")
                return
            }
            log("   ✓ " + String(format: "%.2f MB", Passthrough.fileBytes(src) / 1_048_576))

            // ---- ④ 零重编码直通 + 元数据轨 box 移植
            log("④ 直通 + 元数据轨移植…")
            do {
                let r = try Passthrough.convert(source: src,
                                                outputURL: dst,
                                                maxSeconds: 2.0,
                                                keepAudio: false,
                                                metaFormat: nil,
                                                identifier: "SELFTEST-0001",
                                                sampleURL: sampleURL,
                                                progress: { p in log("   " + p) })
                log("   ✓ \(r.frames) 帧 · 轨 " + r.metaTracks.joined(separator: "+"))
            } catch {
                log("   ✗ " + error.localizedDescription)
                end("自检中断：直通失败")
                return
            }

            // ---- ⑤ 读回校验
            log("⑤ 读回校验…")
            let a = AVURLAsset(url: dst)
            let vt = a.tracks(withMediaType: .video).count
            let mt = a.tracks(withMediaType: .metadata).count
            var hasId = false
            for m in a.metadata(forFormat: .quickTimeMetadata) {
                if ((m.key as? String) ?? "").contains("content.identifier") { hasId = true }
            }
            let data = (try? Data(contentsOf: dst)) ?? Data()
            let txt = String(decoding: [UInt8](data), as: UTF8.self)
            let mebx = txt.contains("mebx")
            let sit = txt.contains("still-image-time")
            let lpi = txt.contains("live-photo-info")
            let ori = txt.contains("video-orientation")
            log("   video=\(vt) metadata=\(mt) identifier=\(hasId)")
            log("   mebx=\(mebx) still-image-time=\(sit) live-photo-info=\(lpi) orientation=\(ori)")

            // 断言基准 = 真机自己拍的实况照片（iPhone15,4 / iOS 27.2 实测）：
            //   vide + live-photo-info + still-image-time + moov/meta(identifier)
            //   **没有 video-orientation**（有它反而会与 tkhd 旋转矩阵叠加成双重旋转）
            // 我们不做音频轨，所以 mt 期望值是 2 而不是真机的 3。
            var problems: [String] = []
            if vt == 0 { problems.append("没有画面轨") }
            if mt < 2 { problems.append("元数据轨不足 2 条（实际 \(mt)）") }
            if !hasId { problems.append("缺 content.identifier") }
            if !mebx { problems.append("没有 mebx 轨") }
            if !sit { problems.append("缺 still-image-time") }
            if !lpi { problems.append("缺 live-photo-info") }
            if ori { problems.append("多出 video-orientation（会造成方向转两次）") }

            let ok = problems.isEmpty
            log(ok ? "✅ 自检全部通过" : "⚠️ 结构不完整：" + problems.joined(separator: "、"))
            end(ok ? "✅ 自检通过：环境正常，问题只在具体视频或业务分支"
                   : "⚠️ 结构不完整：\n" + problems.joined(separator: "\n"))
        }
    }

    // MARK: - 造测试视频

    /// 返回 nil 表示成功，否则返回失败原因
    private static func makeTestVideo(_ url: URL, w: Int, h: Int, seconds: Double) -> String? {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            return "创建 writer 失败"
        }
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
        guard writer.canAdd(vIn) else { return "canAdd(video) 失败" }
        writer.add(vIn)

        guard writer.startWriting() else {
            return "startWriting 失败：\(writer.error?.localizedDescription ?? "未知")"
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { return "拿不到 pixelBufferPool" }

        let frames = max(1, Int(seconds * 30))
        for i in 0..<frames {
            var spin = 0
            while !vIn.isReadyForMoreMediaData && spin < 1000 {
                usleep(2000)
                spin += 1
            }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buf = pb else { continue }
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buf)
                for y in 0..<h {
                    let p = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<w {
                        p[x * 4 + 0] = UInt8((i * 6) % 256)
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
        if sem.wait(timeout: .now() + 60) == .timedOut {
            writer.cancelWriting()
            return "封装超时"
        }
        if writer.status != .completed {
            return "finish 失败：\(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")"
        }
        return nil
    }
}
