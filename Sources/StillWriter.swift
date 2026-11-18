import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// Apple MakerNote（ContentIdentifier）写入器
//
// 真机实况照片的静帧里，EXIF MakerNote 有一段 69 字节结构：
//   [0..9]   "Apple iOS\0"
//   [10..11] 00 01            版本
//   [12..13] "MM"             TIFF 大端
//   [14..15] 00 01            IFD entry 数
//   [16..17] 00 11            tag 0x0011 = ContentIdentifier
//   [18..19] 00 02            type 2 = ASCII
//   [20..23] 00 00 00 25      count 37
//   [24..27] 00 00 00 20      value offset 32（相对 MakerNote 起点）
//   [28..31] 00 00 00 00      next IFD
//   [32..67] UUID(36)
//   [68]     00
//
// ImageIO 对 MakerNote 的“写”支持不可靠（读没问题、写常被静默丢弃），
// 所以这里做两条路：先按常规写 HEIC 并读回验证；拿不到就自己拼 EXIF
// 塞进 JPEG。哪条通就用哪条，不赌。
enum StillWriter {

    static let makerNoteTemplate: [UInt8] = [
        0x41, 0x70, 0x70, 0x6C, 0x65, 0x20, 0x69, 0x4F, 0x53, 0x00,
        0x00, 0x01,
        0x4D, 0x4D,
        0x00, 0x01,
        0x00, 0x11,
        0x00, 0x02,
        0x00, 0x00, 0x00, 0x25,
        0x00, 0x00, 0x00, 0x20,
        0x00, 0x00, 0x00, 0x00
    ]

    static func makerNote(identifier: String) -> Data {
        var d = Data(makerNoteTemplate)
        var u = Array(identifier.utf8)
        if u.count > 36 { u = Array(u[0..<36]) }
        while u.count < 36 { u.append(0x30) }
        d.append(contentsOf: u)
        d.append(0x00)
        return d
    }

    // MARK: - 对外入口

    @discardableResult
    static func write(cgImage: CGImage,
                      to dir: URL,
                      baseName: String,
                      identifier: String,
                      dateString: String) throws -> URL {

        // 路 1：HEIC（画质最好），按字节确认 MakerNote 真写进去了
        let heicURL = dir.appendingPathComponent(baseName + ".heic")
        if debugWriteHEIC(cgImage, to: heicURL, identifier: identifier, dateString: dateString),
           containsMakerNote(at: heicURL, expecting: identifier) {
            Diag.log("静帧：HEIC 写入 MakerNote 成功")
            return heicURL
        }
        try? FileManager.default.removeItem(at: heicURL)

        // 路 2：JPEG + 手工 EXIF（位置完全由我们控制，成功率最高）
        let jpgURL = dir.appendingPathComponent(baseName + ".jpg")
        try debugWriteJPEG(cgImage, to: jpgURL, identifier: identifier, dateString: dateString)
        guard containsMakerNote(at: jpgURL, expecting: identifier) else {
            throw MakeError.msg("静帧 MakerNote 写入失败，产物不会被识别为实况照片")
        }
        Diag.log("静帧：JPEG + 手工 EXIF 写入 MakerNote 成功")
        return jpgURL
    }

    // MARK: - 验证（按字节，不信 ImageIO 的属性解析）

    /// ImageIO 的 kCGImagePropertyExifMakerNote 不一定会把 Apple MakerNote 回吐出来，
    /// 所以判据必须是「文件字节里确实有 Apple iOS 头部 + 我们的 UUID」。
    /// 系统相册判定实况照片走的是原生 EXIF 解析，不依赖这个公开属性。
    static func containsMakerNote(at url: URL, expecting identifier: String) -> Bool {
        guard let d = try? Data(contentsOf: url) else { return false }
        let uuid = Data(identifier.utf8)
        guard let r = d.range(of: uuid) else { return false }
        let pos = d.distance(from: d.startIndex, to: r.lowerBound)
        guard pos >= 32 else { return false }
        let headStart = d.index(d.startIndex, offsetBy: pos - 32)
        let headEnd = d.index(d.startIndex, offsetBy: pos)
        let prefix = d[headStart..<headEnd]
        return prefix.starts(with: Data("Apple iOS".utf8))
    }

    /// 仅用于诊断：ImageIO 能否把 MakerNote 作为属性读回来（不作为判据）
    static func imageIOReadsMakerNote(at url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let note = exif[kCGImagePropertyExifMakerNote as String] as? Data
        else { return false }
        return note.count > 40
    }

    // MARK: - HEIC

    static func debugWriteHEIC(_ image: CGImage, to url: URL,
                                  identifier: String, dateString: String) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.heic.identifier as CFString,
                                                         1, nil) else { return false }

        var exif: [String: Any] = [:]
        exif[kCGImagePropertyExifMakerNote as String] = makerNote(identifier: identifier)
        exif[kCGImagePropertyExifDateTimeOriginal as String] = dateString
        exif[kCGImagePropertyExifDateTimeDigitized as String] = dateString

        var tiff: [String: Any] = [:]
        tiff[kCGImagePropertyTIFFMake as String] = "Apple"
        tiff[kCGImagePropertyTIFFModel as String] = "iPhone"

        let props: [String: Any] = [
            kCGImageDestinationLossyCompressionQuality as String: 1.0,
            kCGImagePropertyOrientation as String: 1,
            kCGImagePropertyExifDictionary as String: exif,
            kCGImagePropertyTIFFDictionary as String: tiff
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: - JPEG + 手工 EXIF

    static func debugWriteJPEG(_ image: CGImage, to url: URL,
                                               identifier: String, dateString: String) throws {
        try? FileManager.default.removeItem(at: url)

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.jpeg.identifier as CFString,
                                                         1, nil) else {
            throw MakeError.msg("无法创建 JPEG 输出")
        }
        let props: [String: Any] = [
            kCGImageDestinationLossyCompressionQuality as String: 1.0,
            kCGImagePropertyOrientation as String: 1
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw MakeError.msg("JPEG 编码失败")
        }

        guard let raw = try? Data(contentsOf: url) else {
            throw MakeError.msg("JPEG 读回失败")
        }
        let app1 = buildApp1(identifier: identifier,
                             dateString: dateString,
                             width: image.width,
                             height: image.height)
        let rebuilt = stripExifApp1(raw)
        var out = Data([0xFF, 0xD8])
        out.append(app1)
        out.append(rebuilt.dropFirst(2))
        try out.write(to: url)
    }

    /// 组装完整的 APP1(Exif) 段：FFE1 + 长度 + "Exif\0\0" + TIFF
    ///
    /// TIFF 布局（大端 MM）：
    ///   0..7      header
    ///   8..61     IFD0 (4 entries：Make / Model / Orientation / ExifIFD 指针)
    ///   62..67    "Apple\0"
    ///   68..74    "iPhone\0"
    ///   75        对齐填充
    ///   76..153   ExifIFD (6 entries)
    ///   154..173  DateTimeOriginal(20)
    ///   174..193  DateTimeDigitized(20)
    ///   194..262  MakerNote(69)
    private static func buildApp1(identifier: String, dateString: String,
                                  width: Int, height: Int) -> Data {
        let mn = makerNote(identifier: identifier)

        var make = Array("Apple".utf8);  make.append(0)       // 6
        var model = Array("iPhone".utf8); model.append(0)      // 7
        var dt = Array(dateString.utf8)
        if dt.count > 20 { dt = Array(dt[0..<20]) }
        while dt.count < 20 { dt.append(0) }                   // 20

        let ifd0Offset  = 8
        let makeOffset  = 62
        let modelOffset = 68
        let exifIfdOffset = 76
        let dtOrigOffset  = 154
        let dtDigiOffset  = 174
        let mnOffset      = 194

        var tiff = Data()
        tiff.append(contentsOf: [0x4D, 0x4D])
        tiff.append(contentsOf: be16(0x002A))
        tiff.append(contentsOf: be32(ifd0Offset))

        // ---- IFD0
        tiff.append(contentsOf: be16(4))
        tiff.append(contentsOf: entry(0x010F, 2, make.count,  be32(makeOffset)))
        tiff.append(contentsOf: entry(0x0110, 2, model.count, be32(modelOffset)))
        tiff.append(contentsOf: entry(0x0112, 3, 1,           be16(1) + [0, 0]))
        tiff.append(contentsOf: entry(0x8769, 4, 1,           be32(exifIfdOffset)))
        tiff.append(contentsOf: be32(0))
        // 此时长度应为 62
        tiff.append(contentsOf: make)
        tiff.append(contentsOf: model)
        tiff.append(0x00)                                      // → 76

        // ---- ExifIFD
        tiff.append(contentsOf: be16(6))
        tiff.append(contentsOf: entry(0x9000, 7, 4, Array("0232".utf8)))    // ExifVersion
        tiff.append(contentsOf: entry(0x9003, 2, dt.count, be32(dtOrigOffset)))
        tiff.append(contentsOf: entry(0x9004, 2, dt.count, be32(dtDigiOffset)))
        tiff.append(contentsOf: entry(0xA002, 4, 1, be32(width)))
        tiff.append(contentsOf: entry(0xA003, 4, 1, be32(height)))
        tiff.append(contentsOf: entry(0x927C, 7, mn.count, be32(mnOffset))) // MakerNote
        tiff.append(contentsOf: be32(0))
        // 此时长度应为 154
        tiff.append(contentsOf: dt)
        tiff.append(contentsOf: dt)
        tiff.append(mn)

        var app1 = Data([0xFF, 0xE1])
        let segLen = 2 + 6 + tiff.count
        app1.append(contentsOf: be16(segLen))
        app1.append(contentsOf: Array("Exif".utf8))
        app1.append(0x00)
        app1.append(0x00)
        app1.append(tiff)
        return app1
    }

    private static func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: [UInt8]) -> [UInt8] {
        var v = value
        while v.count < 4 { v.append(0) }
        return be16(tag) + be16(type) + be32(count) + Array(v.prefix(4))
    }

    private static func be16(_ v: Int) -> [UInt8] {
        [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private static func be32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
         UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    /// 去掉 JPEG 里已有的 APP1(Exif)，保留其余所有段
    private static func stripExifApp1(_ data: Data) -> Data {
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return data }
        var out = Data([0xFF, 0xD8])
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { break }
            let marker = b[i + 1]
            if marker == 0xDA {                       // SOS：后面全是压缩数据
                out.append(contentsOf: b[i...])
                return out
            }
            if marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01 {
                out.append(contentsOf: [0xFF, marker])
                i += 2
                continue
            }
            let len = (Int(b[i + 2]) << 8) | Int(b[i + 3])
            let end = i + 2 + len
            guard end <= b.count else { break }
            let isExif = marker == 0xE1 && len >= 8
                && b[i + 4] == 0x45 && b[i + 5] == 0x78
                && b[i + 6] == 0x69 && b[i + 7] == 0x66
            if !isExif {
                out.append(contentsOf: b[i..<end])
            }
            i = end
        }
        return out
    }
}
