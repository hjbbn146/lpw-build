import Foundation
import CoreGraphics
import ImageIO

// 在 macOS runner 上跑，验证 StillWriter 的两条路径在 Apple 平台上的真实行为。
// 目的是把「ImageIO 到底认不认 MakerNote」这件事从猜测变成实测。

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

let size = 800
guard let img = makeImage(size, size) else {
    print("PROBE fail: cannot render image")
    exit(1)
}

let ident = UUID().uuidString
let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("probe_still")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

print("PROBE identifier = \(ident)")

do {
    let url = try StillWriter.write(cgImage: img,
                                    to: dir,
                                    baseName: "probe",
                                    identifier: ident,
                                    dateString: "2026:11:18 09:00:00")
    let ok = StillWriter.containsMakerNote(at: url, expecting: ident)
    let bytes = (try? Data(contentsOf: url).count) ?? 0
    print("PROBE chosen = \(url.lastPathComponent)  bytes=\(bytes)  makerNoteBytesOK=\(ok)  imageIOReads=\(StillWriter.imageIOReadsMakerNote(at: url))")
    if !ok {
        print("PROBE fail: maker note missing in bytes")
        exit(2)
    }
    // 单独看一下 HEIC 路径到底能不能带 MakerNote（决定画质上限）
    for ext in ["heic", "jpg"] {
        let u = dir.appendingPathComponent("probe_alone.\(ext)")
        if ext == "heic" {
            _ = StillWriter.debugWriteHEIC(img, to: u, identifier: ident, dateString: "2026:11:18 09:00:00")
        } else {
            _ = try? StillWriter.debugWriteJPEG(img, to: u, identifier: ident, dateString: "2026:11:18 09:00:00")
        }
        let exists = FileManager.default.fileExists(atPath: u.path)
        let has = exists && StillWriter.containsMakerNote(at: u, expecting: ident)
        let size = (try? Data(contentsOf: u).count) ?? 0
        print("PROBE \(ext): exists=\(exists) bytes=\(size) makerNoteBytesOK=\(has)")
    }
} catch {
    print("PROBE fail: \(error.localizedDescription)")
    exit(3)
}

print("PROBE pass")
