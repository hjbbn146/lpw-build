import Foundation

/// 极简 MOV / MP4 box 读写。
///
/// 只做一件事：在不解码、不重编码、不动任何压缩数据的前提下，
/// 把「真机原生实况 MOV」里的元数据轨整条移植到我们自己直通出来的 MOV 上。
///
/// iOS 认不认一张实况照片，看的不是画面，而是 moov 里这几条轨：
///   trak(meta, com.apple.quicktime.live-photo-info)        传感器数据
///   trak(meta, com.apple.quicktime.still-image-time)       静帧时刻
///   trak(meta, com.apple.quicktime.video-orientation)      画面方向
///   moov/meta(keys+ilst, content.identifier)               与照片 MakerNote 配对的 UUID
///
/// AVAssetWriter 能写最后一项，却写不了前三条 ——
/// CMMetadataFormatDescriptionCreateWithMetadataSpecifications 在 iOS 26/27
/// 上恒定返回 -12710（实测六种组合全灭），而 appendTimedMetadataGroup:
/// 在真机上直接抛 ObjC 异常。所以这几条轨只能二进制搬。
enum BoxKit {

    struct Box {
        var type: String
        var off: Int
        var size: Int
        var hdr: Int
    }

    static func u32(_ d: [UInt8], _ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= d.count else { return 0 }
        return (UInt32(d[o]) << 24) | (UInt32(d[o+1]) << 16) | (UInt32(d[o+2]) << 8) | UInt32(d[o+3])
    }

    static func u64(_ d: [UInt8], _ o: Int) -> UInt64 {
        guard o >= 0, o + 8 <= d.count else { return 0 }
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(d[o+i]) }
        return v
    }

    static func i32(_ d: [UInt8], _ o: Int) -> Int32 {
        Int32(bitPattern: u32(d, o))
    }

    static func put32(_ a: inout [UInt8], _ o: Int, _ v: UInt32) {
        guard o >= 0, o + 4 <= a.count else { return }
        a[o] = UInt8((v >> 24) & 0xFF)
        a[o+1] = UInt8((v >> 16) & 0xFF)
        a[o+2] = UInt8((v >> 8) & 0xFF)
        a[o+3] = UInt8(v & 0xFF)
    }

    static func put64(_ a: inout [UInt8], _ o: Int, _ v: UInt64) {
        guard o >= 0, o + 8 <= a.count else { return }
        for i in 0..<8 { a[o+i] = UInt8((v >> UInt64(8 * (7 - i))) & 0xFF) }
    }

    static func fourCC(_ d: [UInt8], _ o: Int) -> String {
        guard o >= 0, o + 4 <= d.count else { return "????" }
        var s = ""
        for i in 0..<4 {
            let c = d[o+i]
            s.append(c >= 0x20 && c < 0x7F ? Character(UnicodeScalar(c)) : "?")
        }
        return s
    }

    static func boxes(_ d: [UInt8], _ off: Int, _ end: Int) -> [Box] {
        var out: [Box] = []
        var p = off
        while p + 8 <= end {
            var sz = Int(u32(d, p))
            let typ = fourCC(d, p + 4)
            var hdr = 8
            if sz == 1 {
                sz = Int(u64(d, p + 8)); hdr = 16
            } else if sz == 0 {
                sz = end - p
            }
            if sz < hdr || p + sz > end { break }
            out.append(Box(type: typ, off: p, size: sz, hdr: hdr))
            p += sz
        }
        return out
    }

    static func children(_ d: [UInt8], _ b: Box) -> [Box] {
        let start = b.off + b.hdr
        let end = b.off + b.size
        if b.type == "stsd" {
            return boxes(d, start + 8, end)
        }
        if b.type == "meta" {
            // QuickTime 规范里 meta 是 fullbox（多 4 字节 version/flags），
            // 但 AVAssetWriter 写出来的 meta 省略了这 4 字节，两种都要兼容。
            let a = boxes(d, start, end)
            if let f = a.first, !f.type.contains("?") { return a }
            return boxes(d, start + 4, end)
        }
        return boxes(d, start, end)
    }

    static func child(_ d: [UInt8], _ b: Box, _ name: String) -> Box? {
        children(d, b).first { $0.type == name }
    }

    static func find(_ d: [UInt8], _ b: Box, _ names: [String]) -> Box? {
        var cur: Box? = b
        for n in names {
            guard let c = cur else { return nil }
            cur = child(d, c, n)
        }
        return cur
    }

    static func payload(_ b: Box) -> Int { b.off + b.hdr }

    /// 拼一个 8 字节头的普通 box
    static func make(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 8 + payload.count)
        put32(&out, 0, UInt32(8 + payload.count))
        let cc = Array(type.utf8)
        for i in 0..<min(4, cc.count) { out[4+i] = cc[i] }
        out.replaceSubrange(8..<(8 + payload.count), with: payload)
        return out
    }
}
