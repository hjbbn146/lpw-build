import Foundation

/// 把带 Apple MakerNote 的 Exif 塞进 HEIC。
///
/// 为什么必须自己动手：`CGImageDestination` 写 HEIC 时会把 MakerNote 静默丢掉
/// （CI 实测 `PROBE still heic: makerNoteBytesOK=false`），而真机拍的实况照片
/// 全是 HEIC —— 相册里"实况"能不能点亮，照片容器的可信度也占一份。
///
/// HEIF 里 Exif 是一个独立 item，iloc 用**绝对偏移**指向它，所以只要：
///   1. 把新 payload 追加到 mdat 末尾
///   2. 改 mdat 的 size
///   3. 改 iloc 里该 item 的 offset / length
/// 就完成了替换，图像数据一个字节不动。
///
/// payload 布局照抄 Apple 自己的写法（已在真机 HEIC 里实测确认）：
///   [4 字节 = 6]["Exif\0\0"][TIFF]
enum HeicExifInjector {

    enum Fail: Error, CustomStringConvertible {
        case noMdat, noMeta, noIloc, noExifItem, mdatNotLast, badIloc(String)
        var description: String {
            switch self {
            case .noMdat: return "HEIC 里没有 mdat"
            case .noMeta: return "HEIC 里没有 meta"
            case .noIloc: return "meta 里没有 iloc"
            case .noExifItem: return "iinf 里没有 Exif item"
            case .mdatNotLast: return "mdat 不在文件尾部，位置不变假设不成立"
            case .badIloc(let s): return "iloc 结构不支持：\(s)"
            }
        }
    }

    // MARK: - 入口

    /// - Parameter tiff: 裸 TIFF（JPEG APP1 里 "Exif\0\0" 之后那段）
    @discardableResult
    static func inject(tiff: Data, into url: URL) throws -> Int {
        guard let raw = try? Data(contentsOf: url) else {
            throw Fail.badIloc("读不到文件")
        }
        var d = [UInt8](raw)

        guard let mdat = findTop(d, "mdat") else { throw Fail.noMdat }
        guard let meta = findTop(d, "meta") else { throw Fail.noMeta }
        // mdat 必须在最后，否则「追加到末尾」会破坏后面的 box
        guard mdat.off + mdat.size == d.count else { throw Fail.mdatNotLast }

        let metaStart = meta.off + meta.hdr + 4          // meta 是 fullbox
        let metaEnd = meta.off + meta.size
        guard let iloc = findBox(d, metaStart, metaEnd, "iloc") else { throw Fail.noIloc }
        guard let iinf = findBox(d, metaStart, metaEnd, "iinf") else { throw Fail.noExifItem }

        guard let exifID = findExifItemID(d, iinf) else { throw Fail.noExifItem }
        guard let slot = findIlocSlot(d, iloc, exifID) else {
            throw Fail.badIloc("iloc 里找不到 item \(exifID)")
        }

        // ---- 新 payload
        var payload: [UInt8] = [0, 0, 0, 6]
        payload.append(contentsOf: Array("Exif".utf8))
        payload.append(contentsOf: [0, 0])
        payload.append(contentsOf: [UInt8](tiff))

        // ---- 扩 mdat
        let newOff = mdat.off + mdat.size
        let newSize = mdat.size + payload.count
        if mdat.hdr == 8 {
            putU32(&d, mdat.off, UInt32(newSize))
        } else {
            putU64(&d, mdat.off + 8, UInt64(newSize))
        }

        // ---- 改 iloc 指向新数据
        putBig(&d, slot.offPos, newOff, slot.offBytes)
        putBig(&d, slot.lenPos, payload.count, slot.lenBytes)

        // ---- 追加
        d.append(contentsOf: payload)

        try Data(d).write(to: url)
        return payload.count
    }

    // MARK: - box 扫描

    struct B { var type: String; var off: Int; var size: Int; var hdr: Int }

    static func boxes(_ d: [UInt8], _ from: Int, _ to: Int) -> [B] {
        var out: [B] = []
        var p = from
        while p + 8 <= to {
            var sz = Int(u32(d, p))
            let t = fourCC(d, p + 4)
            var hdr = 8
            if sz == 1 {
                sz = Int(u64(d, p + 8)); hdr = 16
            } else if sz == 0 {
                sz = to - p
            }
            if sz < hdr || p + sz > to { break }
            out.append(B(type: t, off: p, size: sz, hdr: hdr))
            p += sz
        }
        return out
    }

    static func findTop(_ d: [UInt8], _ name: String) -> B? {
        boxes(d, 0, d.count).first { $0.type == name }
    }

    static func findBox(_ d: [UInt8], _ from: Int, _ to: Int, _ name: String) -> B? {
        boxes(d, from, to).first { $0.type == name }
    }

    /// iinf 里找 item_type == "Exif" 的 item_id
    static func findExifItemID(_ d: [UInt8], _ iinf: B) -> Int? {
        let p = iinf.off + iinf.hdr
        let ver = d[p]
        let cnt = ver == 0 ? Int(u16(d, p + 4)) : Int(u32(d, p + 4))
        var q = p + (ver == 0 ? 6 : 8)
        let end = iinf.off + iinf.size
        var found = 0
        for _ in 0..<cnt {
            guard q + 8 <= end else { break }
            let esz = Int(u32(d, q))
            guard esz >= 8, q + esz <= end else { break }
            let v = d[q + 8]
            if v >= 2 {
                // infe v2: ver/flags(4) item_id(2) protection(2) item_type(4)
                // infe v3: ver/flags(4) item_id(4) protection(2) item_type(4)
                let idSize = v == 2 ? 2 : 4
                let idPos = q + 12
                let typePos = idPos + idSize + 2
                if typePos + 4 <= q + esz, fourCC(d, typePos) == "Exif" {
                    found = idSize == 2 ? Int(u16(d, idPos)) : Int(u32(d, idPos))
                    break
                }
            }
            q += esz
        }
        return found > 0 ? found : nil
    }

    struct Slot { var offPos: Int; var lenPos: Int; var offBytes: Int; var lenBytes: Int }

    /// 在 iloc 里定位该 item 第一个 extent 的 offset/length 字段位置
    static func findIlocSlot(_ d: [UInt8], _ iloc: B, _ target: Int) -> Slot? {
        let p = iloc.off + iloc.hdr
        let ver = d[p]
        let offBytes = Int(d[p + 4] >> 4)
        let lenBytes = Int(d[p + 4] & 0x0F)
        let baseBytes = Int(d[p + 5] >> 4)
        let idxBytes = Int(d[p + 5] & 0x0F)
        let cnt = Int(u16(d, p + 6))
        guard offBytes == 4 || offBytes == 8, lenBytes == 4 || lenBytes == 8 else {
            return nil
        }
        let end = iloc.off + iloc.size
        var q = p + 8
        for _ in 0..<cnt {
            guard q + 2 <= end else { return nil }
            let iid = Int(u16(d, q)); q += 2
            if ver == 1 || ver == 2 { q += 2 }        // construction_method
            q += 2                                     // data_reference_index
            q += baseBytes
            guard q + 2 <= end else { return nil }
            let extents = Int(u16(d, q)); q += 2
            guard extents > 0 else { continue }
            if (ver == 1 || ver == 2) && idxBytes > 0 { q += idxBytes }
            let offPos = q
            q += offBytes
            let lenPos = q
            q += lenBytes
            // 跳过其余 extent
            for _ in 1..<extents {
                if (ver == 1 || ver == 2) && idxBytes > 0 { q += idxBytes }
                q += offBytes + lenBytes
            }
            if iid == target {
                return Slot(offPos: offPos, lenPos: lenPos, offBytes: offBytes, lenBytes: lenBytes)
            }
        }
        return nil
    }

    // MARK: - 读写

    static func u16(_ d: [UInt8], _ o: Int) -> UInt16 {
        guard o >= 0, o + 2 <= d.count else { return 0 }
        return (UInt16(d[o]) << 8) | UInt16(d[o+1])
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

    static func fourCC(_ d: [UInt8], _ o: Int) -> String {
        guard o >= 0, o + 4 <= d.count else { return "????" }
        var s = ""
        for i in 0..<4 {
            let c = d[o+i]
            s.append(c >= 0x20 && c < 0x7F ? Character(UnicodeScalar(c)) : "?")
        }
        return s
    }

    static func putU32(_ d: inout [UInt8], _ o: Int, _ v: UInt32) {
        guard o >= 0, o + 4 <= d.count else { return }
        d[o] = UInt8((v >> 24) & 0xFF); d[o+1] = UInt8((v >> 16) & 0xFF)
        d[o+2] = UInt8((v >> 8) & 0xFF); d[o+3] = UInt8(v & 0xFF)
    }

    static func putU64(_ d: inout [UInt8], _ o: Int, _ v: UInt64) {
        guard o >= 0, o + 8 <= d.count else { return }
        for i in 0..<8 { d[o+i] = UInt8((v >> UInt64(8 * (7 - i))) & 0xFF) }
    }

    static func putBig(_ d: inout [UInt8], _ o: Int, _ v: Int, _ n: Int) {
        if n == 8 { putU64(&d, o, UInt64(v)) } else { putU32(&d, o, UInt32(v)) }
    }
}
