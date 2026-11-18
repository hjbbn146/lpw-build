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

            // ---- ② 相册权限 + still-image-time 格式描述
            log("② 从相册取 still-image-time 格式…")
            let mf = MetaFormatProvider.stillImageTime()
            if mf == nil {
                log("   ✗ 拿不到。相册需「完全访问」，且相册里要有一张实况照片")
                end("自检中断：缺元数据格式")
                return
            }
            log("   ✓ 拿到")

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

            // ---- ④ 零重编码直通（带元数据轨）
            log("④ 直通（视频 + 元数据两轨）…")
            do {
                let r = try Passthrough.convert(source: src,
                                                outputURL: dst,
                                                maxSeconds: 2.0,
                                                keepAudio: false,
                                                metaFormat: mf,
                                                identifier: "SELFTEST-0001",
                                                progress: { p in log("   " + p) })
                log("   ✓ \(r.frames) 帧")
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
            let mebx = data.range(of: Data("mebx".utf8)) != nil
            let sit = data.range(of: Data("still-image-time".utf8)) != nil
            log("   video=\(vt) metadata=\(mt) identifier=\(hasId) mebx=\(mebx) sit=\(sit)")

            let ok = vt > 0 && mt > 0 && hasId && mebx && sit
            log(ok ? "✅ 自检全部通过" : "⚠️ 结构不完整，见上")
            end(ok ? "✅ 自检通过：环境正常，问题只在具体视频或业务分支"
                   : "⚠️ 自检未全通过，把日志发开发者")
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
